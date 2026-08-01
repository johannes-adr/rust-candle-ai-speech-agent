//! Speech-to-Text: Qwen3-ASR über Crane.
//!
//! Das Modell ist nicht `Sync` und die Inferenz blockiert, deshalb lebt es auf
//! einem eigenen OS-Thread. [`Stt`] ist nur ein klonbarer Handle, der Aufträge
//! über einen Kanal dorthin schickt — damit ist die Transkription von
//! async-Code aus `await`-bar, ohne die Tokio-Worker zu blockieren.

use anyhow::{Context, Result};
use crane_core::generation::TranscribeOptions;
use crane_core::models::qwen3_asr::Model;
use crane_core::models::{DType, Device};
use tokio::sync::{mpsc, oneshot};

/// Ein Auftrag an den Modell-Thread: Mono-f32-PCM rein, Text zurück.
type Job = (Vec<f32>, oneshot::Sender<Result<String>>);

/// Klonbarer Handle auf den STT-Thread.
#[derive(Clone)]
pub struct Stt {
    tx: mpsc::UnboundedSender<Job>,
    sample_rate: u32,
}

impl Stt {
    /// Lädt das Modell auf einem eigenen Thread und blockiert, bis es steht.
    ///
    /// `language: None` überlässt dem Modell die Spracherkennung.
    pub fn spawn(
        model_path: &str,
        language: Option<String>,
        device: Device,
        dtype: DType,
    ) -> Result<Self> {
        let (tx, mut rx) = mpsc::unbounded_channel::<Job>();
        // std-Kanal, weil das Laden synchron abgewartet wird.
        let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<u32>>();

        // Der Thread überlebt diesen Aufruf, deshalb den Pfad besitzen.
        let model_path = model_path.to_string();

        std::thread::Builder::new()
            .name("stt".into())
            .spawn(move || {
                let loaded = Model::new(&model_path, &device, &dtype)
                    .with_context(|| format!("STT-Modell nicht ladbar: {model_path}"));

                let mut model = match loaded {
                    Ok(m) => m,
                    Err(e) => {
                        let _ = ready_tx.send(Err(e));
                        return;
                    }
                };

                // Optionen einmalig aufbauen: Default ist greedy (temperature
                // 0.0), wir setzen nur die Sprache.
                let opts = TranscribeOptions {
                    language,
                    ..Default::default()
                };

                if ready_tx.send(Ok(model.sample_rate())).is_err() {
                    return;
                }

                while let Some((samples, reply)) = rx.blocking_recv() {
                    let result = transcribe_blocking(&mut model, &opts, &samples);
                    // Empfänger weg = Anfrage abgebrochen, kein Fehler.
                    let _ = reply.send(result);
                }
            })
            .context("STT-Thread nicht startbar")?;

        let sample_rate = ready_rx.recv().context("STT-Thread abgestürzt")??;
        Ok(Self { tx, sample_rate })
    }

    /// Sample-Rate, die dieses Modell erwartet (16000).
    pub fn sample_rate(&self) -> u32 {
        self.sample_rate
    }

    /// Mono-f32-PCM zu Text transkribieren.
    pub async fn transcribe(&self, samples: Vec<f32>) -> Result<String> {
        let (reply_tx, reply_rx) = oneshot::channel();
        self.tx
            .send((samples, reply_tx))
            .map_err(|_| anyhow::anyhow!("STT-Thread ist beendet"))?;
        reply_rx.await.context("STT-Antwort verloren")?
    }
}

/// Die eigentliche Transkription — läuft ausschließlich auf dem STT-Thread.
fn transcribe_blocking(
    model: &mut Model,
    opts: &TranscribeOptions,
    samples: &[f32],
) -> Result<String> {
    let text = model
        .transcribe(samples, opts)
        .context("Transkription fehlgeschlagen")?;
    Ok(strip_control_tokens(&text))
}

/// Qwen3-ASR stellt dem Transkript seine Sprach-Erkennung voran, etwa
/// `language German<asr_text>Kurzer Test.` — Crane reicht das ungefiltert
/// durch. Alles bis einschließlich `<asr_text>` gehört nicht zum Gesagten und
/// hätte im LLM-Prompt nichts zu suchen.
fn strip_control_tokens(text: &str) -> String {
    const MARKER: &str = "<asr_text>";
    match text.split_once(MARKER) {
        Some((_, rest)) => rest.trim().to_string(),
        None => text.trim().to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::strip_control_tokens;

    #[test]
    fn entfernt_sprach_praefix() {
        assert_eq!(
            strip_control_tokens("language German<asr_text>Kurzer Test, zweiter Satz."),
            "Kurzer Test, zweiter Satz."
        );
    }

    #[test]
    fn laesst_reines_transkript_stehen() {
        assert_eq!(strip_control_tokens("  Hallo Welt.  "), "Hallo Welt.");
    }
}
