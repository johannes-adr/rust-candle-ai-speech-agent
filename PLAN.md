# Plan: „Vorleser“ – PDF/Text → Hörbuch mit Qwen3-TTS

Stand: 16.10.2026 · Zielgerät: Mac mit M4, 16 GB RAM · Status: **Plan, noch kein Code**

Ziel: Eine Mac-App, mit der eine Oma ohne Hilfe einen Brief, ein PDF oder einen
Text in eine Audiodatei verwandelt. Vorgelesen wird von einer fertigen Stimme,
einer beschriebenen Stimme („ruhig, warm, wie ein Märchen“) oder der eigenen,
geklonten Stimme. Alles läuft lokal und offline.

---

## 1. Entscheidungen auf einen Blick

| Thema | Entscheidung | Warum |
| --- | --- | --- |
| Sprache/Plattform | **Swift 6 + SwiftUI, native macOS-App** (macOS 26) | App-Icon im Dock statt Terminal/Browser; PDFKit, Vision-OCR, Mikrofon, Teilen, Mitteilungen gibt es eingebaut |
| Inferenz | **MLX** (Metal-GPU) über `mlx-audio-swift`; `VocelloQwen3Core` als Plan B | 4/8-bit-Quantisierung, ca. 3 GB Spitzenspeicher, schneller als Echtzeit (siehe §2.2) |
| Modelle | **Qwen3-TTS-12Hz-1.7B-Base** (Klonen, Langtext) + **1.7B-VoiceDesign** (Stimme beschreiben) | Base ist der einzige Weg zu einer gleichbleibenden Stimme über 100 Abschnitte; VoiceDesign nur bei Bedarf |
| Stil-Anweisungen | **Design → Klon**: Die Beschreibung erzeugt einmal eine Referenzaufnahme, das ganze Dokument wird dann mit Base geklont | Offizieller Qwen-Workflow für konsistente Stimmen; Base ignoriert `instruct` |
| Fertige Stimmen | 3 deutsche Stimmen × 4 Stile **vorab erzeugt und mitgeliefert** (nur WAV + Text, wenige MB) | Im Normalfall wird VoiceDesign nie geladen → weniger RAM, schnellerer Start |
| Textaufbereitung | PDFKit + Vision-OCR + eigene Bereinigung + deutsche Normalisierung (Zahlen, Datum, Abkürzungen) | Alles systemeigen, kein zusätzliches Modell |
| Langtext | Abschnitte von **200–500 Zeichen**, nacheinander, mit Prüfung und automatischer Wiederholung | Qwen3-TTS wird ab ca. 500 Wörtern pro Durchgang unzuverlässig (§2.3) |
| Ausgabe | **.m4a (AAC, mono, 48–64 kbit/s)**, ca. 20–30 MB pro Stunde; MP3 optional später | AAC kodiert macOS nativ und sparsam; MP3 bräuchte LAME |
| Altes Rust/Candle-Projekt | **wird nicht weiterverwendet** | nur 0.6B, nur F32, 0,56–0,74× Echtzeit, keine Quantisierung (eigene Messungen, `README.md`) |

---

## 2. Recherche-Ergebnisse

### 2.1 Qwen3-TTS-Familie (Open Source, Apache 2.0, seit 22.01.2026)

| Checkpoint | Kann | Stil per Anweisung | Rolle bei uns |
| --- | --- | --- | --- |
| 1.7B-VoiceDesign | Stimme aus Textbeschreibung | ✅ (Pflicht) | Referenz für „Stimme beschreiben“ erzeugen |
| 1.7B-CustomVoice | 9 feste Sprecher (zh/en/ja/ko) | ✅ | **nicht** im MVP (keine deutschen Muttersprachler) |
| 1.7B-Base | Klonen ab ca. 3 s Referenz | ❌ (wird ignoriert) | **Hauptmodell** für jedes Dokument |
| 0.6B-Base / -CustomVoice | wie oben, kleiner | ❌ | Ausweichoption, falls 1.7B zu langsam |

Wichtig für uns:

- **Deutsch** wird unterstützt, aber nur Hochdeutsch. Laut technischem Bericht:
  WER 1,235 (ElevenLabs 0,572), Sprecherähnlichkeit 0,775 (ElevenLabs 0,614).
  Verständlichkeit also gut, aber nicht Spitze → Normalisierung und Prüfung
  lohnen sich.
- **Klonen**: Mit Transkript (ICL-Modus) wird es am ähnlichsten. Ohne Transkript
  gibt es `x_vector_only_mode`, das ist schwächer. Empfohlen werden
  10–15 s Referenz; länger macht es nur langsamer (eigene Messung im alten Projekt).
- **Stil beim Klonen**: Base übernimmt Sprechweise und Tempo der Referenz.
  `instruct` hat dort keine Wirkung (HF-Diskussion, Vocello-Doku). Wer die eigene
  Stimme „fröhlich“ will, muss fröhlich aufnehmen.
- **Anweisungen** zuverlässig umgesetzt (laut Vocello-Messungen): neutral, ruhig,
  flüsternd, traurig. Fröhlich, aufgeregt usw. wirken eher als Richtung.

### 2.2 Laufzeit-Optionen auf Apple Silicon

| Option | Status | Gemessen / berichtet |
| --- | --- | --- |
| **Crane/Candle (Rust, altes Projekt)** | 0.6B, F32 (F16 bricht das Sampling) | **0,56–0,74× Echtzeit**, also langsamer als das Abspielen |
| PyTorch MPS (offizielles `qwen-tts`) | läuft | ca. 10–15 s pro Satz, schwer (Python + Torch) |
| `qwen3-tts.cpp` (ggml/Metal) | nur 0.6B-Base, Q8, jung | ohne belastbare Mac-Zahlen |
| `mlx-audio` (Python) | alle Varianten, 4/6/8-bit, Batching | 1.7B 6-bit: 1,67× Echtzeit bei 3,9 GB; Batch 8: 5,45× bei 4,1 GB |
| **`mlx-audio-swift`** | Base, CustomVoice, VoiceDesign, Streaming; **kein** Batching | keine veröffentlichten Zahlen |
| **Vocello (`VocelloQwen3Core`, MIT)** | Fork von mlx-audio-swift, stark optimiert, 1.7B 4/8-bit | **RTF 0,26–0,32** auf Mac mini M6, 16 GB (≈3–4× schneller als Echtzeit); 8-GB-M2: 1,4–1,9× Echtzeit; Spitzenspeicher **~3 GB**, über 10 min Langtext konstant |

**Folgerung:** MLX in Swift ist auf dem Mac die schnellste und sparsamste
Lösung, ohne Python und ohne lokalen Server. Ein M4 sollte zwischen den M2- und
den 16-GB-Werten von Vocello liegen. Das misst Spike S1.

Beim Einbinden geht es so vor:
1. Start mit **`mlx-audio-swift`** als SwiftPM-Abhängigkeit (einfache API, MIT).
2. Die Engine liegt hinter einem eigenen `SpeechEngine`-Protokoll.
3. Wenn S1 zeigt, dass Upstream zu langsam ist oder die Klon-Referenz bei jedem
   Aufruf neu berechnet: **`VocelloQwen3Core` vendoren** (MIT, liegt nur als
   lokales Paket in deren Repo, also per `git subtree`). Es bringt gecachte
   Klon-Prompts, verschmolzenes RoPE (+26 %) und einen kompilierten
   Code-Predictor (+8–11 %) mit.
4. Batching (Python hat es, Swift nicht) bleibt eine spätere Optimierung, die nur
   kommt, falls der Durchsatz nicht reicht.

> Nebenbefund: Vocello ist eine fertige MIT-App mit Design, Klonen und Langtext.
> Es ist aber ein „Studio“ für Fortgeschrittene, ohne PDF-Import und ohne
> Oma-Bedienung. Wir übernehmen die Erkenntnisse (und notfalls die Engine),
> nicht die Oberfläche.

### 2.3 Langtext-Stabilität

- Laut Qwen-Bericht ist Langtext stabil. Eine unabhängige Studie („Taming
  Long-form TTS“, 09/2026) widerspricht: unter 500 Wörtern zuverlässig, ab
  1.500 Wörtern bis zu 35–48 % Worst-Case-WER (Auslassungen, Halluzinationen).
- Daraus folgt: **kurze Abschnitte, jeder einzeln geprüft**. Abschnitte können
  so auch einzeln wiederholt und nach einem Abbruch fortgesetzt werden.
- Ungeführte Takes schwanken zwischen Seeds um ca. 2,7 Halbtöne. Geklonte Takes
  bleiben laut Vocello bei der Referenz (ECAPA-Ähnlichkeit 0,81–0,87). Deshalb:
  feste Referenz plus fester Seed pro Abschnitt.

### 2.4 Systemeigene Bausteine (kostenlos, ohne Zusatzmodelle)

| Aufgabe | macOS-API |
| --- | --- |
| PDF-Text mit Zeilenpositionen | PDFKit (`PDFSelection.selectionsByLine()`, Bounds) |
| Scans / Fotos | Vision `RecognizeDocumentsRequest` (Absätze, macOS 26); Fallback `VNRecognizeTextRequest` de-DE |
| Word / RTF / ODT / HTML | `NSAttributedString(url:)` liest .docx, .odt und .rtf direkt |
| Sätze trennen, Sprache erkennen | NaturalLanguage (`NLTokenizer`, `NLLanguageRecognizer`) |
| Zahlen ausschreiben | `NumberFormatter(.spellOut, de_DE)` + eigene Ordinal- und Datumsregeln |
| Silbentrennung prüfen | `NSSpellChecker` (prüft, ob „Bei“+„spiel“ ein Wort ist) |
| Transkript der eigenen Aufnahme, Qualitätsprüfung | `SpeechAnalyzer`/`SpeechTranscriber` (on-device, Deutsch, macOS 26) |
| Stilwunsch DE→EN (falls nötig) | Translation-Framework (on-device) |
| Tempo ohne Tonhöhenänderung | `AVAudioUnitTimePitch` (offline rendern) |
| AAC-Export | `AVAudioFile` / `AVAssetWriter` |

---

## 3. Bedienkonzept „für Oma“

### Regeln

1. **Eine Frage pro Bildschirm**, drei Schritte, immer „Zurück“ möglich.
2. **Groß**: Text ≥ 20 pt, Überschriften ≥ 30 pt, Knöpfe ≥ 60 pt hoch. Jeder
   Knopf hat Symbol **und** Wort, nie nur ein Icon. Kontrast ≥ 7:1.
3. **Keine Fachwörter**: kein „TTS“, „Modell“, „Klonen“, „WAV“. Stattdessen
   „Vorlesen lassen“, „Stimme“, „Hörbuch“.
4. **Nichts kaputt machbar**: Alles wird automatisch gespeichert. Abbrechen
   fragt nach („Bisher Fertiges bleibt erhalten“). Nach Absturz oder Zuklappen
   macht die App weiter.
5. **Kein verstecktes Bedienen**: kein Hover, kein Doppelklick, kein Rechtsklick
   nötig. Ziehen geht, ist aber nie der einzige Weg.
6. **Fester Ablageort**: `Musik › Vorgelesen`, zusätzlich als Liste
   „Meine Hörbücher“ auf dem Startbildschirm.
7. **Hilfe-Knopf** zeigt Name und Telefonnummer des Helfers (von dir einstellbar).
8. Technik für Helfer liegt im normalen Einstellungsfenster (⌘,): Qualität,
   Format, Ablageort, Protokolle.

### Bildschirme

```
① Start                                         ② Stimme
┌────────────────────────────────────────┐     ┌────────────────────────────────────────┐
│ Vorleser                     [ Hilfe ] │     │ Schritt 2 von 3: Wer soll vorlesen?    │
│                                        │     │ ┌───────┐ ┌───────┐ ┌───────┐ ┌──────┐ │
│ Was möchten Sie vorlesen lassen?       │     │ │ Helga │ │ Karl  │ │ Lena  │ │Meine │ │
│ ┌──────────────────┐ ┌───────────────┐ │     │ │ warm, │ │ tief, │ │ klar, │ │eigene│ │
│ │ [Datei]          │ │ [Stift]       │ │     │ │ ruhig │ │gemütl.│ │ jung  │ │Stimme│ │
│ │ Datei auswählen  │ │ Text eintippen│ │     │ │[>Probe]│ │[>Probe]│ │[>Probe]│ │[o Neu]│ │
│ │ PDF, Word, Text  │ │ oder einfügen │ │     │ └───────┘ └───────┘ └───────┘ └──────┘ │
│ └──────────────────┘ └───────────────┘ │     │ Wie soll es klingen?                   │
│   … oder Datei einfach hierher ziehen  │     │ [Ruhig] [Fröhlich] [Wie ein Märchen]   │
│                                        │     │ [Sachlich] [Eigener Wunsch …]          │
│ Meine Hörbücher                        │     │ Tempo: [Langsamer] [Normal] [Schneller]│
│ > Brief Krankenkasse   3 Min  gestern  │     │                                        │
│ > Rotkäppchen         12 Min  Montag   │     │ [ Zurück ]        [ Vorlesen lassen > ]│
└────────────────────────────────────────┘     └────────────────────────────────────────┘

③ Es arbeitet                                   ④ Fertig
┌────────────────────────────────────────┐     ┌────────────────────────────────────────┐
│ Ihr Hörbuch wird erstellt …            │     │ Fertig!  „Brief Krankenkasse“ (3 Min)  │
│ ████████████░░░░░░░░  Seite 12 von 30  │     │                                        │
│ Noch etwa 15 Minuten.                  │     │ [ > Anhören ]  [ Verschicken ]         │
│ Sie können den Computer nebenbei       │     │ [ Im Ordner zeigen ]                   │
│ ganz normal benutzen.                  │     │                                        │
│ [ > Schon mal reinhören ] [ Anhalten ] │     │ Gespeichert in: Musik › Vorgelesen     │
└────────────────────────────────────────┘     └────────────────────────────────────────┘
```

- Ist der Text kurz (z. B. ein Brief unter ca. 1 Minute), überspringt die App ③
  und **liest sofort vor**, während sie noch rechnet (Streaming). Gespeichert
  wird trotzdem.
- **Probe** spielt eine mitgelieferte Aufnahme ab, sofort und ohne Modell.
- **Eigene Stimme** führt Schritt für Schritt:
  1. Großer Lesetext.
  2. Roter Knopf „Aufnahme starten“, dann 3-2-1 und eine Pegelanzeige.
  3. Anhören, dann „So behalten“ oder „Nochmal“.
  4. Freundliche Hinweise („Bitte etwas näher ans Mikrofon“, „Es ist sehr laut im Raum“).
  5. Häkchen „Das ist meine Stimme oder ich habe die Erlaubnis“.

  Weil der Lesetext feststeht, ist das Transkript bekannt; die Oma muss nichts
  abtippen. Die Spracherkennung prüft nur, ob der Text wirklich vorgelesen wurde.
- **Stil bei eigener Stimme**: Statt der Stil-Knöpfe steht dort ehrlich „Ihre
  Stimme klingt so, wie Sie sie aufgenommen haben“. Tempo und Pausen
  funktionieren trotzdem, weil wir sie nachträglich anwenden.
- **Fertig**: Ton plus Mitteilung. „Verschicken“ öffnet das Teilen-Menü
  (Mail, Nachrichten, AirDrop).
- Ein eingebauter **Player** mit großem Play/Pause und „30 s zurück“ merkt sich
  die Position.

---

## 4. Technische Architektur

```
┌──────────── SwiftUI-App (Oma-Oberfläche, @Observable ViewModels) ───────────┐
│                                                                              │
│  DocumentImport ──► TextPrep ──────► ChunkPlanner ──► SynthesisJob ──► AudioOut
│  PDF/DOCX/TXT/      Bereinigung,     Absätze →        Engine-Aufruf,   Pausen, Tempo,
│  Einfügen, OCR      Normalisierung   200–500 Zeichen  Prüfung, Retry   Lautheit, AAC
│                                                          │                   │
│                     VoiceStore (Stimmen) ── SpeechEngine (actor, MLX)        │
│                     Projects (Fortschritt auf Platte, Fortsetzen)            │
└──────────────────────────────────────────────────────────────────────────────┘
         dieselbe Pipeline headless:  vorleser-cli  (Tests, Benchmarks, Presets)
```

### 4.1 Ordnerstruktur (neu, in diesem Branch)

```
Vorleser/
├── project.yml                  XcodeGen (diffbar statt .xcodeproj)
├── App/                         SwiftUI-Views, ViewModels, Assets, Info.plist, Entitlements
├── Resources/Voices/            Preset-Referenzen (wav + txt) + Hörproben
└── Packages/VorleserCore/       SwiftPM, ohne UI, voll testbar
    ├── Sources/DocumentImport/  PDFKit, NSAttributedString, Vision-OCR
    ├── Sources/TextPrep/        Bereinigung, Normalisierung (de), Satztrennung, ChunkPlanner
    ├── Sources/Speech/          SpeechEngine-Protokoll, MLXQwenEngine, ModelStore, VoiceStore
    ├── Sources/AudioOut/        QC, Pausen, Lautheit, Tempo, AAC/Kapitel
    ├── Sources/Projects/        Manifest, Fortsetzen
    ├── Sources/vorleser-cli/
    └── Tests/                   Golden-Files für TextPrep, QC-Tests, Engine-Smoke (nur mit Modell)
```

### 4.2 Kernschnittstellen (Skizze)

```swift
protocol SpeechEngine: Actor {
    func load(_ model: ModelKind) async throws            // .base, .voiceDesign; nie beide gleichzeitig
    func unload() async
    func prepare(_ voice: Voice) async throws -> VoiceHandle   // Klon-Prompt einmal pro Stimme, gecacht
    func speak(_ text: String, voice: VoiceHandle, language: Language,
               seed: UInt64) -> AsyncThrowingStream<[Float], Error>   // streamt → flacher Speicher
    func design(description: String, sampleText: String, language: Language,
                seed: UInt64) async throws -> [Float]                  // nur VoiceDesign
}

struct Voice  { id, name, kind: .preset | .designed | .recorded, referenceWAV, referenceText, description? }
struct Chunk  { index, text, spokenText, kind: .sentence | .paragraphEnd | .heading,
                seed, status: .pending | .done | .failed, duration, qc }
struct Project { id, title, sourceHash, voiceID, style, tempo, chunks: [Chunk] }   // manifest.json
```

### 4.3 Text-Pipeline

1. **Import**
   - PDF-Seiten mit Text: PDFKit liefert Zeilen mit Position.
   - Seiten ohne Text: Seite rendern und per Vision-OCR lesen.
   - .docx/.odt/.rtf: über `NSAttributedString`; .txt mit Kodierungserkennung.
   - Eingefügter Text: direkt übernehmen.
2. **Bereinigen** (nur PDF)
   - Kopf- und Fußzeilen: Zeilen im oberen/unteren Seitenrand, die auf ≥ 50 % der
     Seiten (Ziffern ignoriert) wiederkehren, fliegen raus. Einzelne Seitenzahlen auch.
   - Silbentrennung: „Bei-⏎spiel“ wird „Beispiel“, wenn `NSSpellChecker` das Wort
     kennt. Sonst bleibt der Bindestrich („Nord-Süd“).
   - Zeilen zu Absätzen: Neuer Absatz bei Satzende mit Abstand > 1,5 Zeilenhöhen
     oder bei Einrückung.
   - Überschriften (größere Schrift, kurze Zeile) werden Kapitelmarken und
     bekommen eine längere Pause.
   - Fußnotenziffern entfernen. Tabellen und Bildunterschriften überspringen.
   - Zwei Spalten: Spalten über die x-Position der Zeilen erkennen und nacheinander lesen.
3. **Normalisieren (Deutsch)**
   - Nur das, was Spike S2 als problematisch zeigt. Kandidaten:
     - Datum: 3.5.2024 → „dritter Mai zweitausendvierundzwanzig“
     - Uhrzeit: 14:30 → „vierzehn Uhr dreißig“
     - Geld: 12,50 € → „zwölf Euro fünfzig“
     - Prozent, Jahreszahlen (1987 → „neunzehnhundertsiebenundachtzig“)
     - Römische Kapitelzahlen
     - Abkürzungen (z. B., d. h., usw., Dr., Nr., ca., bzw., S., Tel.)
     - Einheiten
     - Telefonnummern Ziffer für Ziffer
     - URLs und E-Mails („eine Internetadresse“)
   - Testbar über Golden-Files (Eingabe → erwartete Aussprache).
4. **Abschnitte planen**
   - `NLTokenizer` trennt Sätze, ergänzt um eine eigene Abkürzungsliste.
   - Sätze werden innerhalb eines Absatzes zu 200–500 Zeichen gepackt. Ein
     Absatz endet immer an einer Abschnittsgrenze.
   - Sätze über 500 Zeichen werden an `;`, `:` oder `,` geteilt.
   - Die genaue Größe legt S2 fest.

### 4.4 Sprachsynthese (ressourcenschonend)

- **Nur ein Modell im Speicher.** Das ganze Dokument läuft über Base. VoiceDesign
  wird nur für „Eigener Wunsch …“ kurz geladen, erzeugt die Referenz und wird
  wieder entladen. Nach 60 s Leerlauf entlädt die App alles und braucht dann
  < 150 MB RAM.
- **Klon-Prompt einmal pro Dokument** berechnen statt pro Abschnitt.
- **Streaming auch beim Datei-Export**: Audio wird stückweise auf die Platte
  geschrieben. Vocello zeigt, dass das den Spitzenspeicher von ~8 GB auf ~3 GB
  senkt.
- **Seriell, ein Abschnitt nach dem anderen.** Seed = Hash(Projekt, Index,
  Versuch), damit jeder Lauf reproduzierbar ist.
- **Prüfung je Abschnitt** (billig zuerst):
  1. NaN/Clipping, Stille am Ende abschneiden.
  2. Dauer plausibel? Erwartet sind Zeichen ÷ Sprechrate der Stimme. Unter 0,5×
     oder über 2× gilt als verdächtig.
  3. Optional (Standard an, wenn S1 es günstig misst): on-device-Spracherkennung,
     dann WER gegen den Text. Über 15 % wird es verdächtig.
  4. Verdächtige Abschnitte werden mit neuem Seed wiederholt, höchstens 2-mal.
     Danach behalten und im Protokoll markieren.
- **Fortsetzen**: Jeder fertige Abschnitt liegt als `chunks/0001.caf` im
  Projektordner. Nach Beenden, Absturz oder Ruhezustand geht es dort weiter.
- **Energie**
  - `ProcessInfo.beginActivity(.userInitiated, .idleSystemSleepDisabled)`:
    Der Mac schläft nicht ein, der Bildschirm darf aus.
  - Bei Thermal-State `.serious` kurze Pausen zwischen Abschnitten.
  - Während der Arbeit keine durchscheinenden UI-Effekte; das kostete bei
    Vocello ~23 % Leistung.
- **Restzeit** aus der gemessenen Geschwindigkeit der ersten Abschnitte
  („noch etwa 15 Minuten“).

### 4.5 Audio-Ausgabe

- Pausen setzen wir selbst zwischen die Abschnitte: Satz 0,35 s, Absatz 0,8 s,
  Kapitel 1,5 s. Der Regler „Pausen“ skaliert diese Werte. 10 ms Überblendung
  gegen Knackser.
- Tempo per `AVAudioUnitTimePitch` (0,8–1,2×, Tonhöhe bleibt).
- Lautheit auf ca. −18 LUFS angleichen, Spitzen auf −1,5 dBFS begrenzen.
- Export als `.m4a`, AAC-LC mono, ca. 48–64 kbit/s, mit Metadaten (Titel,
  „Vorgelesen mit KI“).
  - Später: Kapitelmarken (M4B) und MP3 (LAME) für CD-Player oder USB-Stick.

### 4.6 Speicher- und Platzbudget (M4, 16 GB)

| Zustand | RAM (Schätzung, aus Vocello-Messungen) |
| --- | --- |
| App ohne Modell | < 150 MB |
| Dokument umwandeln (1.7B-Base, 8-bit, Streaming) | ca. 3,1–3,6 GB |
| … mit 4-bit | ca. 2,4–3,0 GB |
| Stimme beschreiben (VoiceDesign) | ähnlich, nie gleichzeitig mit Base |

Auf der Platte: Modelle ca. 4–6 GB (Base + VoiceDesign, je nach Bit-Tiefe).
Hörbuch ca. 20–30 MB pro Stunde.

Grobe Erwartung: Liegt die RTF auf dem M4 bei 0,3–0,5, ist ein 30-seitiges PDF
(≈ 1 h Audio) in 20–30 Minuten fertig. Das misst S1.

---

## 5. Vorgehen in Phasen

Jede Phase endet mit etwas Lauffähigem. Die Spikes kommen zuerst, weil sie
Entscheidungen kippen können.

### Phase 0 – Spikes (Messen statt Raten)

| Spike | Frage | Ausgang |
| --- | --- | --- |
| **S1 Engine** | RTF, Spitzenspeicher und Klon-Overhead pro Aufruf auf dem M4: `mlx-audio-swift` vs. `VocelloQwen3Core` (Python-`mlx-audio` als Referenz). 4-bit vs. 8-bit im Blindtest auf Deutsch. | Engine und Bit-Tiefe gewählt. Ziel: RTF ≤ 0,5, Spitze ≤ 4 GB |
| **S2 Deutsch** | Wie liest das Modell Zahlen, Datum, Abkürzungen, englische Wörter? Fehlerrate bei 250, 500 und 900 Zeichen pro Abschnitt. Hilft eine niedrigere Temperatur? | Regelliste für die Normalisierung, Abschnittsgröße, Sampling-Werte |
| **S3 Stimme** | Bleibt eine per Design erzeugte Referenz über 30 Abschnitte geklont stabil? Funktionieren Beschreibungen auf Deutsch, oder besser auf Englisch (dann übersetzen)? Welche Stil-Knöpfe kommen wirklich an? | Workflow bestätigt, Texte für die Stil-Knöpfe festgelegt |
| **S4 PDFs** | 10 echte PDFs: Behördenbrief, Zeitungsartikel, Buch, zweispaltig, Scan, Handy-Foto | Bereinigungsregeln, OCR-Schwellen |

### Phase 1 – Kern-Pipeline als CLI
`vorleser-cli brief.pdf --voice helga --style ruhig -o brief.m4a`
- Mit Fortsetzen, Prüfung, Pausen, Lautheit, AAC.
- Golden-File-Tests für TextPrep.
- `vorleser-cli design-presets` erzeugt Preset-Kandidaten mit mehreren Seeds.
  Die besten werden angehört, ausgewählt und unter `Resources/Voices` eingecheckt.

### Phase 2 – App-MVP
- Bildschirme ① bis ④ und die Liste „Meine Hörbücher“.
- Preset-Stimmen und Stil-Knöpfe, sofort Vorlesen bei kurzen Texten.
- Player, Fortschritt mit Restzeit, Schlafsperre, Mitteilung, Teilen.

### Phase 3 – Eigene Stimme
- Geführte Aufnahme mit Pegel- und Rauschprüfung sowie Spracherkennungs-Check.
- Zustimmungs-Häkchen, Stimmen-Bibliothek.
- Audio-Import (Transkript per `SpeechTranscriber`, sonst x-vector).

### Phase 4 – Stimme beschreiben
- „Eigener Wunsch …“ als Freitext; Diktieren über die macOS-Diktierfunktion geht.
- VoiceDesign erzeugt 2 Vorschläge, die Oma wählt einen, er wird als Stimme gespeichert.

### Phase 5 – Feinschliff und Auslieferung
- OCR für Scans und Fotos (auch „Vom iPhone fotografieren“ via Continuity Camera).
- Kapitel, optional MP3.
- Einrichtungsassistent: Modelle einmalig laden, mit Prüfsummen und festen Revisionen.
- Helfer-Einstellungen, Signieren und Notarisieren.
- **Usability-Test mit der Oma**: 3 Aufgaben ohne Hilfe, dabei beobachten und
  danach nachbessern.
  1. Brief vorlesen lassen
  2. Hörbuch wiederfinden und anhören
  3. Eigene Stimme aufnehmen

---

## 6. Risiken

| Risiko | Gegenmittel |
| --- | --- |
| Deutsche Aussprache schwächer als kommerzielle Anbieter | kuratierte Presets, Normalisierung, Prüfung mit Wiederholung |
| Auslassungen oder Halluzinationen bei langen Texten | kurze Abschnitte, Dauer- und Spracherkennungsprüfung, neuer Seed |
| Swift-Port unreif oder langsamer als gedacht | `SpeechEngine`-Protokoll; Plan B Vocello-Core; Plan C `mlx-audio` (Python) nur für die CLI |
| Stil bei geklonter Stimme nicht steuerbar | ehrlich kommunizieren; Tempo und Pausen nachträglich; Aufnahme im gewünschten Ton |
| macOS 26 nötig (Vision-Dokumente, SpeechAnalyzer) | M4 unterstützt macOS 26; sonst Fallback auf `VNRecognizeTextRequest` / `SFSpeechRecognizer` |
| Missbrauch geklonter Stimmen | nur lokal, Zustimmungs-Häkchen, KI-Hinweis in den Metadaten (EU AI Act Art. 50 bei Veröffentlichung) |
| Einrichtung zu schwer für die Oma | Helfer richtet einmal ein; danach braucht die App kein Internet mehr |

---

## 7. Offene Fragen an dich

1. Läuft auf dem M4 schon **macOS 26 (Tahoe)**? Davon hängen OCR-Absätze und
   Spracherkennung ab.
2. Reicht **.m4a**, oder braucht die Oma **MP3** (CD-Player, Autoradio)?
3. Soll das alte Rust-Projekt in diesem Branch **gelöscht** werden, sobald die
   Umsetzung beginnt? `main` behält es ja.
4. Gibt es einen **Apple-Developer-Account** zum Signieren? Ohne ihn baust du
   die App per Xcode für ihren Mac, was auch geht.
5. Nur **Deutsch**, oder weitere Sprachen?

---

## Quellen

- Qwen3-TTS Repo & Modellübersicht: <https://github.com/QwenLM/Qwen3-TTS>
- Qwen-Blog zum Release (22.01.2026): <https://qwen.ai/blog?id=qwen3tts-0115>
- Technischer Bericht (Deutsch-WER/SIM, Langtext): <https://arxiv.org/pdf/2601.15621>
- Unabhängige Langtext-Studie „Taming Long-form Text-to-Speech“: <https://huggingface.co/papers/2609.16989>
- Base ignoriert `instruct` (HF-Diskussion): <https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice/discussions/38>
- mlx-audio (Python, Batching-Benchmark): <https://github.com/Blaizzy/mlx-audio>
- mlx-audio-swift (Qwen3-TTS-Port): <https://github.com/Blaizzy/mlx-audio-swift>
- Vocello / QwenVoice (Swift + MLX, Messungen, Optimierungen): <https://github.com/PowerBeef/Vocello>,
  `benchmarks/OPTIMIZATION.md`, `Packages/VocelloQwen3Core`
- qwen3-tts.cpp (ggml): <https://github.com/predict-woo/qwen3-tts.cpp>
- speech-swift (MLX/CoreML-Bibliothek): <https://github.com/soniqo/speech-swift>
- Deutsch-Klonen-Erfahrungen (PyTorch/MPS): <https://github.com/yauh/qwen3-tts-german-clones>
- Vision „Read documents“ (WWDC25): <https://developer.apple.com/videos/play/wwdc2025/272>
- SpeechAnalyzer (macOS 26, Deutsch): <https://blog.addpipe.com/apple-speechanalyzer-api/>
- Schriftgröße für ältere Menschen (Review): <https://pmc.ncbi.nlm.nih.gov/articles/PMC9376262/>
- Eigene Messungen des alten Projekts: [README.md](README.md) (Abschnitt Performance)
