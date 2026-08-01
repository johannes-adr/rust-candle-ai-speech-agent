//! WebUI: HTTP-Server für die Sprach-Pipeline.
//!
//! Der Server ist bewusst dünn — er übersetzt nur zwischen Browser und
//! [`Pipeline`]: rohes PCM bzw. Text rein, ein SSE-Stream aus JSON-Events
//! zurück. Jede Anfrage bekommt von der Pipeline einen eigenen
//! [`mpsc::Receiver`], der wieder in einen Stream verpackt wird; schließt der
//! Kanal, endet der SSE-Stream (nach einem abschließenden `done`-Event).
//!
//! Das Frontend ist per [`include_str!`] fest einkompiliert — kein
//! Filesystem-Serving zur Laufzeit, damit die Binary allein lauffähig bleibt.

use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::http::header;
use axum::response::IntoResponse;
use axum::response::sse::{Event as SseEvent, Sse};
use axum::routing::{get, post};
use base64::Engine;
use futures_util::stream::{Stream, StreamExt};
use serde_json::json;
use tokio::sync::mpsc;

use crate::pipeline::{Event, Pipeline};

/// Das komplette Frontend — eine Datei, alles inline.
const INDEX_HTML: &str = include_str!("../static/index.html");

/// Startet den HTTP-Server und blockiert, bis er endet.
pub async fn serve(pipeline: Arc<Pipeline>, addr: SocketAddr) -> Result<()> {
    let app = Router::new()
        .route("/", get(index))
        .route("/api/config", get(config))
        .route("/api/tts", post(tts))
        .route("/api/s2s", post(s2s))
        .with_state(pipeline);

    let listener = tokio::net::TcpListener::bind(addr)
        .await
        .with_context(|| format!("Adresse nicht bindbar: {addr}"))?;

    // Die tatsächlich gebundene Adresse ausgeben (Port 0 = vom OS vergeben).
    let local = listener.local_addr().context("Lokale Adresse unbekannt")?;
    println!("WebUI: http://{local}");

    axum::serve(listener, app)
        .await
        .context("Web-Server abgebrochen")
}

/// `GET /` — das einkompilierte Frontend.
async fn index() -> impl IntoResponse {
    (
        [(header::CONTENT_TYPE, "text/html; charset=utf-8")],
        INDEX_HTML,
    )
}

/// `GET /api/config` — was der Browser wissen muss, bevor er aufnimmt.
async fn config(State(pipeline): State<Arc<Pipeline>>) -> impl IntoResponse {
    axum::Json(json!({ "sample_rate": pipeline.stt_sample_rate() }))
}

/// `POST /api/tts` — Body ist der Text (text/plain), Antwort ein SSE-Stream.
async fn tts(State(pipeline): State<Arc<Pipeline>>, text: String) -> impl IntoResponse {
    sse_from(pipeline.text_to_speech(text))
}

/// `POST /api/s2s` — Body ist rohes Mono-PCM als little-endian `f32` mit
/// [`Pipeline::stt_sample_rate`]; Antwort ist ein SSE-Stream.
async fn s2s(State(pipeline): State<Arc<Pipeline>>, body: Bytes) -> impl IntoResponse {
    // Ein angeschnittenes letztes Sample (Body-Länge kein Vielfaches von 4)
    // wird von `chunks_exact` einfach verworfen.
    let samples: Vec<f32> = body
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();

    sse_from(pipeline.speech_to_speech(samples))
}

/// Einen Pipeline-Kanal in einen SSE-Stream verwandeln.
///
/// `unfold` zieht solange Events aus dem Receiver, bis dieser schließt —
/// `recv()` liefert dann `None` und beendet damit den Stream. Erst danach geht
/// per `chain` noch das abschließende `done`-Event raus.
fn sse_from(rx: mpsc::Receiver<Event>) -> Sse<impl Stream<Item = Result<SseEvent, Infallible>>> {
    let events = futures_util::stream::unfold(rx, |mut rx| async move {
        rx.recv().await.map(|event| (event, rx))
    })
    .map(|event| Ok(SseEvent::default().data(encode(event).to_string())));

    let done = futures_util::stream::once(async {
        Ok(SseEvent::default().data(json!({ "type": "done" }).to_string()))
    });

    Sse::new(events.chain(done))
}

/// Ein Pipeline-Event als JSON für das Frontend.
fn encode(event: Event) -> serde_json::Value {
    match event {
        Event::Transcript(text) => json!({ "type": "transcript", "text": text }),
        Event::Delta(text) => json!({ "type": "delta", "text": text }),
        Event::Audio(chunk) => match chunk.to_wav() {
            Ok(wav) => {
                let wav = base64::engine::general_purpose::STANDARD.encode(&wav);
                json!({ "type": "audio", "wav": wav })
            }
            // Ein kaputter Chunk soll den Stream nicht abreißen lassen — der
            // Browser bekommt stattdessen einen Fehler angezeigt.
            Err(e) => json!({ "type": "error", "message": format!("WAV-Kodierung fehlgeschlagen: {e}") }),
        },
        Event::Error(message) => json!({ "type": "error", "message": message }),
    }
}
