# Vorleser – Arbeitsregeln für Claude Code

Mac-App, die PDF/Text in MP3 verwandelt (Qwen3-TTS, lokal), bedienbar für eine
Oma. **Der vollständige Plan mit Begründungen und Quellen steht in
[PLAN.md](PLAN.md). Lies ihn vor der ersten Änderung.** Diese Datei enthält nur,
was du in jeder Sitzung brauchst.

## Rahmen (vom Nutzer festgelegt, nicht neu verhandeln)

- Ein Mac mit **M4, 16 GB RAM, macOS 26**. Darauf wird gebaut **und** benutzt.
- **Kein Apple-Developer-Account.** Signiert wird mit dem kostenlosen
  „Personal Team“ in Xcode. Keine Notarisierung, kein Sandbox, kein Hardened Runtime.
- **Alle 10 Qwen-Sprachen** vorlesen: de, pt, en, es, fr, it, ru, zh, ja, ko.
  Die Oberfläche gibt es auf **Deutsch und Portugiesisch**.
- Ausgabe ist **MP3** (LAME): CBR 64 kbit/s, mono, 44,1 kHz, ID3v2.
- Ressourcenschonend: **genau ein Modell im Speicher**, Streaming, Entladen im
  Leerlauf. Nach der Einrichtung keine Netzwerkzugriffe.
- Zur Laufzeit **kein Python und kein lokaler Server**. Python darf nur für
  Vergleichsmessungen in Spikes dienen.

## Architektur in einem Satz je Teil

- `Packages/VorleserCore` (SwiftPM, ohne UI) enthält:
  - `DocumentImport`: PDFKit/Vision/NSAttributedString
  - `TextPrep`: Bereinigung, Normalizer je Sprache, ChunkPlanner
  - `Speech` (Modul heißt `VorleserSpeech`, wegen Apples Speech-Framework): `SpeechEngine`-Actor über MLX, `VoiceStore`, `RecordedVoiceStore`
  - `VoiceCapture`: Mikrofon-Aufnahme, Pegel-/Rauschprüfung, Spracherkennungs-Check, Audio-Import (Phase 3)
  - `AudioOut`: QC, Pausen, Lautheit, Tempo, 44,1-kHz-Resampling, LAME
  - `Projects`: Manifest, Fortsetzen
  - `vorleser-cli`
- `App/`: SwiftUI, nur Bedienung. Logik gehört ins Package.
- Projektdatei kommt aus `project.yml` (XcodeGen). `.xcodeproj` ist nicht eingecheckt.

## Fakten, die du nicht neu recherchieren musst

- Modelle: `Qwen3-TTS-12Hz-1.7B-Base` (Klonen, Hauptmodell) und
  `Qwen3-TTS-12Hz-1.7B-VoiceDesign` (Stimme aus Beschreibung), als MLX-Variante
  4-bit oder 8-bit aus `mlx-community/…`. **Exakte Repo-Namen und Revisionen
  auf Hugging Face prüfen und festpinnen.**
- **Base ignoriert `instruct`.** Stil kommt aus der Referenzaufnahme. Deshalb
  der Ablauf: VoiceDesign erzeugt einmal eine Referenz, dann klont Base sie für
  jeden Abschnitt.
- Klonen mit Transkript (ICL) ist besser als `x_vector_only_mode`. Referenz
  10–15 s; länger bringt nichts außer Latenz.
- Langtext wird ab ca. 500 Wörtern pro Durchgang unzuverlässig. Abschnitte von
  200–500 Zeichen (CJK ca. ⅓), jeder wird geprüft und bei Bedarf mit neuem Seed
  wiederholt.
- `mlx-audio-swift`-API (Stand Recherche):
  - `TTS.loadModel(modelRepo:)`
  - `model.generate(text:voice:refAudio:refText:language:)`
  - `generateStream(…, streamingInterval: 0.32)`
  - `voice` = Beschreibung (VoiceDesign) bzw. Sprecher+Stil (CustomVoice)
  - Kein Batching.
- Vergleichswerte von Vocello (Swift+MLX, MIT, 1.7B 4-bit):
  - RTF 0,26–0,32 auf einem 16-GB-Mac, ~3 GB Spitzenspeicher mit Streaming.
  - Gewinne: verschmolzenes RoPE im Code-Predictor (+26 %), kompilierter
    Code-Predictor-Pass (+8–11 %), 8-bit-Text-Embeddings (−278 MB).
  - Verluste: KV-Cache quantisieren (−8,6 %), harte `Memory.memoryLimit` (falsche OOMs).
  - Quelle: `github.com/PowerBeef/Vocello`, `benchmarks/OPTIMIZATION.md`.
- `SpeechTranscriber` (macOS 26) hatte zum Start kein Russisch. Für Russisch
  daher `SFSpeechRecognizer` oder nur Dauerprüfung.

## Lehren aus dem alten Rust-Projekt (auf `main`)

- Referenz-Audio **immer auf die Rate resamplen, die das Modell meldet**, nie
  hart kodieren. 16 statt 24 kHz ließ die Stimme um den Faktor 1,5 zu hoch klingen.
- Resampling bandbegrenzt (`AVAudioConverter`), nicht linear interpolieren.
- Am Komma zu schneiden kostete Betonung **und** Zeit; besser an Satzgrenzen
  schneiden. `19,99` und `19.99` nie trennen.
- NaN/Inf im Sampling kann vorkommen (F16 in Candle). Jeden Abschnitt auf
  NaN prüfen.

## Arbeitsweise

- **Reihenfolge nach PLAN.md §5**: erst Spikes S1–S5, dann Phasen 1–5.
- **Messen statt raten.** Jeder Spike schreibt `docs/spikes/Sx-<thema>.md` mit
  Aufbau, Messwerten (RTF = Rechenzeit ÷ Audiodauer, Spitzenspeicher), Fazit und
  getroffener Entscheidung. Weicht ein Ergebnis vom Plan ab, PLAN.md anpassen
  und den Nutzer darauf hinweisen.
- **Du kannst nicht hören.** Objektiv prüfen kannst du:
  - Dauer, Pegel, Stille, NaN
  - RTF, Speicher
  - Spracherkennung zurück in Text, dann WER/CER

  Alles, was nach Klang beurteilt werden muss (🎧 im Plan), legst du als Dateien
  in `spike-output/` ab. Bitte den Nutzer dann gezielt ums Anhören, mit Liste
  der Dateien und konkreter Frage.
- Bauen und testen:
  - `swift build` / `swift test` im Package
  - App: `xcodegen generate && xcodebuild -scheme Vorleser -configuration Debug build`
  - Installieren: `scripts/install.sh`
- Modelle liegen im HF-Cache bzw. später unter
  `~/Library/Application Support/Vorleser/Models`, nie im Repo.
- Es gibt keine fertigen Stimmen. Jede Stimme (aufgenommen, importiert, beschrieben) liegt unter
  `~/Library/Application Support/Vorleser/Voices` als Audio (.caf) plus eigener Text (.txt);
  als `refText` dient immer dieser gespeicherte Text. Testausgaben gehören nach `spike-output/` und sind ignoriert.

## Konventionen

- Doku, Kommentare und Commit-Texte auf Deutsch. Bezeichner im Code auf Englisch.
- Swift 6 mit strikter Concurrency. Die Engine ist ein `actor`. Kein `MLXArray`
  über Actor-Grenzen; dort `[Float]` übergeben.
- UI-Texte nur über `Localizable.xcstrings` (de, pt), nie hart im Code.
- Oma-Regeln aus PLAN.md §3 sind Abnahmekriterien, keine Vorschläge:
  - Schrift ≥ 20 pt, Knöpfe ≥ 60 pt mit Wort und Symbol
  - keine Fachwörter
  - kein Hover, kein Rechtsklick
  - alles automatisch speichern
- Kleine, überprüfte Commits. Vor jedem Commit muss `swift test` grün sein.
