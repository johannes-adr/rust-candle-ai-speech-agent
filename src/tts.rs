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

/// Referenz-Aufnahme für Voice Cloning: WAV-Datei plus exaktes Transkript.
///
/// Bewusst die **rohen WAV-Bytes** und keine fertigen Samples: der
/// Speaker-Encoder erwartet eine ganz bestimmte Sample-Rate, und die steht in
/// der `config.json` des Checkpoints. Dekodiert wird deshalb erst auf dem
/// TTS-Thread, wo das Modell danach gefragt werden kann. Vorher stand hier
/// eine hartkodierte Rate — mit 16 kHz statt 24 kHz klang die geklonte Stimme
/// um den Faktor 1,5 zu hoch.
#[derive(Debug, Clone)]
pub struct Reference {
    pub wav: Vec<u8>,
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

/// Eine einzelne Synthese-Anfrage. `None` heißt jeweils: Default aus
/// [`TtsConfig`] nehmen.
#[derive(Debug, Clone)]
pub struct SpeechRequest {
    pub text: String,
    pub language: Option<String>,
    pub speaker: Option<String>,
    pub reference: Option<Reference>,
}

impl SpeechRequest {
    /// Anfrage nur mit Text — alles andere wie konfiguriert.
    pub fn new(text: impl Into<String>) -> Self {
        Self {
            text: text.into(),
            language: None,
            speaker: None,
            reference: None,
        }
    }
}

/// Was das geladene Checkpoint kann — beim Laden aus der `config.json`
/// gelesen, damit die UI nur anbietet, was tatsächlich geht.
///
/// Ein Prozess hat immer genau ein Checkpoint geladen, und die beiden
/// Varianten schließen sich aus: CustomVoice kann Preset-Stimmen und **kein**
/// Cloning, Base kann **nur** Cloning.
#[derive(Debug, Clone)]
pub struct Capabilities {
    /// Unterstützte Sprachen, sortiert, mit `"auto"` an erster Stelle.
    pub languages: Vec<String>,
    /// Preset-Sprecher, sortiert; leer beim Base-Checkpoint.
    pub speakers: Vec<String>,
    /// `true` = Base-Checkpoint, spricht nur mit Referenz-Audio.
    pub cloning: bool,
    /// Sample-Rate, auf die Referenz-Aufnahmen gebracht werden müssen.
    /// Kommt aus dem Checkpoint, nicht aus einer Konstanten.
    pub speaker_encoder_sample_rate: u32,
}

/// Ein Auftrag an den Modell-Thread: Anfrage rein, Audio-Chunks zurück.
///
/// Kein `oneshot`, weil ein Satz mehrere Chunks liefert — Crane gibt beim
/// Streaming schon nach wenigen Codec-Frames das erste Stück Wellenform raus.
type Job = (SpeechRequest, mpsc::UnboundedSender<Result<AudioChunk>>);

/// Klonbarer Handle auf den TTS-Thread.
#[derive(Clone)]
pub struct Tts {
    tx: mpsc::UnboundedSender<Job>,
    capabilities: Capabilities,
}

impl Tts {
    /// Lädt das Modell auf einem eigenen Thread und blockiert, bis es steht.
    pub fn spawn(cfg: TtsConfig, device: Device, dtype: DType) -> Result<Self> {
        let (tx, mut rx) = mpsc::unbounded_channel::<Job>();
        // std-Kanal, weil das Laden synchron abgewartet wird.
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<Capabilities>>();

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

                let capabilities = read_capabilities(&model);

                // Default-Sprecher einmalig auflösen: sortiert, damit er
                // reproduzierbar ist.
                let speaker = cfg
                    .speaker
                    .clone()
                    .or_else(|| capabilities.speakers.first().cloned());

                if ready_tx.send(Ok(capabilities)).is_err() {
                    return;
                }

                while let Some((req, out)) = rx.blocking_recv() {
                    synthesize_blocking(&mut model, &cfg, speaker.as_deref(), &req, &out);
                }
            })
            .context("TTS-Thread nicht startbar")?;

        let capabilities = ready_rx.recv().context("TTS-Thread abgestürzt")??;
        Ok(Self { tx, capabilities })
    }

    /// Was das geladene Checkpoint kann.
    pub fn capabilities(&self) -> &Capabilities {
        &self.capabilities
    }

    /// Einen Satz synthetisieren.
    ///
    /// Liefert die Chunks, sobald sie fertig sind — der erste kommt lange vor
    /// dem Satzende. Der Kanal schließt, wenn der Satz vollständig ist.
    pub fn synthesize(&self, req: SpeechRequest) -> mpsc::UnboundedReceiver<Result<AudioChunk>> {
        let (out_tx, out_rx) = mpsc::unbounded_channel();
        if self.tx.send((req, out_tx.clone())).is_err() {
            let _ = out_tx.send(Err(anyhow::anyhow!("TTS-Thread ist beendet")));
        }
        out_rx
    }
}

/// Sprachen und Stimmen aus der geladenen `config.json` ziehen.
fn read_capabilities(model: &Model) -> Capabilities {
    let talker = &model.config.talker_config;

    let mut languages: Vec<String> = talker.codec_language_id.keys().cloned().collect();
    languages.sort();
    // "auto" steht nicht in der Config — Crane wertet es als Sonderfall aus
    // und überlässt die Sprache dem Modell.
    languages.insert(0, "auto".to_string());

    let mut speakers: Vec<String> = talker.spk_id.keys().cloned().collect();
    speakers.sort();

    Capabilities {
        languages,
        speakers,
        cloning: model.config.tts_model_type.as_deref() == Some("base"),
        speaker_encoder_sample_rate: model.speaker_encoder_sample_rate(),
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
    default_speaker: Option<&str>,
    req: &SpeechRequest,
    out: &mpsc::UnboundedSender<Result<AudioChunk>>,
) {
    let sample_rate = model.sample_rate();
    let text = req.text.as_str();

    // Anfrage schlägt Konfiguration.
    let language = req.language.as_deref().unwrap_or(&cfg.language);
    let speaker = req.speaker.as_deref().or(default_speaker);
    let reference = req.reference.as_ref().or(cfg.reference.as_ref());

    if let Some(reference) = reference {
        // Die Referenz erst hier dekodieren: nur an dieser Stelle ist die vom
        // Speaker-Encoder erwartete Rate bekannt.
        let chunk = crane::audio::decode_wav(&reference.wav, model.speaker_encoder_sample_rate())
            .context("Referenz-Audio nicht dekodierbar")
            .and_then(|samples| {
                model.generate_voice_clone(
                    text,
                    language,
                    &samples,
                    reference.transcript.trim(),
                    &cfg.opts,
                )
            })
            .and_then(|(audio, sr)| to_chunk(&audio, sr));
        let _ = out.send(chunk);
        return;
    }

    if !cfg.stream {
        let chunk = model
            .generate_speech(text, language, speaker, &cfg.opts)
            .and_then(|(audio, sr)| to_chunk(&audio, sr));
        let _ = out.send(chunk);
        return;
    }

    let stream = match model.generate_speech_streaming(text, language, speaker, &cfg.opts) {
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
