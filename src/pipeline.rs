//! Orchestrierung: Audio → STT → LLM → satzweise TTS → Audio.
//!
//! Die drei Stufen laufen entkoppelt: das LLM streamt Token, die hier zu
//! Sätzen gepuffert werden, und **jeder fertige Satz geht sofort** an die
//! Synthese. Der Aufrufer bekommt einen Kanal und hört das erste Stück
//! Antwort, während das LLM noch schreibt.

use tokio::sync::mpsc;

use crate::llm::{Llm, Message};
use crate::stt::Stt;
use crate::tts::{AudioChunk, Tts};

/// Was während eines Durchlaufs passiert, in Ankunftsreihenfolge.
#[derive(Debug)]
pub enum Event {
    /// Erkannter Nutzertext (nur im Speech-to-Speech-Modus).
    Transcript(String),
    /// Token-Delta des LLM.
    Delta(String),
    /// Ein fertig synthetisierter Satz.
    Audio(AudioChunk),
    Error(String),
}

pub struct Pipeline {
    stt: Stt,
    llm: Llm,
    tts: Tts,
    system_prompt: String,
}

impl Pipeline {
    pub fn new(stt: Stt, llm: Llm, tts: Tts, system_prompt: impl Into<String>) -> Self {
        Self {
            stt,
            llm,
            tts,
            system_prompt: system_prompt.into(),
        }
    }

    /// Sample-Rate, die die Pipeline als Eingang erwartet.
    pub fn stt_sample_rate(&self) -> u32 {
        self.stt.sample_rate()
    }

    /// Voller Durchlauf: gesprochene Frage rein, gesprochene Antwort raus.
    ///
    /// `samples` ist Mono-f32-PCM mit [`Self::stt_sample_rate`].
    pub fn speech_to_speech(&self, samples: Vec<f32>) -> mpsc::Receiver<Event> {
        let (tx, rx) = mpsc::channel(32);
        let stt = self.stt.clone();
        let llm = self.llm.clone();
        let tts = self.tts.clone();
        let system_prompt = self.system_prompt.clone();

        tokio::spawn(async move {
            let transcript = match stt.transcribe(samples).await {
                Ok(t) => t.trim().to_string(),
                Err(e) => {
                    let _ = tx.send(Event::Error(format!("STT fehlgeschlagen: {e:#}"))).await;
                    return;
                }
            };

            if transcript.is_empty() {
                let _ = tx
                    .send(Event::Error("Nichts verstanden.".to_string()))
                    .await;
                return;
            }
            if tx.send(Event::Transcript(transcript.clone())).await.is_err() {
                return;
            }

            let messages = vec![Message::system(system_prompt), Message::user(transcript)];
            answer_and_speak(&llm, &tts, messages, &tx).await;
        });

        rx
    }

    /// Reiner TTS-Modus: Text rein, Audio raus. Kein STT, kein LLM.
    pub fn text_to_speech(&self, text: String) -> mpsc::Receiver<Event> {
        let (tx, rx) = mpsc::channel(32);
        let tts = self.tts.clone();

        tokio::spawn(async move {
            let text = text.trim().to_string();
            if text.is_empty() {
                let _ = tx.send(Event::Error("Kein Text übergeben.".to_string())).await;
                return;
            }
            // Auch hier satzweise, damit lange Texte früh zu hören sind.
            let mut buffer = text;
            drain(&tts, &tx, &mut buffer).await;
        });

        rx
    }
}

/// LLM-Stream konsumieren, Deltas durchreichen und jeden fertigen Satz
/// sofort synthetisieren.
async fn answer_and_speak(
    llm: &Llm,
    tts: &Tts,
    messages: Vec<Message>,
    tx: &mpsc::Sender<Event>,
) {
    let mut deltas = llm.stream_chat(messages);
    let mut buffer = String::new();

    while let Some(item) = deltas.recv().await {
        let delta = match item {
            Ok(d) => d,
            Err(e) => {
                let _ = tx.send(Event::Error(format!("LLM fehlgeschlagen: {e:#}"))).await;
                return;
            }
        };

        if tx.send(Event::Delta(delta.clone())).await.is_err() {
            return;
        }
        buffer.push_str(&delta);

        // `false`: am Puffer-Ende noch nicht abschneiden — dort könnte der
        // Satz (oder eine Dezimalzahl) einfach noch weitergehen.
        while let Some(sentence) = take_sentence(&mut buffer, false) {
            if !speak(tts, tx, &sentence).await {
                return;
            }
        }
    }

    // Rest nach Stream-Ende: jetzt ist der Puffer wirklich vollständig.
    drain(tts, tx, &mut buffer).await;
}

/// Den Puffer restlos aussprechen.
///
/// Erst die noch vollständigen Sätze, dann — und das ist der Grund für diese
/// Funktion — was ohne Satzzeichen übrig bleibt. Ein LLM, das mit „Bis dann"
/// ohne Punkt endet, würde sonst still verschluckt.
async fn drain(tts: &Tts, tx: &mpsc::Sender<Event>, buffer: &mut String) {
    while let Some(sentence) = take_sentence(buffer, true) {
        if !speak(tts, tx, &sentence).await {
            return;
        }
    }

    let rest = buffer.trim();
    if rest.chars().any(char::is_alphanumeric) {
        speak(tts, tx, &rest.to_string()).await;
    }
    buffer.clear();
}

/// Einen Satz synthetisieren und senden. `false` = Empfänger ist weg,
/// Aufrufer soll abbrechen.
async fn speak(tts: &Tts, tx: &mpsc::Sender<Event>, sentence: &str) -> bool {
    let event = match tts.synthesize(sentence).await {
        Ok(chunk) => Event::Audio(chunk),
        Err(e) => Event::Error(format!("TTS fehlgeschlagen: {e:#}")),
    };
    tx.send(event).await.is_ok()
}

/// Schneidet den ersten vollständigen Satz vorne aus `buffer`.
///
/// Satzende ist `.`, `!` oder `?`, gefolgt von Whitespace. Steht der
/// Terminator am Puffer-Ende, ist noch offen, ob er wirklich einen Satz
/// beendet: bei „19.“ könnte gleich „99“ folgen. Entscheidend ist deshalb das
/// Zeichen **davor** — eine Ziffer heißt warten, alles andere heißt schneiden.
///
/// Das ist keine Kosmetik: der letzte Satz einer Antwort endet fast immer am
/// Puffer-Ende, und ihn bis zum Schließen des LLM-Streams liegen zu lassen
/// kostet spürbar Latenz. `flush` erzwingt den Schnitt, wenn ohnehin nichts
/// mehr nachkommt.
///
/// Gibt `None` zurück, wenn kein Satz fertig ist oder nur Satzzeichen ohne
/// sprechbaren Inhalt übrig sind.
fn take_sentence(buffer: &mut String, flush: bool) -> Option<String> {
    let end = buffer.char_indices().find_map(|(i, c)| {
        if !matches!(c, '.' | '!' | '?') {
            return None;
        }
        let after = i + c.len_utf8();
        match buffer[after..].chars().next() {
            Some(next) if next.is_whitespace() => Some(after),
            Some(_) => None,
            // Puffer-Ende: nur eine Ziffer davor lässt eine Fortsetzung
            // erwarten (Dezimalzahl, Datum).
            None => {
                let vorher = buffer[..i].chars().next_back();
                (flush || !vorher.is_some_and(|p| p.is_ascii_digit())).then_some(after)
            }
        }
    })?;

    let sentence = buffer[..end].trim().to_string();
    buffer.drain(..end);

    if sentence.chars().any(char::is_alphanumeric) {
        Some(sentence)
    } else {
        // Reine Satzzeichen ergeben keine Sprachausgabe — verwerfen und den
        // Aufrufer weitersuchen lassen.
        take_sentence(buffer, flush)
    }
}

#[cfg(test)]
mod tests {
    use super::take_sentence;

    #[test]
    fn splittet_am_satzende() {
        let mut buf = "Hallo Welt. Wie geht es dir?".to_string();
        assert_eq!(take_sentence(&mut buf, false).as_deref(), Some("Hallo Welt."));
        assert_eq!(buf, " Wie geht es dir?");
    }

    #[test]
    fn wartet_auf_unvollstaendigen_satz() {
        let mut buf = "Hallo Welt".to_string();
        assert_eq!(take_sentence(&mut buf, false), None);
        assert_eq!(buf, "Hallo Welt");
    }

    #[test]
    fn zerschneidet_keine_dezimalzahl() {
        let mut buf = "Das kostet 19.99 Euro".to_string();
        assert_eq!(take_sentence(&mut buf, false), None);
    }

    #[test]
    fn schneidet_letzten_satz_ohne_auf_stream_ende_zu_warten() {
        let mut buf = "Fertig.".to_string();
        assert_eq!(take_sentence(&mut buf, false).as_deref(), Some("Fertig."));
        assert!(buf.is_empty());
    }

    #[test]
    fn wartet_bei_ziffer_vor_dem_punkt() {
        // Könnte „19.99“ werden — erst der Flush entscheidet.
        let mut buf = "Das kostet 19.".to_string();
        assert_eq!(take_sentence(&mut buf, false), None);
        assert_eq!(
            take_sentence(&mut buf, true).as_deref(),
            Some("Das kostet 19.")
        );
        assert!(buf.is_empty());
    }

    #[test]
    fn ueberspringt_inhaltslose_satzzeichen() {
        let mut buf = "... Also gut! Und weiter".to_string();
        assert_eq!(take_sentence(&mut buf, false).as_deref(), Some("Also gut!"));
        assert_eq!(buf, " Und weiter");
    }
}
