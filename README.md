# rust-candle-ai-speech-agent

afconvert -f WAVE -d LEI16@24000 "Ohne Titel.m4a" stimme.wav

Minimalbeispiel: **Text-to-Speech** und **Voice Cloning** mit Qwen3-TTS,
direkt in Rust über [Crane](https://github.com/lucasjinreal/Crane) (Candle).
Kein Server, kein Python — ein `main.rs`, das eine WAV-Datei schreibt.

Auf Apple Silicon läuft das Modell über Metal auf der GPU, sonst auf der CPU.

## 1. Modelle laden

Zwei Checkpoints, je nach Modus (zusammen ca. 3 GB):

```bash
hf download Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice --local-dir models/Qwen3-TTS-12Hz-0.6B-CustomVoice
```

```bash
hf download Qwen/Qwen3-TTS-12Hz-0.6B-Base --local-dir models/Qwen3-TTS-12Hz-0.6B-Base
```

(Ältere `huggingface_hub`-Versionen: `huggingface-cli download …`.)

Die GGUF-Dateien aus dem `qwentts.cpp`-Projekt funktionieren hier **nicht** —
Crane lädt die HF-Safetensors-Ordner.

## 2. Sprechen lassen

Vorgegebene Stimme (CustomVoice-Modell):

```bash
cargo run --release -- "Hallo, ich bin eine Stimme aus Rust."
```

→ `out/tts.wav`

## 3. Stimme klonen

Referenz-Aufnahme + zugehöriges Transkript übergeben (Base-Modell):

```bash
cargo run --release -- "Hallo, ich klinge wie du." stimme.wav stimme.txt
```

→ `out/clone.wav`

`stimme.wav` ist ein kurzer, sauberer Ausschnitt (~5–15 s) der Zielstimme,
`stimme.txt` enthält exakt das, was darin gesagt wird. Das Base-Modell braucht
beides: es lernt die Stimme in-context aus Audio **und** Text. Das Sample-Rate
der Datei ist egal, Crane resampelt beim Laden.

## Stellschrauben

Alles in [src/main.rs](src/main.rs):

| Konstante                      | Bedeutung                                                           |
| ------------------------------ | ------------------------------------------------------------------- |
| `LANGUAGE`                     | `"german"`, `"english"`, `"chinese"`, `"japanese"`, … oder `"auto"` |
| `SpeechOptions.temperature`    | niedriger = ruhiger/monotoner, höher = variabler                    |
| `SpeechOptions.max_new_tokens` | Längenlimit (2048 ≈ knapp 3 Minuten bei 12 Hz)                      |

## Warum `.cargo/config.toml`

candle 0.11 kompiliert auf Apple Silicon einen NEON-f16-Pfad, der Intrinsics
aus dem noch instabilen `stdarch_neon_f16` benutzt — auf stable Rust ein
harter Compile-Fehler. [.cargo/config.toml](.cargo/config.toml) schaltet das
Target-Feature `fp16` ab, damit candle den generischen f16-Pfad nimmt. Für
dieses Beispiel folgenlos (f32 auf Metal). Die Datei kann weg, sobald das
Feature stabilisiert ist oder du auf nightly baust.

## Stimmen

Der Lauf gibt die im Checkpoint vorhandenen Stimmen aus (`Verfügbare
Stimmen: [...]`); für eine andere Preset-Stimme dort einen Namen fest
eintragen statt `speakers.first()`.
