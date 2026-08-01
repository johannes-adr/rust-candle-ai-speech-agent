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
use tokio::sync::{mpsc, oneshot};

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
    pub opts: SpeechOptions,
}

/// Ein Auftrag an den Modell-Thread: Text rein, Audio zurück.
type Job = (String, oneshot::Sender<Result<AudioChunk>>);

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

                while let Some((text, reply)) = rx.blocking_recv() {
                    let result = synthesize_blocking(&mut model, &cfg, speaker.as_deref(), &text);
                    // Empfänger weg = Anfrage abgebrochen, kein Fehler.
                    let _ = reply.send(result);
                }
            })
            .context("TTS-Thread nicht startbar")?;

        ready_rx.recv().context("TTS-Thread abgestürzt")??;
        Ok(Self { tx })
    }

    /// Einen Satz (oder beliebigen Text) synthetisieren.
    pub async fn synthesize(&self, text: &str) -> Result<AudioChunk> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send((text.to_string(), reply_tx))
            .map_err(|_| anyhow::anyhow!("TTS-Thread ist beendet"))?;
        reply_rx.await.context("TTS-Antwort verloren")?
    }
}

/// Die eigentliche Synthese — läuft ausschließlich auf dem TTS-Thread.
fn synthesize_blocking(
    model: &mut Model,
    cfg: &TtsConfig,
    speaker: Option<&str>,
    text: &str,
) -> Result<AudioChunk> {
    let (audio, sample_rate) = match &cfg.reference {
        Some(reference) => model.generate_voice_clone(
            text,
            &cfg.language,
            &reference.samples,
            reference.transcript.trim(),
            &cfg.opts,
        )?,
        None => model.generate_speech(text, &cfg.language, speaker, &cfg.opts)?,
    };

    let samples: Vec<f32> = audio.to_dtype(DType::F32)?.flatten_all()?.to_vec1()?;
    Ok(AudioChunk {
        samples,
        sample_rate,
    })
}
