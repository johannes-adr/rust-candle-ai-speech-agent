//! Text-to-Speech: Qwen3-TTS über Crane.
//!
//! Das Modell ist nicht `Sync` und die Inferenz blockiert, deshalb lebt es auf
//! einem eigenen OS-Thread. [`Tts`] ist nur ein klonbarer Handle, der Aufträge
//! über einen Kanal dorthin schickt — damit ist die Synthese von async-Code aus
//! `await`-bar, ohne die Tokio-Worker zu blockieren.

use anyhow::{Context, Result};
use crane_core::generation::SpeechOptions;
use crane_core::models::qwen3_tts::Model;
use crane_core::models::{DType, Device};
use tokio::sync::mpsc;

/// Ein Stück fertig synthetisiertes Audio (mono, f32).
#[derive(Debug, Clone)]
pub struct AudioChunk {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
}

impl AudioChunk {
    /// Als 16-Bit-Mono-WAV kodieren (inkl. Header) — so kann der Browser den
    /// Chunk direkt abspielen.
    pub fn to_wav(&self) -> Result<Vec<u8>> {
        crane::audio::encode_wav(
            &self.samples,
            &crane::audio::AudioInfo {
                sample_rate: self.sample_rate,
                channels: 1,
                bits_per_sample: 16,
            },
        )
    }
}

/// Referenz-Aufnahme für Voice Cloning: Audio plus exaktes Transkript.
#[derive(Debug, Clone)]
pub struct Reference {
    pub samples: Vec<f32>,
    pub transcript: String,
}

/// Wie gesprochen werden soll. `reference: Some(..)` schaltet auf Voice
/// Cloning um (Base-Modell), `None` auf eine Preset-Stimme (CustomVoice).
#[derive(Debug, Clone)]
pub struct TtsConfig {
    pub model_path: String,
    pub language: String,
    /// Preset-Sprecher; `None` = erster Sprecher des Checkpoints.
    pub speaker: Option<String>,
    pub reference: Option<Reference>,
    /// Audio schon während der Generierung eines Satzes ausgeben.
    ///
    /// Erkauft wird das mit Durchsatz: Crane dekodiert jeden Chunk mit 25
    /// Frames Kontext, der Vokoder rechnet also Teile doppelt (gemessen 0,56x
    /// statt 0,74x Echtzeit). Der erste Ton kommt dafür nach ~1 s statt nach
    /// ~11 s. Für einen Dialog-Agenten ist das der richtige Tausch; für lange
    /// Vorlese-Texte am Stück eher nicht.
    pub stream: bool,
    pub opts: SpeechOptions,
}

/// Ein Auftrag an den Modell-Thread: Text rein, Audio-Chunks zurück.
///
/// Kein `oneshot`, weil ein Satz mehrere Chunks liefert — Crane gibt beim
/// Streaming schon nach wenigen Codec-Frames das erste Stück Wellenform raus.
type Job = (String, mpsc::UnboundedSender<Result<AudioChunk>>);

/// Klonbarer Handle auf den TTS-Thread.
#[derive(Clone)]
pub struct Tts {
    tx: mpsc::UnboundedSender<Job>,
}

impl Tts {
    /// Lädt das Modell auf einem eigenen Thread und blockiert, bis es steht.
    pub fn spawn(cfg: TtsConfig, device: Device, dtype: DType) -> Result<Self> {
        let (tx, mut rx) = mpsc::unbounded_channel::<Job>();
        // std-Kanal, weil das Laden synchron abgewartet wird.
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<()>>();

        std::thread::Builder::new()
            .name("tts".into())
            .spawn(move || {
                let loaded = Model::new(&cfg.model_path, &device, &dtype)
                    .with_context(|| format!("TTS-Modell nicht ladbar: {}", cfg.model_path));

                let mut model = match loaded {
                    Ok(m) => m,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };

                // Sprecher einmalig auflösen: sortiert, damit der Default
                // reproduzierbar ist.
                let speaker = cfg.speaker.clone().or_else(|| {
                    let mut names: Vec<String> =
                        model.config.talker_config.spk_id.keys().cloned().collect();
                    names.sort();
                    names.first().cloned()
                });

                if ready_tx.send(Ok(())).is_err() {
                    return;
                }

                while let Some((text, out)) = rx.blocking_recv() {
                    synthesize_blocking(&mut model, &cfg, speaker.as_deref(), &text, &out);
                }
            })
            .context("TTS-Thread nicht startbar")?;

        ready_rx.recv().context("TTS-Thread abgestürzt")??;
        Ok(Self { tx })
    }

    /// Einen Satz synthetisieren.
    ///
    /// Liefert die Chunks, sobald sie fertig sind — der erste kommt lange vor
    /// dem Satzende. Der Kanal schließt, wenn der Satz vollständig ist.
    pub fn synthesize(&self, text: &str) -> mpsc::UnboundedReceiver<Result<AudioChunk>> {
        let (out_tx, out_rx) = mpsc::unbounded_channel();
        if self.tx.send((text.to_string(), out_tx.clone())).is_err() {
            let _ = out_tx.send(Err(anyhow::anyhow!("TTS-Thread ist beendet")));
        }
        out_rx
    }
}

/// Die eigentliche Synthese — läuft ausschließlich auf dem TTS-Thread.
///
/// Voice Cloning kennt in Crane keinen Streaming-Pfad
/// (`generate_speech_streaming` gibt es nur mit Preset-Sprecher), dort kommt
/// der Satz deshalb als ein einzelner Chunk.
fn synthesize_blocking(
    model: &mut Model,
    cfg: &TtsConfig,
    speaker: Option<&str>,
    text: &str,
    out: &mpsc::UnboundedSender<Result<AudioChunk>>,
) {
    let sample_rate = model.sample_rate();

    if let Some(reference) = &cfg.reference {
        let chunk = model
            .generate_voice_clone(
                text,
                &cfg.language,
                &reference.samples,
                reference.transcript.trim(),
                &cfg.opts,
            )
            .and_then(|(audio, sr)| to_chunk(&audio, sr));
        let _ = out.send(chunk);
        return;
    }

    if !cfg.stream {
        let chunk = model
            .generate_speech(text, &cfg.language, speaker, &cfg.opts)
            .and_then(|(audio, sr)| to_chunk(&audio, sr));
        let _ = out.send(chunk);
        return;
    }

    let stream = match model.generate_speech_streaming(text, &cfg.language, speaker, &cfg.opts) {
        Ok(stream) => stream,
        Err(e) => {
            let _ = out.send(Err(e));
            return;
        }
    };

    for item in stream {
        let chunk = item.and_then(|audio| to_chunk(&audio, sample_rate));
        let failed = chunk.is_err();
        // Empfänger weg = Anfrage abgebrochen, kein Fehler.
        if out.send(chunk).is_err() || failed {
            return;
        }
    }
}

fn to_chunk(audio: &crane_core::models::Tensor, sample_rate: u32) -> Result<AudioChunk> {
    let samples: Vec<f32> = audio.to_dtype(DType::F32)?.flatten_all()?.to_vec1()?;
    Ok(AudioChunk {
        samples,
        sample_rate,
    })
}
