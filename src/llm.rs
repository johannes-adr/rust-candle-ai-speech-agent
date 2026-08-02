//! LLM-Anbindung: OpenAI-kompatibler Chat-Completions-Client mit SSE-Streaming.
//!
//! Zielserver ist Ollama unter `http://localhost:11434/v1`, das Protokoll ist
//! aber das gewöhnliche OpenAI-Format. Die Antwort kommt als Server-Sent-Events
//! herein; jedes Event trägt ein Text-Delta. Diese Deltas werden sofort über
//! einen Kanal weitergereicht, damit nachgelagerte Stufen (Satz-Segmentierung,
//! TTS) schon loslegen können, während das Modell noch schreibt.

use anyhow::{Context, Result};
use futures_util::StreamExt;
use tokio::sync::mpsc;

/// Eine Nachricht im Chat-Verlauf.
#[derive(Debug, Clone, serde::Serialize)]
pub struct Message {
    pub role: String,
    pub content: String,
}

impl Message {
    /// System-Prompt — setzt Rolle und Verhalten des Assistenten.
    pub fn system(content: impl Into<String>) -> Self {
        Self {
            role: "system".into(),
            content: content.into(),
        }
    }

    /// Eingabe des Nutzers.
    pub fn user(content: impl Into<String>) -> Self {
        Self {
            role: "user".into(),
            content: content.into(),
        }
    }
}

/// Klonbarer Client auf einen OpenAI-kompatiblen Endpunkt.
///
/// `reqwest::Client` teilt seinen Verbindungspool über Klone hinweg, deshalb
/// ist `Clone` hier billig und erwünscht.
#[derive(Clone)]
pub struct Llm {
    http: reqwest::Client,
    endpoint: String,
    model: String,
    reasoning_effort: String,
}

impl Llm {
    /// `endpoint` ist die Basis-URL inklusive `/v1`
    /// (z. B. `http://localhost:11434/v1`); angehängt wird `/chat/completions`.
    /// Ein abschließender `/` wird getrimmt, damit die URL nicht doppelt
    /// getrennt wird.
    pub fn new(
        endpoint: impl Into<String>,
        model: impl Into<String>,
        reasoning_effort: impl Into<String>,
    ) -> Self {
        let endpoint = endpoint.into().trim_end_matches('/').to_string();
        Self {
            http: reqwest::Client::new(),
            endpoint,
            model: model.into(),
            reasoning_effort: reasoning_effort.into(),
        }
    }

    /// Startet die Anfrage und liefert einen Kanal, über den die Text-Deltas
    /// in Ankunftsreihenfolge kommen. Der Kanal schließt am Ende des Streams;
    /// ein Fehler wird als letztes Element gesendet.
    ///
    /// Bewusst nicht `async`: der Aufrufer bekommt den Receiver sofort, die
    /// HTTP-Anfrage läuft nebenher in einer eigenen Task.
    pub fn stream_chat(&self, messages: Vec<Message>) -> mpsc::Receiver<Result<String>> {
        let (tx, rx) = mpsc::channel::<Result<String>>(64);
        let this = self.clone();

        tokio::spawn(async move {
            if let Err(e) = this.run_stream(messages, &tx).await {
                // Fehler ist immer das letzte Element; schlägt auch das fehl,
                // ist der Empfänger ohnehin weg.
                let _ = tx.send(Err(e)).await;
            }
        });

        rx
    }

    /// Die eigentliche Anfrage samt SSE-Auswertung.
    async fn run_stream(
        &self,
        messages: Vec<Message>,
        tx: &mpsc::Sender<Result<String>>,
    ) -> Result<()> {
        let url = format!("{}/chat/completions", self.endpoint);
        // `reasoning_effort: "none"` schaltet die Denkphase ab. Bei
        // gemma4:e2b sind das gemessen 3,2 s statt 0,5 s bis zur Antwort —
        // für einen Sprach-Agenten der mit Abstand größte Einzelposten.
        // Ollamas eigenes `think: false` wirkt am OpenAI-Endpunkt *nicht*,
        // dieses Feld schon; Modelle ohne Denkphase ignorieren es.
        let body = serde_json::json!({
            "model": self.model,
            "messages": messages,
            "stream": true,
            "reasoning_effort": self.reasoning_effort,
        });

        let resp = self
            .http
            .post(&url)
            .json(&body)
            .send()
            .await
            .with_context(|| format!("LLM nicht erreichbar: {url}"))?;

        let status = resp.status();
        if !status.is_success() {
            // Ohne den Body ist ein 400/404 nicht zu debuggen — Ollama legt
            // dort die eigentliche Ursache ab (z. B. Modell nicht installiert).
            let body = resp
                .text()
                .await
                .unwrap_or_else(|e| format!("<Body nicht lesbar: {e}>"));
            anyhow::bail!("LLM antwortete mit {status}: {body}");
        }

        let mut stream = resp.bytes_stream();
        // Byte- statt String-Puffer: ein TCP-Chunk kann mitten in einem
        // Mehrbyte-Zeichen (Umlaut, Emoji) enden. Erst die vollständige Zeile
        // wird dekodiert.
        let mut buf: Vec<u8> = Vec::new();

        while let Some(chunk) = stream.next().await {
            let chunk = chunk.context("Abbruch beim Lesen des LLM-Streams")?;
            buf.extend_from_slice(&chunk);

            // Nur bis zum letzten `\n` konsumieren — ein SSE-Event kann über
            // mehrere Chunks zerfallen, der Rest bleibt im Puffer.
            while let Some(nl) = buf.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = buf.drain(..=nl).collect();
                let line = String::from_utf8_lossy(&line[..nl]);

                match handle_line(&line, tx).await? {
                    Flow::Continue => {}
                    Flow::Stop => return Ok(()),
                }
            }
        }

        // Rest ohne abschließendes `\n` (Ollama beendet den Stream nach
        // `data: [DONE]` teils ohne Newline).
        if !buf.is_empty() {
            let line = String::from_utf8_lossy(&buf).into_owned();
            handle_line(&line, tx).await?;
        }

        Ok(())
    }
}

/// Ob nach einer Zeile weitergelesen wird oder Schluss ist.
enum Flow {
    Continue,
    Stop,
}

/// Wertet eine einzelne SSE-Zeile aus und schiebt ein etwaiges Delta in `tx`.
///
/// Leere Zeilen (Event-Trenner) und alles ohne `data: `-Präfix wird ignoriert.
async fn handle_line(line: &str, tx: &mpsc::Sender<Result<String>>) -> Result<Flow> {
    let line = line.trim_end();

    let Some(payload) = line.strip_prefix("data: ") else {
        return Ok(Flow::Continue);
    };

    if payload == "[DONE]" {
        return Ok(Flow::Stop);
    }

    let value: serde_json::Value =
        serde_json::from_str(payload).with_context(|| format!("SSE-Event unlesbar: {payload}"))?;

    // Fehlendes `content` ist normal: reine Rollen-Deltas, Reasoning-Tokens
    // (Ollama legt die neben `content` ab) und das `finish_reason`-Event.
    let Some(delta) = value
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("delta"))
        .and_then(|d| d.get("content"))
        .and_then(|c| c.as_str())
    else {
        return Ok(Flow::Continue);
    };

    if delta.is_empty() {
        return Ok(Flow::Continue);
    }

    // Send-Fehler heißt: Empfänger ist weg, die Antwort interessiert niemanden
    // mehr. Sauber aufhören, nicht als Fehler behandeln.
    if tx.send(Ok(delta.to_string())).await.is_err() {
        return Ok(Flow::Stop);
    }

    Ok(Flow::Continue)
}
