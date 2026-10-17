# Spike S1 – Engine (mlx-audio-swift auf dem M4)

Stand: 16.10.2026 · Gerät: M4, 24 GB RAM, macOS 26.6 · Xcode 27.0 (Swift 6.4, SDK 27)
für **alle** Messungen unten (Release-Build, `swift build -c release`).

## Aufbau

- `Sources/Speech`: `SpeechEngine`-Protokoll (Actor), `MLXQwenEngine`, `ModelKind`, `ModelSpec`
  (gepinnte Repos), `Voice`/`VoiceHandle`, `AudioResampler` (Referenz laden/kürzen).
- Klon-Prompt: `prepare(voice)` ruft upstream `Qwen3TTSModel.prepareReferenceConditioning`
  einmal auf (Referenz-Codec-Encoder + Sprecher-Embedding + Referenztext-Tokens), das Ergebnis
  liegt im Actor. `speak` nutzt `generateStream(text:conditioning:…)` und liefert `[Float]`.
  Die Sprache des Prompts wird pro Aufruf ersetzt (`codec_language_id` aus der `config.json`),
  damit dieselbe Referenz in jeder Lesesprache dient.
- Resampling: Speech hängt von `AudioOut` ab und nutzt `AudioOut.Resampler`
  (bandbegrenzt, AVAudioConverter). Das koppelt Speech an AudioOut (und dessen C-Target),
  vermeidet aber eine zweite Implementierung. Die Rate kommt immer vom Modell (24 000 Hz).
- Seed: Speech nimmt einen `UInt64` und setzt `MLXRandom.seed`. Ableitung macht
  `Projects.SeedDerivation`. Geprüft: gleicher Seed, gleiche Eingabe gibt bitgleiches Audio
  (`maxDiff = 0`, 4- und 8-bit).
- Spike: `swift run -c release spike-s1 refs --out <Ordner>` und
  `spike-s1 bench --bits 4|8 --out <Ordner> [--interval 0.32] [--langs de,pt]`.

## Gepinnte Quellen

| Was | Name | Revision |
| --- | --- | --- |
| Bibliothek | `Blaizzy/mlx-audio-swift` Tag v0.1.5 | `dbe5eaac964e8257785f9d015c81f819a38016a8` |
| Base 4-bit | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit` | `37e955a1deb861c088ae5f3a67043185f3d1a60c` (2,2 GB) |
| Base 8-bit | `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit` | `e7dd0585652209fa0d7783659aad4e8a324de11c` (2,9 GB) |
| VoiceDesign 4-bit | `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit` | `5c390979e4b93af5f2932f90742ca99c7dd04687` (2,2 GB) |

Es gibt auch 5-/6-bit und bf16; VoiceDesign-8-bit wurde nicht geladen. Upstream-HEAD war am
16.10. `244458d` (10.10.); v0.1.5 genügt. Abhängigkeit mlx-swift 0.30.6+ (Metal-Toolchain
muss installiert sein: `xcodebuild -downloadComponent MetalToolchain`).

## Messwerte (Base, geklont, Streaming 0,32 s)

Je Sprache 3 Abschnitte à ca. 300 Zeichen, Referenz ca. 9,6 s von VoiceDesign erzeugt
(Seed 1234; Texte stehen in `spike-s1/main.swift` und `spike-output/S1/refs/*.txt`).

| | 4-bit | 8-bit |
| --- | --- | --- |
| Ladezeit (Platte, Cache warm) | 1,6 s | 1,9 s |
| Footprint nach Laden | 2,5 GB | 3,3 GB |
| **RTF de** (3 Abschnitte, 62 s / 59 s Audio) | **0,83** | **0,94** |
| **RTF pt** (3 Abschnitte, 60 s / 56 s Audio) | **0,82** | **0,95** |
| Zeit bis erstes Audio | 0,6 s | 0,6 s |
| MLX-Spitze je Abschnitt | 3,1–3,2 GB | 3,9 GB |
| Footprint im Betrieb | 3,5 GB | 3,9 GB |
| Footprint-Spitze (phys_footprint, ganzer Lauf) | 5,1 GB | 5,9 GB |
| Klon-Prompt `prepare` | 1,5 s (erster Aufruf, Warmlauf), danach 0,08 s | 0,09 s |
| NaN/Inf | 0 in 12 Abschnitten | 0 |
| Spitzenpegel / RMS | 0,86–0,98 / 0,10–0,14 | 0,71–0,94 / 0,08–0,12 |
| Seed-Determinismus | identisch | identisch |
| Nach Entladen | 1,5 GB (MLX gibt Speicher nur teilweise zurück) | 1,9 GB |

Weitere Messungen:
- Streaming-Intervall 2,0 s statt 0,32 s: identisches Audio, RTF 0,80 statt 0,83, aber MLX-Spitze
  4,6 GB statt 3,1 GB. **0,32 s bleibt.**
- VoiceDesign-4-bit (nicht streamend, `generate`): RTF 0,42–0,45 bei ca. 9,6 s Audio, aber
  MLX-Spitze 5,3 GB und Footprint-Spitze 9,8 GB (bei 20 s Audio sogar 16,8 GB). Für `design`
  ist der Streaming-Pfad nötig, bevor Phase 4 beginnt (Referenzen sollen kurz bleiben, ca. 10 s).
- Klon-Overhead: nur der einmalige `prepare`-Aufruf. Mit dem Conditioning-Pfad wird die
  Referenz **nicht** bei jedem Aufruf neu enkodiert. Der Weg `generate(refAudio:)` cached nur
  über die Objektidentität des Arrays und ist unzuverlässig; die Engine nutzt ihn nicht.
- Nicht gemessen: Python-`mlx-audio` als Referenz, WER per Spracherkennung (Aufwand/Nutzen
  gering, solange die Hörprobe fehlt; gehört zu S2).

## Fazit

- **Speicher passt** (Ziel ≤ 4 GB im Betrieb: 3,5 / 3,9 GB), Qualitätsprüfung (NaN, Pegel) sauber,
  Seeds reproduzierbar.
- **Geschwindigkeit verfehlt das Ziel**: RTF 0,82–0,95 statt ≤ 0,5. Das ist nur ca. 1,1–1,2-fache
  Echtzeit. Ein 30-Seiten-PDF (≈ 1 h Audio) braucht damit rund 50 Minuten statt 20–30.
  4-bit ist etwa 12 % schneller als 8-bit. Dafür ist die Vocello-Optimierung der naheliegende
  Hebel (verschmolzenes RoPE +26 %, kompilierter Code-Predictor +8–11 %, zusammen RTF ≈ 0,55).
- **Plan B (VocelloQwen3Core)**: Das Repo hat kein `Package.swift` im Wurzelverzeichnis
  (`swift package resolve` scheitert), der Code müsste also als Unterordner vendort werden
  (`git subtree`). Nicht gemacht. Erst Hörtest, dann entscheiden: Reicht RTF 0,8, weil das
  Umwandeln im Hintergrund läuft und die Oma nicht zusieht, oder muss vendort werden?
  Upstream funktioniert technisch vollständig (kein Scheitern), deshalb kein Pflichtgrund.

## Entscheidung (vorläufig bis 🎧-Test)

- Engine: **`mlx-audio-swift` v0.1.5** hinter `SpeechEngine`. Vocello-Vendoring als Phase-1-Aufgabe
  einplanen, falls RTF 0,8 für die Restzeit-Anzeige zu langsam wirkt.
- Bit-Tiefe: **4-bit als Standard** (schneller, 0,4 GB weniger RAM), 8-bit nur, wenn der
  Blindtest hörbar besser ist.
- Nicht über `swift test` testbar: MLX findet dort die `default.metallib` nicht. Modelltests
  laufen deshalb über `spike-s1`; `swift test` deckt Resampling, Pfade und Sprachtabellen ab.
- `swift build` funktioniert für MLX, sobald die Metal Toolchain installiert ist (Xcode 27).

## 🎧 Hörproben (`spike-output/S1/`)

Blindtest 4-bit gegen 8-bit, jeweils gleicher Text, gleicher Seed, gleiche Referenz:

- `de-4bit-1.wav` … `de-4bit-3.wav` gegen `de-8bit-1.wav` … `de-8bit-3.wav`
- `pt-4bit-1.wav` … `pt-4bit-3.wav` gegen `pt-8bit-1.wav` … `pt-8bit-3.wav`
- Referenzen: `refs/ref-de.wav`, `refs/ref-pt.wav` (Text in den `.txt`)

Fragen:
1. Klingt 8-bit hörbar besser (Betonung, Zischlaute, Stabilität)? Wenn nein, 4-bit.
2. Ist die geklonte Stimme in allen drei Abschnitten dieselbe wie die Referenz?
3. Portugiesisch: klingt es nach Brasilien (gewollt: „brasilianisch“ in der Beschreibung)?
   Gibt es Verschlucktes, Wiederholungen oder abgeschnittene Satzenden?
4. Ist das Tempo angenehm (Referenzstimme „ruhig, warm“)?
