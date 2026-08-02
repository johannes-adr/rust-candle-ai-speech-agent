//! WebUI: HTTP-Server für die Sprach-Pipeline.
//!
//! Der Server ist bewusst dünn — er übersetzt nur zwischen Browser und
//! [`Pipeline`]: rohes PCM bzw. ein Text-Auftrag rein, ein SSE-Stream aus
//! JSON-Events zurück. Jede Anfrage bekommt von der Pipeline einen eigenen
//! [`mpsc::Receiver`], der wieder in einen Stream verpackt wird; schließt der
//! Kanal, endet der SSE-Stream (nach einem abschließenden `done`-Event).
//!
//! Was der Prozess kann, hängt am Start: ohne ASR und LLM (`MODE=tts`) gibt es
//! nur Text-to-Speech, und das eine geladene TTS-Checkpoint entscheidet, ob
//! Preset-Stimmen oder Voice Cloning zur Verfügung stehen. `GET /api/config`
//! macht beides für das Frontend sichtbar; Anfragen, die dazu nicht passen,
//! werden hier abgelehnt, statt sie in die Pipeline durchzureichen.
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
use axum::http::{StatusCode, header};
use axum::response::sse::{Event as SseEvent, Sse};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use base64::Engine;
use futures_util::stream::{Stream, StreamExt};
use serde::Deserialize;
use serde_json::json;
use tokio::sync::mpsc;

use crate::pipeline::{Event, Pipeline};
use crate::tts::{Reference, SpeechRequest};
use crate::voices::{REFERENCE_SAMPLE_RATE, VoiceStore};

/// Das komplette Frontend — eine Datei, alles inline.
const INDEX_HTML: &str = include_str!("../static/index.html");

/// Was die Handler brauchen: die Pipeline und die Ablage gespeicherter
/// Stimmen. Getrennt gehalten, weil die Ablage nichts mit dem Datenfluss
/// STT → LLM → TTS zu tun hat.
#[derive(Clone)]
struct AppState {
    pipeline: Arc<Pipeline>,
    voices: Arc<VoiceStore>,
}

/// Startet den HTTP-Server und blockiert, bis er endet.
pub async fn serve(
    pipeline: Arc<Pipeline>,
    voices: Arc<VoiceStore>,
    addr: SocketAddr,
) -> Result<()> {
    let app = Router::new()
        .route("/", get(index))
        .route("/api/config", get(config))
        .route("/api/voices", get(voices_list))
        .route("/api/tts", post(tts))
        .route("/api/s2s", post(s2s))
        .with_state(AppState { pipeline, voices });

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

/// `GET /api/config` — was der Browser wissen muss, bevor er loslegt.
///
/// Daraus baut das Frontend seine Oberfläche: ob es den Speech-to-Speech-Tab
/// überhaupt zeigt (`MODE=tts` lädt weder ASR noch LLM), welche Sprachen und
/// Preset-Stimmen zur Auswahl stehen und ob Voice Cloning möglich ist. Preset-
/// Stimmen und Cloning schließen sich aus — welches von beiden gilt, entscheidet
/// das eine geladene Checkpoint.
async fn config(State(state): State<AppState>) -> impl IntoResponse {
    let caps = state.pipeline.capabilities();
    // `None` heißt: kein STT geladen. Der Wert wird zu JSON-`null`, und
    // `speech_to_speech` sagt dem Browser dasselbe noch einmal als Flag.
    let sample_rate = state.pipeline.stt_sample_rate();

    axum::Json(json!({
        "speech_to_speech": sample_rate.is_some(),
        "sample_rate": sample_rate,
        "languages": caps.languages,
        "voices": caps.speakers,
        "voice_cloning": caps.cloning,
        "saved_voices": state.voices.list(),
    }))
}

/// `GET /api/voices` — nur die Liste gespeicherter Stimmen.
///
/// Dieselbe Information wie in `/api/config`, aber einzeln abrufbar: nach dem
/// Speichern einer neuen Stimme lädt das Frontend nur diese Liste neu.
async fn voices_list(State(state): State<AppState>) -> impl IntoResponse {
    axum::Json(state.voices.list())
}

/// Body von `POST /api/tts`.
///
/// Außer `text` ist alles optional; fehlende Felder bedeuten „Server-Default
/// nehmen". `reference_wav` ist eine base64-kodierte WAV-Datei und gehört
/// zwingend mit `reference_text` zusammen.
#[derive(Deserialize)]
struct TtsRequest {
    text: String,
    #[serde(default)]
    language: Option<String>,
    #[serde(default)]
    speaker: Option<String>,
    #[serde(default)]
    reference_wav: Option<String>,
    #[serde(default)]
    reference_text: Option<String>,
    /// Name einer gespeicherten Stimme statt einer frisch hochgeladenen
    /// Referenz.
    #[serde(default)]
    voice: Option<String>,
    /// Die hochgeladene Referenz unter diesem Namen ablegen.
    #[serde(default)]
    save_as: Option<String>,
}

/// `POST /api/tts` — Body ist JSON ([`TtsRequest`]), Antwort ein SSE-Stream.
///
/// Unbrauchbare Referenz-Daten sind ein Fehler des Aufrufers und werden mit
/// HTTP 400 beantwortet, nicht erst mitten im Stream.
async fn tts(State(state): State<AppState>, axum::Json(req): axum::Json<TtsRequest>) -> Response {
    let pipeline = &state.pipeline;
    let upload = normalize(req.reference_wav.clone()).is_some();
    let voice = normalize(req.voice);
    let save_as = normalize(req.save_as);

    // Beide Wege gleichzeitig wäre mehrdeutig — lieber ablehnen als raten.
    if voice.is_some() && upload {
        return bad_request(
            "Entweder eine gespeicherte Stimme wählen oder eine neue Referenz hochladen — nicht beides.",
        );
    }
    if save_as.is_some() && !upload {
        return bad_request("'save_as' braucht eine hochgeladene Referenz-Aufnahme.");
    }

    let reference = match build_reference(req.reference_wav.clone(), req.reference_text.clone()) {
        Ok(reference) => reference,
        Err(message) => return bad_request(message),
    };

    // Erst ablegen, dann sprechen: schlägt das Speichern fehl, soll der
    // Aufrufer das als Fehler sehen und nicht bloß Audio bekommen, während
    // die Stimme still verloren geht.
    if let Some(name) = &save_as {
        let wav = match decode_base64(req.reference_wav.as_deref().unwrap_or_default()) {
            Ok(wav) => wav,
            Err(message) => return bad_request(message),
        };
        let transcript = req.reference_text.as_deref().unwrap_or_default();
        if let Err(e) = state.voices.save(name, &wav, transcript) {
            return bad_request(format!("Stimme nicht speicherbar: {e:#}"));
        }
    }

    // Gespeicherte Stimme laden, falls keine frische Referenz dabei war.
    let reference = match (reference, voice) {
        (Some(reference), _) => Some(reference),
        (None, Some(name)) => match state.voices.load(&name) {
            Ok(reference) => Some(reference),
            Err(e) => return bad_request(format!("Stimme '{name}' nicht ladbar: {e:#}")),
        },
        (None, None) => None,
    };

    // Das Base-Checkpoint kann ohne Referenz gar nichts. Ohne diese Prüfung
    // liefe die Anfrage bis ins Modell und käme als englische Crane-Meldung
    // mitten im SSE-Stream zurück — für den Aufrufer ein 400.
    if pipeline.capabilities().cloning && reference.is_none() {
        return (
            StatusCode::BAD_REQUEST,
            "Dieses Modell (Base-Checkpoint) spricht nur mit Referenz-Aufnahme. \
             Wähle eine gespeicherte Stimme oder lade eine WAV-Datei samt \
             Transkript hoch — oder starte den Server mit dem \
             CustomVoice-Checkpoint für Preset-Stimmen.",
        )
            .into_response();
    }

    let request = SpeechRequest {
        text: req.text,
        language: normalize(req.language),
        speaker: normalize(req.speaker),
        reference,
    };

    sse_from(pipeline.text_to_speech(request)).into_response()
}

/// HTTP 400 mit deutschsprachiger Meldung im Body.
fn bad_request(message: impl Into<String>) -> Response {
    (StatusCode::BAD_REQUEST, message.into()).into_response()
}

/// `POST /api/s2s` — Body ist rohes Mono-PCM als little-endian `f32` mit
/// [`Pipeline::stt_sample_rate`]; Antwort ist ein SSE-Stream.
async fn s2s(State(state): State<AppState>, body: Bytes) -> Response {
    let pipeline = &state.pipeline;
    // Ein angeschnittenes letztes Sample (Body-Länge kein Vielfaches von 4)
    // wird von `chunks_exact` einfach verworfen.
    let samples: Vec<f32> = body
        .chunks_exact(4)
        .map(|b| f32::from_le_bytes([b[0], b[1], b[2], b[3]]))
        .collect();

    match pipeline.speech_to_speech(samples) {
        Some(rx) => sse_from(rx).into_response(),
        // Kein STT oder kein LLM geladen — daran ändert auch ein Retry nichts.
        None => (
            StatusCode::CONFLICT,
            "Speech-to-Speech ist nicht aktiv (MODE=tts).",
        )
            .into_response(),
    }
}

/// Leere bzw. nur aus Leerzeichen bestehende Angaben zählen als „nicht gesetzt".
///
/// So muss das Frontend ein ausgeblendetes Feld nicht extra weglassen.
fn normalize(value: Option<String>) -> Option<String> {
    value
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// Referenz-Aufnahme aus base64-WAV und Transkript bauen.
///
/// Voice Cloning braucht beides: ohne Transkript kann das Modell die
/// Referenz nicht ausrichten, ohne Audio gibt es nichts zu klonen. Halbe
/// Angaben sind deshalb ein Fehler und keine stille Rückkehr zur Preset-Stimme.
/// Das `Err` ist die fertige, deutschsprachige Meldung für HTTP 400.
fn build_reference(
    wav: Option<String>,
    transcript: Option<String>,
) -> Result<Option<Reference>, String> {
    match (normalize(wav), normalize(transcript)) {
        (None, None) => Ok(None),
        (Some(_), None) => {
            Err("Referenz-Audio ohne Transkript — Voice Cloning braucht beides.".to_string())
        }
        (None, Some(_)) => {
            Err("Transkript ohne Referenz-Audio — Voice Cloning braucht beides.".to_string())
        }
        (Some(wav), Some(transcript)) => {
            let bytes = decode_base64(&wav)?;

            let samples = crane::audio::decode_wav(&bytes, REFERENCE_SAMPLE_RATE)
                .map_err(|e| format!("Referenz-Audio nicht lesbar (WAV erwartet): {e:#}"))?;

            Ok(Some(Reference {
                samples,
                transcript,
            }))
        }
    }
}

/// Base64 dekodieren; das `Err` ist die fertige Meldung für HTTP 400.
fn decode_base64(value: &str) -> Result<Vec<u8>, String> {
    base64::engine::general_purpose::STANDARD
        .decode(value.as_bytes())
        .map_err(|e| format!("Referenz-Audio ist kein gültiges Base64: {e}"))
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
