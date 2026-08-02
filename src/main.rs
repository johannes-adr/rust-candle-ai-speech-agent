//! Sprach-Agent mit Qwen3 über Crane/Candle.
//!
//! Ohne Argumente startet der Server mit der WebUI (Speech-to-Speech und
//! Text-to-Speech):
//!
//! ```bash
//! cargo run --release
//! ```
//!
//! Mit Argumenten bleibt der ursprüngliche Einmal-Modus erhalten, der eine
//! WAV-Datei schreibt:
//!
//! ```bash
//! # 1) Text-to-Speech mit einer vorgegebenen Stimme (CustomVoice-Modell)
//! cargo run --release -- "Hallo, ich bin eine Stimme aus Rust."
//!
//! # 2) Voice Cloning aus einer Referenz-Aufnahme (Base-Modell)
//! cargo run --release -- "Hallo, ich klinge wie du." stimme.wav stimme.txt
//! ```
//!
//! `stimme.txt` enthält das Transkript von `stimme.wav` — das Base-Modell
//! braucht beides (Audio + Text), um die Stimme zu übernehmen.

mod llm;
mod pipeline;
mod stt;
mod tts;
mod voices;
mod web;

use std::sync::Arc;

use anyhow::{Context, Result};
use crane_core::generation::SpeechOptions;
use crane_core::models::{DType, Device};

use crate::llm::Llm;
use crate::pipeline::Pipeline;
use crate::stt::Stt;
use crate::tts::{AudioChunk, Reference, SpeechRequest, Tts, TtsConfig};
use crate::voices::VoiceStore;

/// Modell für vorgegebene Sprecher (Preset-Stimmen).
const CUSTOM_VOICE_MODEL: &str = "models/Qwen3-TTS-12Hz-0.6B-CustomVoice";
/// Modell für Voice Cloning (In-Context-Learning aus Referenz-Audio).
const BASE_MODEL: &str = "models/Qwen3-TTS-12Hz-0.6B-Base";
/// Modell für Spracherkennung — Crane erwartet das flache `-hf`-Layout.
const ASR_MODEL: &str = "models/Qwen3-ASR-0.6B-hf";
/// Ablage geklonter Stimmen: je Stimme `<name>.wav` plus `<name>.txt`.
const VOICES_DIR: &str = "voices";

const LANGUAGE: &str = "german";
const OUT_DIR: &str = "out";

const LLM_ENDPOINT: &str = "http://localhost:11434/v1";
const LLM_MODEL: &str = "gemma4:e2b";
/// `"none"` schaltet die Denkphase ab — bei gemma4:e2b gemessen 0,5 s statt
/// 3,2 s bis zur Antwort. Für Modelle, deren Qualität am Denken hängt, hier
/// `"low"`/`"medium"`/`"high"` setzen.
const LLM_REASONING: &str = "none";
const BIND: &str = "127.0.0.1:8080";

const SYSTEM_PROMPT: &str = "Du bist ein gesprochener Assistent. Antworte auf Deutsch, \
kurz und in vollständigen Sätzen. Keine Aufzählungen, keine Formatierung, keine Emojis \
— alles, was du schreibst, wird vorgelesen.";

/// Sample-Rate, die der Speaker-Encoder für Referenz-Audio erwartet.
const SPEAKER_ENCODER_SR: u32 = 16_000;

/// Umgebungsvariable lesen, sonst den Default nehmen.
fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

/// `MODE=tts` schaltet Speech-to-Speech ab: ASR und LLM werden nicht geladen
/// und die WebUI blendet den Modus aus.
fn tts_only() -> bool {
    env_or("MODE", "full").eq_ignore_ascii_case("tts")
}

fn speech_options() -> SpeechOptions {
    SpeechOptions {
        max_new_tokens: 2048,
        temperature: 0.9,
        top_p: Some(1.0),
        repetition_penalty: 1.05,
    }
}

/// Auf Apple Silicon läuft alles auf der GPU (Metal), sonst CPU.
fn device() -> Device {
    let device = Device::new_metal(0).unwrap_or(Device::Cpu);
    println!("Device    : {device:?}");
    device
}

fn dtype(key: &str, default: DType) -> DType {
    match std::env::var(key).as_deref() {
        Ok("f16") => DType::F16,
        Ok("f32") => DType::F32,
        _ => default,
    }
}

/// TTS bleibt in F32: in F16 laufen die Logits des Talkers über und das
/// Sampling bricht mit „A weight is negative, too large or not a valid
/// number" ab.
fn tts_dtype() -> DType {
    dtype("TTS_DTYPE", DType::F32)
}

/// ASR läuft sauber in F16 — und muss es auch: beide Modelle zusammen in F32
/// sind rund 6,7 GB und sprengen neben dem LLM das Metal-Working-Set
/// (`kIOGPUCommandBufferCallbackErrorOutOfMemory`).
fn asr_dtype() -> DType {
    dtype("ASR_DTYPE", DType::F16)
}

fn load_reference(wav_path: &str, txt_path: &str) -> Result<Reference> {
    let transcript = std::fs::read_to_string(txt_path)
        .with_context(|| format!("Transkript nicht lesbar: {txt_path}"))?;
    let samples = crane::audio::load_wav_f32(wav_path, SPEAKER_ENCODER_SR)
        .with_context(|| format!("Referenz-Audio nicht lesbar: {wav_path}"))?;
    Ok(Reference {
        samples,
        transcript,
    })
}

fn tts_config(model_path: String, reference: Option<Reference>) -> TtsConfig {
    TtsConfig {
        model_path,
        language: LANGUAGE.to_string(),
        speaker: std::env::var("TTS_SPEAKER").ok(),
        reference,
        stream: env_or("TTS_STREAM", "1") != "0",
        opts: speech_options(),
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let device = device();

    match args.as_slice() {
        [] => serve(device).await,
        [text] => oneshot(text, None, device).await,
        [text, wav, txt] => oneshot(text, Some((wav.as_str(), txt.as_str())), device).await,
        _ => anyhow::bail!("Aufruf: [<text> [<referenz.wav> <referenz.txt>]]"),
    }
}

/// Server mit WebUI: STT + LLM + TTS als durchgehende Pipeline.
async fn serve(device: Device) -> Result<()> {
    // Sind REF_WAV/REF_TXT gesetzt, spricht der Agent mit geklonter Stimme.
    let reference = match (std::env::var("REF_WAV"), std::env::var("REF_TXT")) {
        (Ok(wav), Ok(txt)) => {
            println!("Referenz  : {wav}");
            Some(load_reference(&wav, &txt)?)
        }
        _ => None,
    };

    let default_model = if reference.is_some() {
        BASE_MODEL
    } else {
        CUSTOM_VOICE_MODEL
    };
    let tts_model = env_or("TTS_MODEL", default_model);
    let asr_model = env_or("ASR_MODEL", ASR_MODEL);

    println!("Lade TTS-Modell: {tts_model} ({:?})", tts_dtype());
    let tts = Tts::spawn(tts_config(tts_model, reference), device.clone(), tts_dtype())?;

    let caps = tts.capabilities();
    println!("Sprachen  : {}", caps.languages.join(", "));
    if caps.cloning {
        println!("Stimme    : Voice Cloning (Base-Checkpoint, Referenz nötig)");
    } else {
        println!("Stimmen   : {}", caps.speakers.join(", "));
    }

    // MODE=tts lädt ASR und LLM gar nicht erst — spart auf einer 24-GB-Kiste
    // rund 1,6 GB VRAM und die halbe Startzeit.
    let (stt, llm) = if tts_only() {
        println!("Modus     : nur Text-to-Speech (ASR und LLM werden nicht geladen)");
        (None, None)
    } else {
        println!("Lade ASR-Modell: {asr_model} ({:?})", asr_dtype());
        // Qwen3-ASR erkennt die Sprache selbst; der Prompt kennt keinen
        // Sprach-Hinweis, deshalb `None`.
        let stt = Stt::spawn(&asr_model, None, device, asr_dtype())?;

        let endpoint = env_or("LLM_ENDPOINT", LLM_ENDPOINT);
        let model = env_or("LLM_MODEL", LLM_MODEL);
        let reasoning = env_or("LLM_REASONING", LLM_REASONING);
        println!("LLM       : {model} @ {endpoint} (reasoning: {reasoning})");

        (Some(stt), Some(Llm::new(endpoint, model, reasoning)))
    };

    let voices = Arc::new(VoiceStore::new(env_or("VOICES_DIR", VOICES_DIR)));
    let gespeichert = voices.list();
    println!(
        "Stimmen-Ablage: {} ({})",
        voices.dir().display(),
        if gespeichert.is_empty() {
            "leer".to_string()
        } else {
            gespeichert.join(", ")
        }
    );

    let pipeline = Arc::new(Pipeline::new(stt, llm, tts, SYSTEM_PROMPT));

    let addr = env_or("BIND", BIND)
        .parse()
        .context("BIND ist keine gültige Adresse (erwartet z. B. 127.0.0.1:8080)")?;
    web::serve(pipeline, voices, addr).await
}

/// Einmal synthetisieren und als WAV ablegen — der ursprüngliche CLI-Modus.
async fn oneshot(text: &str, reference: Option<(&str, &str)>, device: Device) -> Result<()> {
    let cloning = reference.is_some();
    let reference = match reference {
        Some((wav, txt)) => {
            println!("Referenz  : {wav}");
            Some(load_reference(wav, txt)?)
        }
        None => None,
    };

    let model_path = if cloning { BASE_MODEL } else { CUSTOM_VOICE_MODEL };
    println!("Lade Modell: {model_path}");
    println!("Text      : {text}");

    let tts = Tts::spawn(tts_config(model_path.to_string(), reference), device, tts_dtype())?;

    std::fs::create_dir_all(OUT_DIR)?;
    let out_path = if cloning {
        format!("{OUT_DIR}/clone.wav")
    } else {
        format!("{OUT_DIR}/tts.wav")
    };

    let started = std::time::Instant::now();

    // Die Chunks des Satzes wieder zu einer Datei zusammensetzen.
    let mut chunks = tts.synthesize(SpeechRequest::new(text));
    let mut samples = Vec::new();
    let mut sample_rate = 0;
    while let Some(chunk) = chunks.recv().await {
        let chunk = chunk?;
        sample_rate = chunk.sample_rate;
        samples.extend_from_slice(&chunk.samples);
    }
    anyhow::ensure!(!samples.is_empty(), "Keine Audiodaten erzeugt");

    let audio = AudioChunk {
        samples,
        sample_rate,
    };
    std::fs::write(&out_path, audio.to_wav()?)?;

    println!(
        "Gespeichert: {out_path}  ({sample_rate} Hz, {:.1}s Audio) in {:.1?}",
        audio.samples.len() as f32 / sample_rate as f32,
        started.elapsed()
    );
    Ok(())
}
