//! Sehr simples Sprach-Beispiel mit Qwen3-TTS über Crane/Candle.
//!
//! Zwei Modi — der Modus ergibt sich daraus, ob eine Referenz-Aufnahme
//! übergeben wird:
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

use anyhow::{Context, Result};
use crane_core::generation::SpeechOptions;
use crane_core::models::qwen3_tts::Model;
use crane_core::models::{DType, Device};

/// Modell für vorgegebene Sprecher (Preset-Stimmen).
const CUSTOM_VOICE_MODEL: &str = "models/Qwen3-TTS-12Hz-0.6B-CustomVoice";
/// Modell für Voice Cloning (In-Context-Learning aus Referenz-Audio).
const BASE_MODEL: &str = "models/Qwen3-TTS-12Hz-0.6B-Base";

const LANGUAGE: &str = "german";
const OUT_DIR: &str = "out";

fn main() -> Result<()> {
    let mut args = std::env::args().skip(1);
    let mut text = args
        .next()
        .unwrap_or_else(|| "Hallo, ich bin eine Stimme aus Rust.".to_string());
    text = "Er stieg in das Boot, setzte wieder über und kam in seine Stadt. Da brachte man einen Gelähmten zu Ihm, der auf einem Bett lag. Als Jesus ihren Glauben sah, sprach Er zu dem Gelähmten: ‚Hab Vertrauen, mein Sohn; deine Sünden sind dir vergeben.‘ Einige Schriftgelehrte dachten bei sich: ‚Dieser lästert Gott.‘ Da Jesus ihre Gedanken erkannte, sprach Er: ‚Warum hegt ihr böse Gedanken in euren Herzen? Was ist leichter zu sagen: Deine Sünden sind dir vergeben, oder zu sagen: Steh auf und geh umher? Damit ihr aber wißt, daß der Menschensohn Vollmacht hat, auf Erden Sünden zu vergeben – sprach Er zu dem Gelähmten – steh auf, nimm dein Bett und geh nach Hause!‘ Da stand er auf und ging nach Hause. Als die Volksmenge dies sah, geriet sie in Furcht und pries Gott, der den Menschen eine solche Vollmacht gegeben hatte.".to_owned();
    let ref_wav = args.next();
    let ref_txt = args.next();

    // Auf Apple Silicon läuft das Modell auf der GPU (Metal), sonst CPU.
    let device = Device::new_metal(0).unwrap_or(Device::Cpu);
    let dtype = DType::F32;
    println!("Device: {device:?}  dtype: {dtype:?}");

    std::fs::create_dir_all(OUT_DIR)?;

    let opts = SpeechOptions {
        max_new_tokens: 2048,
        temperature: 0.9,
        top_p: Some(1.0),
        repetition_penalty: 1.05,
    };

    let started = std::time::Instant::now();

    let (audio, sample_rate, out_path) = match (ref_wav, ref_txt) {
        // ── Voice Cloning ──────────────────────────────────────────────
        (Some(wav_path), Some(txt_path)) => {
            println!("Lade Base-Modell: {BASE_MODEL}");
            let mut model = Model::new(BASE_MODEL, &device, &dtype)?;

            let ref_text = std::fs::read_to_string(&txt_path)
                .with_context(|| format!("Transkript nicht lesbar: {txt_path}"))?;
            let ref_samples =
                crane::audio::load_wav_f32(&wav_path, model.speaker_encoder_sample_rate())
                    .with_context(|| format!("Referenz-Audio nicht lesbar: {wav_path}"))?;

            println!("Referenz : {wav_path}");
            println!("Transkript: {}", ref_text.trim());
            println!("Text     : {text}");

            let (audio, sr) = model.generate_voice_clone(
                &text,
                LANGUAGE,
                &ref_samples,
                ref_text.trim(),
                &opts,
            )?;
            (audio, sr, format!("{OUT_DIR}/clone.wav"))
        }

        // ── Text-to-Speech mit Preset-Stimme ───────────────────────────
        _ => {
            println!("Lade CustomVoice-Modell: {CUSTOM_VOICE_MODEL}");
            let mut model = Model::new(CUSTOM_VOICE_MODEL, &device, &dtype)?;

            // Sprecherliste sortieren, damit der Default reproduzierbar ist.
            let mut speakers: Vec<String> =
                model.config.talker_config.spk_id.keys().cloned().collect();
            speakers.sort();
            println!("Verfügbare Stimmen: {speakers:?}");

            let speaker = speakers.first().cloned();
            println!("Stimme   : {}", speaker.as_deref().unwrap_or("(keine)"));
            println!("Text     : {text}");

            let (audio, sr) = model.generate_speech(&text, LANGUAGE, speaker.as_deref(), &opts)?;
            (audio, sr, format!("{OUT_DIR}/tts.wav"))
        }
    };

    let saved = crane::audio::save_wav(&audio, &out_path, sample_rate)?;
    println!(
        "Gespeichert: {saved}  ({sample_rate} Hz) in {:.1?}",
        started.elapsed()
    );
    Ok(())
}
