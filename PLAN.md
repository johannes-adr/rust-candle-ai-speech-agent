# Plan: „Vorleser“ – PDF/Text → MP3 mit Qwen3-TTS

Stand: 16.10.2026 · Zielgerät: Mac mit M4, 16 GB RAM, macOS 26 · Status: **Plan, noch kein Code**

Ziel: Eine Mac-App, mit der eine Oma ohne Hilfe einen Brief, ein PDF oder einen
Text in eine MP3 verwandelt. Vorgelesen wird von einer fertigen Stimme, einer
beschriebenen Stimme („ruhig, warm, wie ein Märchen“) oder der eigenen,
geklonten Stimme. Das geht in allen 10 Sprachen von Qwen3-TTS, lokal und offline.

Umgesetzt wird auf dem Mac mit Claude Code. Arbeitsregeln dafür stehen in
[CLAUDE.md](CLAUDE.md).

---

## 1. Entscheidungen auf einen Blick

| Thema | Entscheidung | Warum |
| --- | --- | --- |
| Plattform | **Swift 6 + SwiftUI, native macOS-App** (macOS 26, Xcode 26) | App-Icon im Dock statt Terminal/Browser; PDFKit, Vision-OCR, Mikrofon, Teilen, Mitteilungen gibt es eingebaut |
| Inferenz | **MLX** (Metal-GPU) über `mlx-audio-swift`; `VocelloQwen3Core` als Plan B | 4/8-bit, ca. 3 GB Spitzenspeicher, schneller als Echtzeit (§2.2) |
| Modelle | **Qwen3-TTS-12Hz-1.7B-Base** (Klonen, Langtext) + **1.7B-VoiceDesign** (Stimme beschreiben) | Base hält eine Stimme über 100 Abschnitte gleich; VoiceDesign wird nur bei Bedarf geladen |
| Stil-Anweisungen | **Design → Klon**: Die Beschreibung erzeugt einmal eine Referenzaufnahme, das Dokument wird dann mit Base geklont | Offizieller Qwen-Workflow für konsistente Stimmen; Base ignoriert `instruct` |
| Sprachen (Vorlesen) | **Alle 10**: Deutsch, Portugiesisch, Englisch, Spanisch, Französisch, Italienisch, Russisch, Chinesisch, Japanisch, Koreanisch; automatisch erkannt | Qwen3-TTS kann genau diese 10 |
| Sprachen (Oberfläche) | **Deutsch + Portugiesisch** über String Catalog, folgt der Systemsprache | weitere Sprachen später ohne Code-Änderung |
| Fertige Stimmen | pro Sprache 2 Stimmen (Frau/Mann) × 4 Stile, **einmalig auf dem Mac erzeugt** und als Referenz (ALAC + Text) gespeichert | Im Normalfall wird VoiceDesign nie geladen → weniger RAM |
| Textaufbereitung | PDFKit + Vision-OCR + Bereinigung + Normalisierung je Sprache (Zahlen, Datum, Abkürzungen) | systemeigen, kein Zusatzmodell |
| Langtext | Abschnitte von **200–500 Zeichen** (CJK ca. ⅓), seriell, mit Prüfung und Wiederholung | Qwen3-TTS wird ab ca. 500 Wörtern pro Durchgang unzuverlässig (§2.3) |
| Ausgabe | **MP3**, CBR 64 kbit/s, mono, 44,1 kHz, ID3v2-Tags; lange Bücher zusätzlich als **eine MP3 pro Kapitel** | 44,1 kHz/CBR spielen auch alte CD-Player und Autoradios; ca. 29 MB pro Stunde |
| MP3-Encoder | **LAME 3.100** (LGPL) als SwiftPM-Abhängigkeit (`SwiftLAME`) oder als eigenes C-Target | macOS hat keinen MP3-Encoder eingebaut |
| Signieren | **Ohne Developer-Account**: auf dem M4 selbst mit Xcode bauen, Team = kostenloses „Personal Team“ (Apple-ID) | selbst gebaute Apps haben kein Quarantäne-Flag, also keine Gatekeeper-Warnung; die Mikrofon-Erlaubnis bleibt über Rebuilds erhalten |
| Altes Rust/Candle-Projekt | **in diesem Branch entfernt**, liegt weiter auf `main` | nur 0.6B, nur F32, 0,56–0,74× Echtzeit, keine Quantisierung |

---

## 2. Recherche-Ergebnisse

### 2.1 Qwen3-TTS-Familie (Open Source, Apache 2.0, seit 22.01.2026)

| Checkpoint | Kann | Stil per Anweisung | Rolle bei uns |
| --- | --- | --- | --- |
| 1.7B-VoiceDesign | Stimme aus Textbeschreibung | ✅ (Pflicht) | Referenzen für fertige und beschriebene Stimmen erzeugen |
| 1.7B-CustomVoice | 9 feste Sprecher (zh/en/ja/ko) | ✅ | **nicht** im MVP (keine Muttersprachler für die meisten Sprachen) |
| 1.7B-Base | Klonen ab ca. 3 s Referenz | ❌ (wird ignoriert) | **Hauptmodell** für jedes Dokument |
| 0.6B-Base / -CustomVoice | wie oben, kleiner | ❌ | Ausweichoption, falls 1.7B zu langsam |

Wichtig für uns:

- **Sprachen**: zh, en, ja, ko, de, fr, ru, pt, es, it. Für Deutsch gilt nur
  Hochdeutsch. Laut technischem Bericht hat Deutsch eine WER von 1,235
  (ElevenLabs 0,572) und eine Sprecherähnlichkeit von 0,775 (ElevenLabs 0,614).
  Die Verständlichkeit ist also gut, aber nicht Spitze.
- **Portugiesisch**: Laut Doku werden Brasilianisch und Europäisch genannt, eine
  Auswahl der Variante gibt es aber nicht. Die Aussprache unterscheidet sich
  stark. Der Weg zur richtigen Variante ist die Stimmbeschreibung
  („Muttersprachlerin aus Lissabon“ vs. „aus São Paulo“), das prüft Spike S3.
- **Sprachübergreifendes Klonen** geht (z. B. deutsche Referenz, portugiesischer
  Text). Dabei klingt eventuell Akzent mit. Deshalb hat jede Sprache eigene
  fertige Stimmen, und die eigene Stimme wird möglichst in der Lesesprache
  aufgenommen.
- **Klonen**: Mit Transkript (ICL-Modus) wird es am ähnlichsten, ohne Transkript
  per `x_vector_only_mode` schwächer. Empfohlen werden 10–15 s Referenz; länger
  macht es nur langsamer (Messung im alten Projekt).
- **Stil beim Klonen**: Base übernimmt Sprechweise und Tempo der Referenz,
  `instruct` wirkt dort nicht. Wer die eigene Stimme „fröhlich“ will, muss
  fröhlich aufnehmen.
- **Anweisungen** kommen laut Vocello zuverlässig an für neutral, ruhig,
  flüsternd und traurig. Fröhlich oder aufgeregt wirken eher als Richtung.

### 2.2 Laufzeit-Optionen auf Apple Silicon

| Option | Status | Gemessen / berichtet |
| --- | --- | --- |
| **Crane/Candle (Rust, altes Projekt)** | 0.6B, F32 (F16 bricht das Sampling) | **0,56–0,74× Echtzeit**, also langsamer als das Abspielen |
| PyTorch MPS (offizielles `qwen-tts`) | läuft | ca. 10–15 s pro Satz, schwer |
| `qwen3-tts.cpp` (ggml/Metal) | nur 0.6B-Base, Q8, jung | keine belastbaren Mac-Zahlen |
| `mlx-audio` (Python) | alle Varianten, 4/6/8-bit, Batching | 1.7B 6-bit: 1,67× Echtzeit bei 3,9 GB; Batch 8: 5,45× bei 4,1 GB |
| **`mlx-audio-swift`** | Base, CustomVoice, VoiceDesign, Streaming; **kein** Batching | keine veröffentlichten Zahlen |
| **Vocello (`VocelloQwen3Core`, MIT)** | Fork von mlx-audio-swift, stark optimiert, 1.7B 4/8-bit | **RTF 0,26–0,32** auf Mac mini M6, 16 GB (≈3–4× Echtzeit); 8-GB-M2: 1,4–1,9× Echtzeit; Spitzenspeicher **~3 GB**, über 10 min Langtext konstant |

**Folgerung:** MLX in Swift ist auf dem Mac die schnellste und sparsamste
Lösung, ohne Python und ohne Server. Ein M4 sollte zwischen den M2- und den
M6-Werten von Vocello liegen. Das misst Spike S1.

Vorgehen bei der Engine:
1. Start mit **`mlx-audio-swift`** (SwiftPM, MIT) hinter einem eigenen
   `SpeechEngine`-Protokoll.
2. Wenn S1 zeigt, dass Upstream zu langsam ist oder die Klon-Referenz bei jedem
   Aufruf neu berechnet: **`VocelloQwen3Core` vendoren** (MIT, per
   `git subtree`). Es bringt gecachte Klon-Prompts, verschmolzenes RoPE
   (+26 %) und einen kompilierten Code-Predictor (+8–11 %) mit.
3. Batching kommt nur, falls der Durchsatz nicht reicht.

> Vocello ist eine fertige MIT-App mit Design, Klonen und Langtext. Es ist aber
> ein „Studio“ für Fortgeschrittene, ohne PDF-Import, ohne MP3 und ohne
> Oma-Bedienung. Wir übernehmen die Erkenntnisse (und notfalls die Engine),
> nicht die Oberfläche.

### 2.3 Langtext-Stabilität

- Laut Qwen-Bericht ist Langtext stabil. Eine unabhängige Studie („Taming
  Long-form TTS“, 09/2026) widerspricht: unter 500 Wörtern zuverlässig, ab
  1.500 Wörtern bis zu 35–48 % Worst-Case-WER (Auslassungen, Halluzinationen).
- Daraus folgt: **kurze Abschnitte, jeder geprüft**. Sie lassen sich einzeln
  wiederholen und nach einem Abbruch fortsetzen.
- Ungeführte Takes schwanken zwischen Seeds um ca. 2,7 Halbtöne. Geklonte Takes
  bleiben laut Vocello bei der Referenz (ECAPA-Ähnlichkeit 0,81–0,87). Deshalb:
  feste Referenz plus fester Seed pro Abschnitt.

### 2.4 Systemeigene Bausteine (ohne Zusatzmodelle)

| Aufgabe | macOS-API |
| --- | --- |
| PDF-Text mit Zeilenpositionen | PDFKit (`PDFSelection.selectionsByLine()`, Bounds) |
| Scans / Fotos | Vision `RecognizeDocumentsRequest` (Absätze); Fallback `VNRecognizeTextRequest` |
| Word / RTF / ODT / HTML | `NSAttributedString(url:)` liest .docx, .odt und .rtf direkt |
| Sätze trennen, Sprache erkennen | NaturalLanguage (`NLTokenizer`, `NLLanguageRecognizer`), alle 10 Sprachen inkl. CJK |
| Zahlen ausschreiben | `NumberFormatter(.spellOut)` mit Locale der Lesesprache + eigene Regeln |
| Silbentrennung prüfen | `NSSpellChecker` mit Sprache des Dokuments |
| Transkript der Aufnahme, Qualitätsprüfung | `SpeechAnalyzer`/`SpeechTranscriber` (on-device). Zum Start ohne Russisch → dort `SFSpeechRecognizer` oder nur Dauerprüfung |
| Stilwunsch übersetzen (falls nötig) | Translation-Framework (on-device) |
| Tempo ohne Tonhöhenänderung | `AVAudioUnitTimePitch` (offline rendern) |
| 24 → 44,1 kHz | `AVAudioConverter` (bandbegrenzt) |
| MP3 | LAME 3.100 (`lame_encode_buffer_ieee_float`, `id3tag_*`) |

---

## 3. Bedienkonzept „für Oma“

### Regeln

1. **Eine Frage pro Bildschirm**, drei Schritte, immer „Zurück“ möglich.
2. **Groß**: Text ≥ 20 pt, Überschriften ≥ 30 pt, Knöpfe ≥ 60 pt hoch. Jeder
   Knopf hat Symbol **und** Wort. Kontrast ≥ 7:1.
3. **Keine Fachwörter**: kein „TTS“, „Modell“, „Klonen“, „MP3-Bitrate“.
   Stattdessen „Vorlesen lassen“, „Stimme“, „Hörbuch“.
4. **Nichts kaputt machbar**: Alles wird automatisch gespeichert. Abbrechen
   fragt nach. Nach Absturz oder Zuklappen macht die App weiter.
5. **Kein verstecktes Bedienen**: kein Hover, kein Doppelklick, kein Rechtsklick.
   Ziehen geht, ist aber nie der einzige Weg.
6. **Fester Ablageort**: `Musik › Vorgelesen`, zusätzlich als Liste
   „Meine Hörbücher“ auf dem Startbildschirm.
7. **Hilfe-Knopf** mit Name und Telefonnummer des Helfers (einstellbar).
8. Technik für Helfer im Einstellungsfenster (⌘,): Qualität, Ablageort,
   Protokolle, Stimmen verwalten.
9. **Sprache wird erkannt, nicht gefragt**: Schritt 2 zeigt „Sprache:
   Portugiesisch ✓ [ändern]“ und bietet nur Stimmen dieser Sprache an.

### Bildschirme (Oberfläche hier auf Deutsch, Portugiesisch analog)

```
① Start                                         ② Stimme
┌────────────────────────────────────────┐     ┌────────────────────────────────────────┐
│ Vorleser                     [ Hilfe ] │     │ Schritt 2 von 3: Wer soll vorlesen?    │
│                                        │     │ Sprache: Deutsch ✓          [ändern]   │
│ Was möchten Sie vorlesen lassen?       │     │ ┌────────┐ ┌────────┐ ┌──────────────┐ │
│ ┌──────────────────┐ ┌───────────────┐ │     │ │ Helga  │ │ Karl   │ │ Meine eigene │ │
│ │ [Datei]          │ │ [Stift]       │ │     │ │ warm   │ │ tief   │ │ Stimme       │ │
│ │ Datei auswählen  │ │ Text eintippen│ │     │ │[>Probe]│ │[>Probe]│ │ [o Aufnehmen]│ │
│ │ PDF, Word, Text  │ │ oder einfügen │ │     │ └────────┘ └────────┘ └──────────────┘ │
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

- **Kurzer Text** (unter ca. 1 Minute, z. B. ein Brief): Die App überspringt ③
  und **liest sofort vor**, während sie noch rechnet. Gespeichert wird trotzdem.
- **Probe** spielt eine gespeicherte Aufnahme ab, sofort und ohne Modell.
- **Eigene Stimme** führt Schritt für Schritt:
  1. Großer Lesetext in der gewählten Sprache (je Sprache ein fester Text, ca. 12 s).
  2. Roter Knopf, dann 3-2-1 und eine Pegelanzeige.
  3. Anhören, dann „So behalten“ oder „Nochmal“.
  4. Hinweise wie „Bitte etwas näher ans Mikrofon“.
  5. Häkchen „Das ist meine Stimme oder ich habe die Erlaubnis“.

  Das Transkript ist der feste Lesetext, die Oma muss nichts abtippen. Die
  Spracherkennung prüft nur, ob er vorgelesen wurde.
- **Stil bei eigener Stimme**: Dort steht ehrlich „Ihre Stimme klingt so, wie
  Sie sie aufgenommen haben“. Tempo und Pausen gehen trotzdem.
- **Fertig**: Ton plus Mitteilung. „Verschicken“ öffnet das Teilen-Menü (Mail,
  Nachrichten, AirDrop). Bei Büchern mit Kapiteln landet zusätzlich ein Ordner
  mit `01 Kapitel 1.mp3`, `02 …` daneben, passend für USB-Stick und CD.
- Ein eingebauter **Player** mit großem Play/Pause und „30 s zurück“ merkt sich
  die Position.

---

## 4. Technische Architektur

```
┌──────────── SwiftUI-App (Oma-Oberfläche, @Observable ViewModels) ───────────┐
│                                                                              │
│  DocumentImport ──► TextPrep ──────► ChunkPlanner ──► SynthesisJob ──► AudioOut
│  PDF/DOCX/TXT/      Bereinigung,     Absätze →        Engine-Aufruf,   Pausen, Tempo,
│  Einfügen, OCR      Sprache, Norm.   200–500 Zeichen  Prüfung, Retry   Lautheit, MP3
│                                                          │                   │
│                     VoiceStore (Stimmen) ── SpeechEngine (actor, MLX)        │
│                     Projects (Fortschritt auf Platte, Fortsetzen)            │
└──────────────────────────────────────────────────────────────────────────────┘
         dieselbe Pipeline headless:  vorleser-cli  (Spikes, Tests, Stimmen erzeugen)
```

### 4.1 Ordnerstruktur

```
project.yml                      XcodeGen → Vorleser.xcodeproj (nicht eingecheckt)
App/                             SwiftUI-Views, ViewModels, Assets, Info.plist,
                                 Localizable.xcstrings (de, pt)
Resources/Voices/                presets.json (Beschreibungen je Sprache) + erzeugte Referenzen
Resources/ReadAloud/             feste Lesetexte für die eigene Aufnahme, je Sprache
Packages/VorleserCore/           SwiftPM, ohne UI, testbar per `swift test`
├── Sources/DocumentImport/      PDFKit, NSAttributedString, Vision-OCR
├── Sources/TextPrep/            Bereinigung, Normalizer je Sprache, Satztrennung, ChunkPlanner
├── Sources/Speech/              SpeechEngine-Protokoll, MLXQwenEngine, ModelStore, VoiceStore
├── Sources/AudioOut/            QC, Pausen, Lautheit, Tempo, Resampling, MP3 (LAME)
├── Sources/Projects/            Manifest, Fortsetzen
├── Sources/vorleser-cli/
└── Tests/                       Golden-Files je Sprache, QC-Tests, Engine-Smoke (nur mit Modell)
docs/spikes/                     Ergebnisse der Spikes (Messwerte, Entscheidungen)
scripts/install.sh               Release bauen → /Applications/Vorleser.app
```

### 4.2 Kernschnittstellen (Skizze)

```swift
protocol SpeechEngine: Actor {
    func load(_ model: ModelKind) async throws                 // .base, .voiceDesign; nie beide gleichzeitig
    func unload() async
    func prepare(_ voice: Voice) async throws -> VoiceHandle   // Klon-Prompt einmal pro Stimme, gecacht
    func speak(_ text: String, voice: VoiceHandle, language: Language,
               seed: UInt64) -> AsyncThrowingStream<[Float], Error>   // streamt → flacher Speicher
    func design(description: String, sampleText: String, language: Language,
                seed: UInt64) async throws -> [Float]                  // nur VoiceDesign
}

enum Language: String, CaseIterable { case de, pt, en, es, fr, it, ru, zh, ja, ko }

// Pseudocode, Felder statt fertiger Typen:
Voice   { id, name, language, kind: preset|designed|recorded, referenceAudio, referenceText, description? }
Chunk   { index, text, spokenText, kind: sentence|paragraphEnd|heading, chapter, seed, status, duration, qc }
Project { id, title, sourceHash, language, voiceID, style, tempo, chunks }   // manifest.json
```

### 4.3 Text-Pipeline

1. **Import**
   - PDF-Seiten mit Text: PDFKit liefert Zeilen mit Position.
   - Seiten ohne Text: rendern und per Vision-OCR lesen.
   - .docx/.odt/.rtf: über `NSAttributedString`; .txt mit Kodierungserkennung.
   - Eingefügter Text: direkt.
2. **Sprache erkennen**: `NLLanguageRecognizer` über das ganze Dokument,
   eingeschränkt auf die 10 Sprachen. Ist sie unsicher, fragt Schritt 2 nach.
3. **Bereinigen** (nur PDF)
   - Kopf- und Fußzeilen: wiederkehrende Zeilen am Seitenrand (≥ 50 % der
     Seiten, Ziffern ignoriert) raus, ebenso einzelne Seitenzahlen.
   - Silbentrennung zusammenziehen, wenn `NSSpellChecker` das Wort kennt.
   - Zeilen zu Absätzen zusammenfügen.
   - Überschriften werden Kapitelmarken mit längerer Pause.
   - Fußnotenziffern, Tabellen und Bildunterschriften überspringen.
   - Zwei Spalten über die x-Position der Zeilen erkennen.
4. **Normalisieren**: ein `Normalizer` je Sprache, gebaut nur für das, was
   Spike S2 als Problem zeigt.
   - Für alle Sprachen: Zahlen per `NumberFormatter(.spellOut)` mit Locale,
     Abkürzungsliste je Sprache.
   - Ausgebaut zuerst **Deutsch und Portugiesisch** (Datum, Uhrzeit, Geld,
     Jahreszahlen, Ordinalzahlen, Einheiten, Telefonnummern, URLs).
     Beispiele: „3.5.2024“ → „dritter Mai zweitausendvierundzwanzig“;
     „12,50 €“ → „doze euros e cinquenta“ (pt).
   - Abgesichert per Golden-Files je Sprache (Eingabe → erwartete Aussprache).
5. **Abschnitte planen**
   - `NLTokenizer` trennt Sätze, ergänzt um die Abkürzungsliste.
   - Sätze werden innerhalb eines Absatzes gepackt, Ziel 200–500 Zeichen
     (zh/ja/ko ca. 70–170). Ein Absatz endet immer an einer Abschnittsgrenze.
   - Sätze über der Grenze werden an `;`, `:` oder `,` geteilt.
     Zahlen wie `19,99` und `19.99` bleiben zusammen.

### 4.4 Sprachsynthese (ressourcenschonend)

- **Nur ein Modell im Speicher.** Das Dokument läuft über Base. VoiceDesign wird
  nur für „Eigener Wunsch …“ und das Erzeugen der fertigen Stimmen geladen.
  Nach 60 s Leerlauf entlädt die App alles und braucht dann < 150 MB.
- **Klon-Prompt einmal pro Dokument** berechnen, nicht pro Abschnitt.
- **Streaming auch beim Export**: Audio geht stückweise auf die Platte. Vocello
  senkte damit den Spitzenspeicher von ~8 auf ~3 GB.
- **Seriell**, Seed = Hash(Projekt, Index, Versuch), damit Läufe reproduzierbar sind.
- **Prüfung je Abschnitt**, die billigen Prüfungen zuerst:
  1. NaN/Clipping prüfen, Stille am Ende abschneiden.
  2. Dauer plausibel? Erwartet: Zeichen ÷ Sprechrate der Stimme. Unter 0,5×
     oder über 2× gilt als verdächtig.
  3. Optional (an, wenn S1 es günstig misst): Spracherkennung on-device, dann
     WER bzw. CER gegen den Text. Über 15 % gilt als verdächtig.
  4. Verdächtiges mit neuem Seed wiederholen, höchstens 2-mal. Danach behalten
     und im Protokoll markieren.
- **Fortsetzen**: Jeder fertige Abschnitt liegt als `chunks/0001.caf` im
  Projektordner.
- **Energie**
  - `ProcessInfo.beginActivity` mit `.userInitiated`: Der Mac schläft nicht
    ein, der Bildschirm darf aus.
  - Bei Thermal-State `.serious` kurze Pausen.
  - Keine durchscheinenden UI-Effekte während der Arbeit (bei Vocello ~23 % Leistung).
- **Restzeit** aus der gemessenen Geschwindigkeit der ersten Abschnitte.

### 4.5 Audio-Ausgabe

- Pausen zwischen Abschnitten: Satz 0,35 s, Absatz 0,8 s, Kapitel 1,5 s.
  10 ms Überblendung gegen Knackser.
- Tempo per `AVAudioUnitTimePitch` (0,8–1,2×, Tonhöhe bleibt).
- Lautheit auf ca. −18 LUFS angleichen, Spitzen auf −1,5 dBFS begrenzen.
- 24 kHz → 44,1 kHz per `AVAudioConverter`.
- **MP3** über LAME: CBR 64 kbit/s, mono, 44,1 kHz (MPEG-1 Layer III), mit
  ID3v2-Tags: Titel, Interpret = Stimme, Album = Dokument, Track = Kapitel,
  Kommentar „Mit KI vorgelesen“.
  - Lange Dokumente mit Kapiteln: eine Gesamtdatei plus ein Ordner mit einer
    MP3 pro Kapitel.
- **Lizenz**: LAME ist LGPL. Für den privaten Gebrauch problemlos. Bei
  Weitergabe LAME dynamisch linken oder Objektdateien beilegen.

### 4.6 Speicher- und Platzbudget (M4, 16 GB)

| Zustand | RAM (Schätzung aus Vocello-Messungen) |
| --- | --- |
| App ohne Modell | < 150 MB |
| Dokument umwandeln (1.7B-Base, 8-bit, Streaming) | ca. 3,1–3,6 GB |
| … mit 4-bit | ca. 2,4–3,0 GB |
| VoiceDesign | ähnlich, nie gleichzeitig mit Base |

Auf der Platte:
- Modelle ca. 4–6 GB (Base + VoiceDesign).
- Fertige Stimmen: 10 Sprachen × 2 × 4 = 80 Referenzen à ~12 s, als ALAC ca. 25 MB.
- MP3 ca. 29 MB pro Stunde.

Grobe Erwartung: Bei einer RTF von 0,3–0,5 auf dem M4 ist ein 30-seitiges PDF
(≈ 1 h Audio) in 20–30 Minuten fertig. Das misst S1.

### 4.7 Bauen und Installieren ohne Developer-Account

1. Xcode 26 aus dem App Store installieren, dann `brew install xcodegen`.
2. Xcode › Settings › Accounts › Apple-ID hinzufügen. Damit entsteht das
   kostenlose „Personal Team“, das in `project.yml` als
   `DEVELOPMENT_TEAM` eingetragen wird.
3. `scripts/install.sh` erzeugt das Projekt mit `xcodegen`, baut die
   Release-Version mit `xcodebuild` und kopiert sie nach
   `/Applications/Vorleser.app`.
4. Kein App-Sandbox, kein Hardened Runtime nötig. Im `Info.plist` stehen
   `NSMicrophoneUsageDescription` und `NSSpeechRecognitionUsageDescription`.
5. Weil auf demselben Mac gebaut wird, gibt es kein Quarantäne-Flag und keine
   Warnung. Soll die App einmal auf einen anderen Mac:
   - Systemeinstellungen › Datenschutz & Sicherheit › „Dennoch öffnen“, oder
   - `xattr -dr com.apple.quarantine /Applications/Vorleser.app`.

   Rechtsklick › Öffnen reicht seit macOS 15 nicht mehr.
6. Ad-hoc-Signatur („Sign to Run Locally“) geht auch. Dann fragt macOS nach
   jedem Neubau wieder nach dem Mikrofon. Deshalb das Personal Team.

---

## 5. Vorgehen in Phasen

Jede Phase endet mit etwas Lauffähigem. Die Spikes kommen zuerst, weil sie
Entscheidungen kippen können. 🎧 markiert Stellen, an denen ein **Mensch
zuhören** muss; Claude kann Audio nur messen (Dauer, Spracherkennung, Pegel),
nicht hören.

### Phase 0 – Spikes (Messen statt Raten)

| Spike | Frage | Ausgang |
| --- | --- | --- |
| **S1 Engine** | RTF, Spitzenspeicher und Klon-Overhead pro Aufruf auf dem M4: `mlx-audio-swift` vs. `VocelloQwen3Core` (Python-`mlx-audio` als Referenz). 🎧 4-bit vs. 8-bit im Blindtest (de, pt). | Engine und Bit-Tiefe gewählt. Ziel: RTF ≤ 0,5, Spitze ≤ 4 GB |
| **S2 Sprachen** | Je Sprache ein Testsatz-Set (Zahlen, Datum, Geld, Abkürzungen, Fremdwörter). Mit Spracherkennung zurück in Text, dann vergleichen: was liest das Modell selbst richtig? Fehlerrate bei 250/500/900 Zeichen. Hilft eine niedrigere Temperatur? | Normalisierungsregeln je Sprache, Abschnittsgröße, Sampling |
| **S3 Stimme** | Bleibt eine Design-Referenz über 30 geklonte Abschnitte stabil? Beschreibungen in der Lesesprache oder auf Englisch? 🎧 pt-PT vs. pt-BR per Beschreibung erreichbar? Welche Stil-Knöpfe kommen an? | Workflow bestätigt, `presets.json` festgelegt |
| **S4 PDFs** | 10 echte PDFs: Behördenbrief, Zeitung, Buch, zweispaltig, Scan, Handy-Foto, ein portugiesisches PDF | Bereinigungsregeln, OCR-Schwellen |
| **S5 MP3** | Baut `SwiftLAME` mit Xcode 26? Wenn nicht: LAME 3.100 als eigenes C-Target. ID3v2 setzen, Datei in Musik/Finder prüfen. | Encoder-Weg gewählt |

### Phase 1 – Kern-Pipeline als CLI

`vorleser-cli brief.pdf --voice de-helga --style ruhig -o brief.mp3`
- Mit Spracherkennung, Fortsetzen, Prüfung, Pausen, Lautheit, MP3, Kapiteldateien.
- Golden-File-Tests für TextPrep je Sprache.
- `vorleser-cli design-presets`: erzeugt aus `presets.json` je Stimme und Stil
  3 Kandidaten (verschiedene Seeds) in einen Ordner.
- 🎧 Du hörst im Finder per Leertaste rein und löschst schlechte Kandidaten.
  `vorleser-cli adopt-presets` übernimmt jeweils den ersten verbliebenen.
  Gründlich anhören musst du Deutsch und Portugiesisch, den Rest nur stichprobenartig.

### Phase 2 – App-MVP
- Bildschirme ① bis ④, die Liste „Meine Hörbücher“ und die Spracherkennung in Schritt 2.
- Fertige Stimmen und Stil-Knöpfe, sofort Vorlesen bei kurzen Texten.
- Player, Restzeit, Schlafsperre, Mitteilung, Teilen.
- Oberfläche auf Deutsch und Portugiesisch.
- `scripts/install.sh`.

### Phase 3 – Eigene Stimme
- Geführte Aufnahme mit festem Lesetext je Sprache, Pegel- und Rauschprüfung,
  Spracherkennungs-Check.
- Zustimmungs-Häkchen, Stimmen-Bibliothek.
- Audio-Import: Transkript per `SpeechTranscriber`, sonst x-vector-Modus.

### Phase 4 – Stimme beschreiben
- „Eigener Wunsch …“ als Freitext, Diktieren geht.
- VoiceDesign erzeugt 2 Vorschläge, die Oma wählt einen, er wird als Stimme gespeichert.

### Phase 5 – Feinschliff
- OCR für Scans und Fotos, auch „Vom iPhone fotografieren“ via Continuity Camera.
- Einrichtungsassistent: Modelle einmalig laden, mit Prüfsummen und festen Revisionen.
- Helfer-Einstellungen.
- 🎧 **Usability-Test mit der Oma**: 3 Aufgaben ohne Hilfe, beobachten, nachbessern.
  1. Brief vorlesen lassen
  2. Hörbuch wiederfinden und anhören
  3. Eigene Stimme aufnehmen

---

## 6. Risiken

| Risiko | Gegenmittel |
| --- | --- |
| Aussprache schwächer als kommerzielle Anbieter, je Sprache unterschiedlich | kuratierte Stimmen, Normalisierung, Prüfung mit Wiederholung |
| Portugiesisch in der falschen Variante (BR statt PT) | Variante per Stimmbeschreibung steuern (S3); eigene Stimme klonen |
| Auslassungen oder Halluzinationen bei langen Texten | kurze Abschnitte, Dauer- und Spracherkennungsprüfung, neuer Seed |
| Swift-Port unreif oder langsamer als gedacht | `SpeechEngine`-Protokoll; Plan B Vocello-Core; Plan C `mlx-audio` (Python) nur für die CLI |
| Stil bei geklonter Stimme nicht steuerbar | ehrlich kommunizieren; Tempo und Pausen nachträglich |
| `SwiftLAME` ist Alpha | S5; Ausweg ist LAME als eigenes C-Target |
| Missbrauch geklonter Stimmen | nur lokal, Zustimmungs-Häkchen, KI-Hinweis im ID3-Kommentar (EU AI Act Art. 50 bei Veröffentlichung) |
| Einrichtung zu schwer für die Oma | Helfer richtet einmal ein; danach braucht die App kein Internet mehr |

---

## 7. Noch offen

1. **Portugiesisch aus Portugal oder Brasilien?** Davon hängen die fertigen
   Stimmen und die portugiesische Oberfläche ab (pt-PT vs. pt-BR).

---

## Quellen

- Qwen3-TTS Repo & Modellübersicht: <https://github.com/QwenLM/Qwen3-TTS>
- Qwen-Blog zum Release (22.01.2026): <https://qwen.ai/blog?id=qwen3tts-0115>
- Technischer Bericht (WER/SIM je Sprache, Langtext): <https://arxiv.org/pdf/2601.15621>
- Unabhängige Langtext-Studie „Taming Long-form Text-to-Speech“: <https://huggingface.co/papers/2609.16989>
- Base ignoriert `instruct` (HF-Diskussion): <https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice/discussions/38>
- Sprachen / Portugiesisch-Varianten (Doku): <https://www.mintlify.com/QwenLM/Qwen3-TTS/concepts/languages>
- mlx-audio (Python, Batching-Benchmark): <https://github.com/Blaizzy/mlx-audio>
- mlx-audio-swift (Qwen3-TTS-Port): <https://github.com/Blaizzy/mlx-audio-swift>
- Vocello / QwenVoice (Swift + MLX, Messungen, Optimierungen): <https://github.com/PowerBeef/Vocello>,
  `benchmarks/OPTIMIZATION.md`, `Packages/VocelloQwen3Core`
- qwen3-tts.cpp (ggml): <https://github.com/predict-woo/qwen3-tts.cpp>
- speech-swift (MLX/CoreML-Bibliothek): <https://github.com/soniqo/speech-swift>
- Deutsch-Klonen-Erfahrungen: <https://github.com/yauh/qwen3-tts-german-clones>
- SwiftLAME (LAME-Wrapper, LGPL): <https://github.com/hidden-spectrum/SwiftLAME>
- Kein MP3-Encoder in macOS: <https://developer.apple.com/forums/thread/128434>
- Signieren ohne bezahlten Account / Gatekeeper ab macOS 15: <https://flaviocopes.com/macos-open-anyway/>
- Vision „Read documents“ (WWDC25): <https://developer.apple.com/videos/play/wwdc2025/272>
- SpeechAnalyzer (macOS 26, Sprachen): <https://blog.addpipe.com/apple-speechanalyzer-api/>
- Schriftgröße für ältere Menschen (Review): <https://pmc.ncbi.nlm.nih.gov/articles/PMC9376262/>
- Messungen des alten Rust-Projekts: `README.md` auf `main` (Abschnitt Performance)
