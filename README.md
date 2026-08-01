# rust-candle-ai-speech-agent

Sprach-Agent in Rust: **Speech-to-Speech**, **Text-to-Speech** und **Voice
Cloning** — Qwen3-ASR und Qwen3-TTS laufen lokal über
[Crane](https://github.com/lucasjinreal/Crane) (Candle), das LLM über einen
beliebigen OpenAI-kompatiblen Endpunkt (Default: Ollama).

Auf Apple Silicon laufen beide Modelle über Metal auf der GPU, sonst auf der CPU.

## Aufbau

```
Mikrofon ──► stt.rs ──► llm.rs ──► pipeline.rs ──► tts.rs ──► Lautsprecher
             Qwen3-ASR  Streaming   Satz-Puffer     Qwen3-TTS
```

| Modul                            | Aufgabe                                                       |
| -------------------------------- | ------------------------------------------------------------- |
| [stt.rs](src/stt.rs)             | Qwen3-ASR, eigener OS-Thread, `async` ansprechbar             |
| [llm.rs](src/llm.rs)             | OpenAI-kompatibler Chat-Client, konsumiert SSE als Stream     |
| [tts.rs](src/tts.rs)             | Qwen3-TTS, Preset-Stimme oder Voice Cloning                   |
| [pipeline.rs](src/pipeline.rs)   | STT → LLM → satzweise TTS, vollständig über Tokio-Kanäle      |
| [web.rs](src/web.rs)             | HTTP-Server, SSE-Endpunkte                                    |
| [static/index.html](static/index.html) | WebUI, eine Datei, kein Framework                       |

Die Modelle sind nicht `Sync` und ihre Inferenz blockiert. Sie leben deshalb je
auf einem eigenen OS-Thread; `Stt`/`Tts` sind nur klonbare Handles, die
Aufträge über Kanäle dorthin schicken. Damit blockiert nichts die
Tokio-Worker.

**Warum es sich früh anhört:** Die LLM-Antwort wird gepuffert, bis ein Satzende
(`.`, `!`, `?`) erkannt ist — jeder fertige Satz geht sofort in die Synthese
und wird als eigener Audio-Chunk zum Browser gestreamt. Der Browser hängt die
Chunks in eine Warteschlange und spielt sie lückenlos nacheinander ab, während
das LLM noch schreibt.

## 1. Modelle laden

TTS — je nach Modus (zusammen ca. 3 GB):

```bash
hf download Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice --local-dir models/Qwen3-TTS-12Hz-0.6B-CustomVoice
```

```bash
hf download Qwen/Qwen3-TTS-12Hz-0.6B-Base --local-dir models/Qwen3-TTS-12Hz-0.6B-Base
```

ASR — Crane braucht das flache `-hf`-Layout (ca. 1,9 GB):

```bash
hf download Qwen/Qwen3-ASR-0.6B-hf --local-dir models/Qwen3-ASR-0.6B-hf
```

Die GGUF-Dateien aus `qwentts.cpp` funktionieren hier **nicht** — Crane lädt
HF-Safetensors-Ordner.

## 2. LLM bereitstellen

```bash
ollama pull gemma4:e2b
```

Jeder OpenAI-kompatible Endpunkt geht (`LLM_ENDPOINT`), also auch llama.cpp,
vLLM oder die echte OpenAI-API.

## 3. Starten

```bash
cargo run --release
```

→ [http://127.0.0.1:8080](http://127.0.0.1:8080). Zwei Modi in der UI:

- **Speech-to-Speech** — Mikrofon aufnehmen, Antwort anhören
- **Text-to-Speech** — Text eingeben, vorlesen lassen

## Einmal-Modus (ohne Server)

Vorgegebene Stimme (CustomVoice-Modell):

```bash
cargo run --release -- "Hallo, ich bin eine Stimme aus Rust."
```

→ `out/tts.wav`

Stimme klonen — Referenz-Aufnahme plus zugehöriges Transkript (Base-Modell):

```bash
cargo run --release -- "Hallo, ich klinge wie du." stimme.wav stimme.txt
```

→ `out/clone.wav`

`stimme.wav` ist ein kurzer, sauberer Ausschnitt (~5–15 s) der Zielstimme,
`stimme.txt` enthält exakt das, was darin gesagt wird. Das Base-Modell braucht
beides: es lernt die Stimme in-context aus Audio **und** Text. Die Sample-Rate
der Datei ist egal, Crane resampelt beim Laden.

Aufnahme konvertieren:

```bash
afconvert -f WAVE -d LEI16@24000 "Ohne Titel.m4a" stimme.wav
```

## Konfiguration

Alles über Umgebungsvariablen, Defaults in [src/main.rs](src/main.rs):

| Variable       | Default                                     | Bedeutung                                   |
| -------------- | ------------------------------------------- | ------------------------------------------- |
| `BIND`         | `127.0.0.1:8080`                            | Adresse des Web-Servers                     |
| `LLM_ENDPOINT` | `http://localhost:11434/v1`                 | OpenAI-kompatible Basis-URL                 |
| `LLM_MODEL`    | `gemma4:e2b`                                | Modellname beim Endpunkt                    |
| `ASR_MODEL`    | `models/Qwen3-ASR-0.6B-hf`                  | Pfad zum ASR-Checkpoint                     |
| `TTS_MODEL`    | CustomVoice, bzw. Base wenn `REF_WAV` steht | Pfad zum TTS-Checkpoint                     |
| `TTS_SPEAKER`  | erster Sprecher des Checkpoints             | Preset-Stimme                               |
| `REF_WAV`      | —                                           | Referenz-Audio → der Agent spricht geklont  |
| `REF_TXT`      | —                                           | Transkript dazu (nur zusammen mit `REF_WAV`)|
| `TTS_DTYPE`    | `f32`                                       | `f16` spart Speicher, siehe unten           |
| `ASR_DTYPE`    | `f16`                                       | `f32` kostet ~1,5 GB mehr                   |

Der Agent spricht mit geklonter Stimme, sobald beide Referenz-Variablen gesetzt
sind — dann wird automatisch das Base-Modell genommen:

```bash
REF_WAV=stimme.wav REF_TXT=stimme.txt cargo run --release
```

Sampling und Sprache sind Konstanten in [src/main.rs](src/main.rs):
`LANGUAGE`, `SYSTEM_PROMPT`, `speech_options()`.

### Warum die dtypes unterschiedlich sind

Beide Modelle liegen gleichzeitig im Speicher. In F32 sind das zusammen rund
6,7 GB, und auf einer 24-GB-Maschine bricht Metal dann neben dem LLM mit
`kIOGPUCommandBufferCallbackErrorOutOfMemory` ab.

ASR läuft in F16 sauber. TTS **nicht**: dort laufen die Logits des Talkers über
und das Sampling stirbt mit „A weight is negative, too large or not a valid
number". Deshalb TTS in F32, ASR in F16 — beides über die Variablen oben
umstellbar.

## HTTP-API

| Route          | Body                                        | Antwort                    |
| -------------- | ------------------------------------------- | -------------------------- |
| `GET /`        | —                                           | WebUI                      |
| `GET /api/config` | —                                        | `{"sample_rate": 16000}`   |
| `POST /api/tts`| Text (`text/plain`)                         | SSE                        |
| `POST /api/s2s`| rohes Mono-PCM, little-endian `f32`, 16 kHz | SSE                        |

SSE-Events: `{"type":"transcript"|"delta"|"audio"|"error"|"done", …}`, Audio
als base64-kodiertes WAV.

Der Browser schickt bewusst **rohes PCM** statt `MediaRecorder`-Output: das
wäre WebM/Opus, und dafür bräuchte der Server einen Audio-Decoder. Die UI nimmt
stattdessen über WebAudio auf und resampelt selbst auf 16 kHz.

## Warum `.cargo/config.toml`

candle 0.11 kompiliert auf Apple Silicon einen NEON-f16-Pfad, der Intrinsics
aus dem noch instabilen `stdarch_neon_f16` benutzt — auf stable Rust ein harter
Compile-Fehler. [.cargo/config.toml](.cargo/config.toml) schaltet das
Target-Feature `fp16` ab. Für dieses Projekt folgenlos (f32 auf Metal).

**Nebenwirkung:** Das Debug-Profil baut damit nicht mehr — `gemm-f16` benutzt
Inline-Assembly, die `fullfp16` voraussetzt. Deshalb immer `--release` nehmen,
auch für Tests:

```bash
cargo test --release
```

## Modellgrößen

Qwen3-TTS und Qwen3-ASR gibt es je als 0.6B und 1.7B. Beide haben 28 Layer, der
Unterschied ist die Breite (`hidden_size` 1024 vs. 2048) — bessere Qualität,
aber grob das 3–4-Fache an Rechenzeit pro Schritt. Für einen Sprach-Agenten,
bei dem Latenz zählt, ist 0.6B der bessere Startpunkt. Umstellen heißt nur
`ASR_MODEL`/`TTS_MODEL` auf einen anderen Pfad zeigen lassen.

`Qwen3-TTS-12Hz-1.7B-VoiceDesign` (Stimme per Textbeschreibung) unterstützt
Crane derzeit nicht — nur `base` und `custom_voice`.
