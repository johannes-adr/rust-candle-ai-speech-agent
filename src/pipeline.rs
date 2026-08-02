//! Orchestrierung: Audio → STT → LLM → satzweise TTS → Audio.
//!
//! Die drei Stufen laufen entkoppelt: das LLM streamt Token, die hier zu
//! Sätzen gepuffert werden, und **jeder fertige Satz geht sofort** an die
//! Synthese. Der Aufrufer bekommt einen Kanal und hört das erste Stück
//! Antwort, während das LLM noch schreibt.

use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::llm::{Llm, Message};
use crate::stt::Stt;
use crate::tts::{AudioChunk, Capabilities, SpeechRequest, Tts};

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

/// TTS ist immer da; STT und LLM fehlen im reinen Text-to-Speech-Betrieb
/// (`MODE=tts`) — dann werden die Modelle gar nicht erst geladen.
pub struct Pipeline {
    stt: Option<Stt>,
    llm: Option<Llm>,
    tts: Tts,
    system_prompt: String,
}

impl Pipeline {
    pub fn new(
        stt: Option<Stt>,
        llm: Option<Llm>,
        tts: Tts,
        system_prompt: impl Into<String>,
    ) -> Self {
        Self {
            stt,
            llm,
            tts,
            system_prompt: system_prompt.into(),
        }
    }

    /// Sample-Rate, die die Pipeline als Eingang erwartet — `None`, wenn kein
    /// STT geladen ist.
    pub fn stt_sample_rate(&self) -> Option<u32> {
        self.stt.as_ref().map(Stt::sample_rate)
    }

    /// Was das geladene TTS-Checkpoint kann.
    pub fn capabilities(&self) -> &Capabilities {
        self.tts.capabilities()
    }

    /// Voller Durchlauf: gesprochene Frage rein, gesprochene Antwort raus.
    ///
    /// `samples` ist Mono-f32-PCM mit [`Self::stt_sample_rate`]. `None`, wenn
    /// STT oder LLM fehlen.
    pub fn speech_to_speech(&self, samples: Vec<f32>) -> Option<mpsc::Receiver<Event>> {
        let (stt, llm) = (self.stt.clone()?, self.llm.clone()?);
        let (tx, rx) = mpsc::channel(32);
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

        Some(rx)
    }

    /// Reiner TTS-Modus: Text rein, Audio raus. Kein STT, kein LLM.
    pub fn text_to_speech(&self, req: SpeechRequest) -> mpsc::Receiver<Event> {
        let (tx, rx) = mpsc::channel(32);
        let tts = self.tts.clone();

        tokio::spawn(async move {
            let text = req.text.trim().to_string();
            if text.is_empty() {
                let _ = tx.send(Event::Error("Kein Text übergeben.".to_string())).await;
                return;
            }
            // Auch hier satzweise, damit lange Texte früh zu hören sind.
            let (sentences, speaker) = spawn_speaker(tts, tx.clone(), req);
            let mut buffer = text;
            drain(&mut buffer, &sentences).await;
            drop(sentences);
            let _ = speaker.await;
        });

        rx
    }
}

/// Startet die Synthese-Task und gibt den Kanal zurück, in den Sätze
/// geschoben werden.
///
/// Diese Entkopplung ist der Grund, warum es sie gibt: die Synthese eines
/// Satzes dauert länger als seine Wiedergabe, und würde sie im selben Task
/// wie das Lesen des LLM-Streams laufen, stünde währenddessen die
/// Token-Verarbeitung still — der Antworttext bliebe in der UI hängen und die
/// nächsten Sätze würden erst nach der Synthese überhaupt erkannt. So läuft
/// das LLM mit voller Geschwindigkeit weiter und füllt die Warteschlange,
/// während TTS und Browser hinterherarbeiten.
///
/// Die Sätze selbst bleiben seriell: es gibt ein Modell auf einem Thread.
///
/// `template` liefert Sprache, Stimme und Referenz für jeden Satz; nur der
/// Text wird pro Satz ersetzt.
fn spawn_speaker(
    tts: Tts,
    tx: mpsc::Sender<Event>,
    template: SpeechRequest,
) -> (mpsc::Sender<String>, JoinHandle<()>) {
    let (sentences_tx, mut sentences_rx) = mpsc::channel::<String>(32);

    let handle = tokio::spawn(async move {
        while let Some(sentence) = sentences_rx.recv().await {
            let req = SpeechRequest {
                text: sentence,
                ..template.clone()
            };
            if !speak(&tts, &tx, req).await {
                break;
            }
        }
    });

    (sentences_tx, handle)
}

/// LLM-Stream konsumieren, Deltas durchreichen und fertige Sätze in die
/// Synthese-Warteschlange schieben.
async fn answer_and_speak(
    llm: &Llm,
    tts: &Tts,
    messages: Vec<Message>,
    tx: &mpsc::Sender<Event>,
) {
    // Der Agent spricht mit den Server-Defaults — Sprache und Stimme sind
    // hier nichts, was der Nutzer pro Antwort wählt.
    let (sentences, speaker) = spawn_speaker(tts.clone(), tx.clone(), SpeechRequest::new(""));
    let mut deltas = llm.stream_chat(messages);
    let mut buffer = String::new();

    while let Some(item) = deltas.recv().await {
        let delta = match item {
            Ok(d) => d,
            Err(e) => {
                let _ = tx.send(Event::Error(format!("LLM fehlgeschlagen: {e:#}"))).await;
                break;
            }
        };

        if tx.send(Event::Delta(delta.clone())).await.is_err() {
            break;
        }
        buffer.push_str(&delta);

        // `false`: am Puffer-Ende noch nicht abschneiden — dort könnte der
        // Satz (oder eine Dezimalzahl) einfach noch weitergehen.
        let mut abgebrochen = false;
        while let Some(sentence) = take_sentence(&mut buffer, false) {
            if sentences.send(sentence).await.is_err() {
                abgebrochen = true;
                break;
            }
        }
        if abgebrochen {
            break;
        }
    }

    // Rest nach Stream-Ende: jetzt ist der Puffer wirklich vollständig.
    drain(&mut buffer, &sentences).await;
    // Sender fallen lassen, damit die Synthese-Task ihr Kanalende sieht.
    drop(sentences);
    let _ = speaker.await;
}

/// Den Puffer restlos in die Warteschlange schieben.
///
/// Erst die noch vollständigen Sätze, dann — und das ist der Grund für diese
/// Funktion — was ohne Satzzeichen übrig bleibt. Ein LLM, das mit „Bis dann"
/// ohne Punkt endet, würde sonst still verschluckt.
async fn drain(buffer: &mut String, sentences: &mpsc::Sender<String>) {
    while let Some(sentence) = take_sentence(buffer, true) {
        if sentences.send(sentence).await.is_err() {
            return;
        }
    }

    let rest = buffer.trim();
    if rest.chars().any(char::is_alphanumeric) {
        let _ = sentences.send(rest.to_string()).await;
    }
    buffer.clear();
}

/// Einen Satz synthetisieren und die Chunks weiterreichen, sobald sie da sind.
/// `false` = Empfänger ist weg, Aufrufer soll abbrechen.
async fn speak(tts: &Tts, tx: &mpsc::Sender<Event>, req: SpeechRequest) -> bool {
    let mut chunks = tts.synthesize(req);

    while let Some(item) = chunks.recv().await {
        let event = match item {
            Ok(chunk) => Event::Audio(chunk),
            Err(e) => Event::Error(format!("TTS fehlgeschlagen: {e:#}")),
        };
        if tx.send(event).await.is_err() {
            return false;
        }
    }
    true
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
