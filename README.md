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
- **Text-to-Speech** — Text eingeben, vorlesen lassen; Sprache und Stimme pro
  Anfrage wählbar

### Nur Text-to-Speech

```bash
MODE=tts cargo run --release
```

Dann werden ASR und LLM **gar nicht geladen** — spart ~1,6 GB VRAM und die
halbe Startzeit, und Ollama muss nicht laufen. Die WebUI blendet den
Speech-to-Speech-Modus dann aus.

### Was die UI anbietet, hängt am Checkpoint

Ein Prozess lädt genau ein TTS-Checkpoint, und die beiden schließen sich aus:

| Checkpoint      | `tts_model_type` | UI zeigt                                  |
| --------------- | ---------------- | ----------------------------------------- |
| **CustomVoice** | `custom_voice`   | Sprach- und Stimmen-Auswahl (9 Presets)   |
| **Base**        | `base`           | Sprach-Auswahl + Referenz-Upload (Cloning)|

Sprachen und Stimmen liest der Server beim Laden aus der `config.json` des
Checkpoints und meldet sie über `/api/config` — die UI rät nichts.

Voice Cloning in der UI also so:

```bash
MODE=tts TTS_MODEL=models/Qwen3-TTS-12Hz-0.6B-Base cargo run --release
```

Danach im Text-to-Speech-Modus die Referenz-WAV hochladen und ihr Transkript
eintragen. Alternativ per `REF_WAV`/`REF_TXT` fest vorgeben — dann gilt die
Referenz für alle Anfragen, auch für den Agenten im Speech-to-Speech-Modus.

### Stimmen-Ablage

Damit man eine Referenz nicht jedes Mal neu hochlädt, liegen geklonte Stimmen
in `voices/` (änderbar über `VOICES_DIR`) — je Stimme zwei Dateien:

```
voices/
├── johannes.wav    Referenz-Aufnahme
├── johannes.txt    exaktes Transkript dazu
├── oma.wav
└── oma.txt
```

Dieselbe Konvention wie beim CLI-Aufruf, also lassen sich Stimmen auch von Hand
hineinkopieren — das Verzeichnis wird bei jeder Abfrage neu gelesen, ein
Neustart ist nicht nötig. In der UI erscheinen sie als Dropdown; eine frisch
hochgeladene Referenz kann über „Speichern unter" direkt abgelegt werden.

Stimmnamen dürfen nur Buchstaben, Ziffern, `-` und `_` enthalten. Das ist keine
Kosmetik: der Name kommt aus einer HTTP-Anfrage und landet in einem Dateipfad.

Eine WAV ohne zugehöriges `.txt` (oder umgekehrt) wird ignoriert — das
Base-Modell braucht beides, eine halbe Stimme anzubieten wäre irreführend.

Die Sample-Rate der Aufnahme ist egal: resampled wird erst im TTS-Thread, und
zwar auf die Rate, die das geladene Checkpoint über
`speaker_encoder_sample_rate()` meldet (bei Qwen3-TTS 24 kHz). Deshalb reicht
die Referenz als **rohe WAV-Bytes** durch die ganze Kette — eine hartkodierte
Rate an irgendeiner Zwischenstation ließ die geklonte Stimme sonst um genau
den Ratenfaktor zu hoch klingen.

### Audio herunterladen

Die WebUI sammelt alle Audio-Chunks eines Durchlaufs und bietet sie als **eine**
WAV-Datei zum Download an. Nötig ist das, weil der Server pro Satz eine eigene
WAV mit eigenem Header schickt — die Chunks werden im Browser wieder zu einer
durchgehenden Datei zusammengesetzt.

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
| `MODE`         | `full`                                      | `tts` = nur Text-to-Speech, siehe unten     |
| `BIND`         | `127.0.0.1:8080`                            | Adresse des Web-Servers                     |
| `LLM_ENDPOINT` | `http://localhost:11434/v1`                 | OpenAI-kompatible Basis-URL                 |
| `LLM_MODEL`    | `gemma4:e2b`                                | Modellname beim Endpunkt                    |
| `ASR_MODEL`    | `models/Qwen3-ASR-0.6B-hf`                  | Pfad zum ASR-Checkpoint                     |
| `TTS_MODEL`    | CustomVoice, bzw. Base wenn `REF_WAV` steht | Pfad zum TTS-Checkpoint                     |
| `TTS_SPEAKER`  | erster Sprecher des Checkpoints             | Preset-Stimme                               |
| `REF_WAV`      | —                                           | Referenz-Audio → der Agent spricht geklont  |
| `REF_TXT`      | —                                           | Transkript dazu (nur zusammen mit `REF_WAV`)|
| `VOICES_DIR`   | `voices`                                    | Ablage gespeicherter Voice-Clones           |
| `TTS_DTYPE`    | `f32`                                       | `f16` spart Speicher, siehe unten           |
| `ASR_DTYPE`    | `f16`                                       | `f32` kostet ~1,5 GB mehr                   |
| `TTS_STREAM`   | `1`                                         | `0` = ganzer Satz am Stück, siehe unten     |
| `LLM_REASONING`| `none`                                      | Denkphase; `low`/`medium`/`high` schalten sie an |

Der Agent spricht mit geklonter Stimme, sobald beide Referenz-Variablen gesetzt
sind — dann wird automatisch das Base-Modell genommen:

```bash
REF_WAV=stimme.wav REF_TXT=stimme.txt cargo run --release
```

Sampling und Sprache sind Konstanten in [src/main.rs](src/main.rs):
`LANGUAGE`, `SYSTEM_PROMPT`, `speech_options()`.

## Performance

Gemessen auf M-Serie, 24 GB, warmes Ollama — Zeit bis zum **ersten hörbaren
Ton** in einem Speech-to-Speech-Durchlauf:

| Stufe            | Zeit    | Anmerkung                                  |
| ---------------- | ------- | ------------------------------------------ |
| ASR              | 0,2–0,4 s | F16 auf Metal, unkritisch                |
| LLM erstes Token | 0,5–0,7 s | mit `reasoning_effort: none`             |
| erstes Audio     | 1,5–1,7 s | vorher 8,7 s                             |

Drei Dinge machen den Unterschied:

**Denkphase aus.** `reasoning_effort: "none"` im Request — bei `gemma4:e2b`
5,13 s → 0,48 s bis zum ersten Token. Ollamas eigenes `think: false` wirkt am
OpenAI-Endpunkt **nicht**, dieses Feld schon.

**TTS streamt innerhalb eines Satzes.** Crane gibt über
`generate_speech_streaming` schon nach 5 Codec-Frames (≈0,4 s Ton) die erste
Wellenform raus, statt den Satz fertigzurechnen: 11,5 s → 0,97 s bis zum ersten
Chunk. Kostet Durchsatz, weil jeder Chunk mit 25 Frames Kontext dekodiert wird
und der Vokoder Teile doppelt rechnet — 0,56x statt 0,74x Echtzeit. Für Dialog
ist das der richtige Tausch, für langes Vorlesen nicht: dann `TTS_STREAM=0`.
Voice Cloning hat in Crane keinen Streaming-Pfad und liefert immer den ganzen
Satz.

**LLM und TTS sind entkoppelt.** Die Satzerkennung läuft in einem eigenen Task
und schiebt fertige Sätze in eine Warteschlange; die Synthese arbeitet sie
nebenher ab. Sonst stünde das Lesen der LLM-Token still, solange ein Satz
synthetisiert wird. Die Sätze selbst bleiben seriell — ein Modell, ein Thread.

### Was noch bremst

TTS läuft mit **0,56–0,74x Echtzeit**, also langsamer als das Abspielen. Bei
langen Antworten leert sich die Warteschlange im Browser schneller, als sie
gefüllt wird. Der eigentliche Hebel wäre F16 für den Talker (grob 2x), das
bricht aber aktuell das Sampling — siehe unten. Quantisierung ist keine Option:
Crane hat für `qwen3_tts` keinen quantisierten Pfad (kein GGUF, kein `QMatMul`),
die MLX-4bit-Varianten auf HuggingFace lassen sich damit nicht laden.

Auf der GPU liegt bereits alles: ASR, Talker **und** Vokoder. Der ONNX-Vokoder
in Crane ist `#[cfg(feature = "onnx")]` und bei uns aus — genutzt wird der
native Candle-Decoder auf demselben Metal-Device.

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
| `GET /api/config` | —                                        | Fähigkeiten, siehe unten   |
| `GET /api/voices` | —                                        | `["johannes", "oma"]`      |
| `POST /api/tts`| JSON, siehe unten                           | SSE                        |
| `POST /api/s2s`| rohes Mono-PCM, little-endian `f32`, 16 kHz | SSE (409 bei `MODE=tts`)   |

`GET /api/config`:

```json
{
  "speech_to_speech": true,
  "sample_rate": 16000,
  "languages": ["auto", "chinese", "english", "french", "german", "…"],
  "voices": ["aiden", "dylan", "eric", "ono_anna", "ryan", "serena", "…"],
  "voice_cloning": false,
  "saved_voices": ["johannes", "oma"]
}
```

`POST /api/tts` — alles außer `text` ist optional:

```json
{
  "text": "Hallo Welt.",
  "language": "german",
  "speaker": "serena",
  "voice": "johannes",
  "reference_wav": "<base64 einer WAV-Datei>",
  "reference_text": "Transkript der Referenz",
  "save_as": "johannes"
}
```

`voice` (gespeicherte Stimme) und `reference_wav`/`reference_text` (frische
Referenz) schließen sich aus — beides zusammen ist ein 400, statt dass der
Server rät. `save_as` legt die hochgeladene Referenz unter dem Namen ab und
braucht deshalb `reference_wav` + `reference_text`.

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
