# Phase 1: Kern-Pipeline, CLI und Anbindung an die App

Stand: 16.10.2026 · Gerät: M4, 24 GB, macOS 26.6, Xcode 27 (Swift 6.4) · Modell: Base 4-bit
(`mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit`, Revision wie in `docs/spikes/S1-engine.md`).

## Aufbau

```
Packages/VorleserCore/Sources/
  Pipeline/        SynthesisJob (actor), SynthesisRequest/-Event/-Result, SpeechRate
  Speech/          + VoiceStore (presets.json, <id>-<stil>.caf/.txt), ReferenceFiles (WAV/ALAC)
  vorleser-cli/    read (Standard), voices, design-presets, adopt-presets
Packages/VorleserCore/Tests/PipelineTests/   FakeEngine + 20 Tests ohne Modell
App/Service/LiveAudiobookService.swift       echte Umsetzung von AudiobookService
App/Model/InstantPlayer.swift                „sofort vorlesen“
App/Service/Notifier.swift                   Mitteilung bei Fertig
```

### Öffentliche API `Pipeline`

```swift
public actor SynthesisJob {
    init(engine: any SpeechEngine, store: ProjectStore, config: SynthesisConfig = .init())
    nonisolated func start(_ request: SynthesisRequest) -> AsyncStream<SynthesisEvent>
    func pause(); func resume(); func cancel()
    static func existingProject(in:sourceHash:language:voiceID:style:) async -> Project?
    static func plainText(_ doc: TextDocument) -> String
}
struct SynthesisRequest { title, source: .file(URL)|.text(String)|.document(doc, sourceHash:, kind:),
                          language?, voice: Voice, style?, tempo, outputURL?, resumeProjectID?, pageCount?, sourceData?, sourceExtension? }
struct SynthesisConfig { maxRetries = 2, idleUnloadSeconds = 60, targetLUFS = -18, pauses, qc, thermalState, preventSleep … }
enum SynthesisEvent { stage, projectReady, chunkDone(SynthesisProgress), suspicious, coolingDown,
                      paused, resumed, exporting(fraction:), finished(SynthesisResult), stopped, failed(SynthesisFailure) }
enum SpeechRate { static func charsPerSecond(for: Language) -> Double }
```

### Ablauf eines Auftrags

1. **Import** (`DocumentImporter`) bzw. eingefügter Text; **Sprache** per `LanguageDetector`, falls nicht angegeben.
2. **Abschnitte** (`TextPreparer`), **Projekt** im `ProjectStore`: gleiches Dokument, Sprache, Stimme **und Stil**
   schon angefangen → dort weitermachen (`existingProject`). Fehlgeschlagene Abschnitte bekommen beim
   Fortsetzen eine neue Chance; fertige Abschnitte ohne lesbare CAF gelten wieder als offen (`ProjectStore.reconcile`).
3. **Genau ein Modell** (`engine.load(.base)`), `prepare(voice)` einmal, dann je Abschnitt `speak` als Strom.
4. **Prüfung** je Abschnitt (`ChunkQC`): NaN/Inf, Clipping, Stille trimmen, Dauer gegen `Zeichen ÷ Sprechrate`
   (unter 0,5× oder über 2× verdächtig). Bei Verdacht bis zu **2 Wiederholungen** mit neuem Seed
   (`SeedDerivation(Projekt, Index, Versuch)`); danach wird der Versuch mit dem besten Dauerverhältnis
   behalten und als `suspicious` markiert. Liefert die Engine gar kein Audio, bleibt der Abschnitt `failed`
   und fehlt in der MP3; nach 3 solchen Abschnitten in Folge bricht der Auftrag ab.
5. **CAF** über `ChunkStore` (atomar), `markChunkDone`/`markChunkSuspicious`, Ereignis `chunkDone` mit Restzeit
   (`ETAEstimator`) und Datei (für „sofort vorlesen“).
6. **Export** (`AudioExporter`): Pausen Satz 0,35 / Absatz 0,8 / Kapitel 1,5 s, −18 LUFS, Tempo, 44,1 kHz,
   LAME CBR 64 mono, ID3 (Titel, Interpret = Stimme, Album = Dokument, Kommentar „Mit KI vorgelesen“, je
   Sprache übersetzt), bei mehr als einem Kapitel zusätzlich ein Ordner `<Name> – Kapitel/` mit einer MP3 je Kapitel.
7. **Energie**: `ProcessInfo.beginActivity(.userInitiated)` während der Arbeit; bei Thermal-State `.serious`
   oder schlimmer 3 s Pause vor jedem Abschnitt; nach 60 s Leerlauf `engine.unload()`.

Pause hält vor dem nächsten Abschnitt an (ein laufender wird noch fertig). Abbrechen beendet nach dem
laufenden Stromstück; alles Fertige bleibt, ein neuer Start mit demselben Dokument macht weiter.

### Sprechrate (Dauerprüfung)

Gemessen an `spike-output/S1/*.wav` (je 3 Abschnitte à ca. 300 Zeichen, Referenzstimme „ruhig, warm“,
Stille am Rand eingerechnet):

| Sprache | 4-bit | 8-bit | Standard |
| --- | --- | --- | --- |
| de | 15,5 Zeichen/s | 16,2 | **15,8** |
| pt | 14,4 | 15,4 | **14,9** |

Die übrigen Sprachen sind **Schätzwerte** (en 15, es 15,5, fr 15, it 15, ru 14; zh 4,5, ja 7, ko 6,5
Zeichen/s; CJK zählt Zeichen = Silben/Moren). Sie müssen nur auf ±30 % stimmen, weil das Fenster 0,5×–2×
beträgt. Zu messen in S2/Phase 5, sobald es Referenzen und Hörproben je Sprache gibt.

## VoiceStore und Stimmen

`Speech/VoiceStore.swift` liest `Resources/Voices/presets.json` (dieselbe Datei wie die App; `VoiceLibrary` in der
App ist nur noch eine Hülle darum) und je Stimme/Stil `<id>-<stil>.caf` (ALAC) plus `<id>-<stil>.txt`.
`presets.json` hat jetzt zusätzlich je Stimme einen englischen `design`-Text und oben `styleDesign` je Stil für
VoiceDesign. **Eingecheckt sind vorerst nur** `de-helga-calm` und `pt-teresa-calm` (aus den S1-Referenzen,
ALAC 16 bit, je ca. 250 KB, 9,7 s). Die portugiesische Referenz ist **brasilianisch** erzeugt (S1); die Oberfläche
steht auf pt-PT. Entscheidung PT/BR bleibt offen (PLAN §7).
Fehlt der gewünschte Stil, nimmt die CLI mit Hinweis `calm`; die App spielt dann keine Probe.

## CLI

```bash
cd Packages/VorleserCore && swift build -c release --product vorleser-cli
V=.build/release/vorleser-cli
$V brief.pdf --voice de-helga --style ruhig -o brief.mp3     # liest, prüft, schreibt MP3
$V - --lang de < text.txt -o out.mp3                          # Text von der Standardeingabe
$V voices                                                      # Stimmen und vorhandene Referenzen
$V design-presets ../../spike-output/presets --lang de --voice de-helga --style calm
$V adopt-presets ../../spike-output/presets                    # erster verbliebener Kandidat → Resources/Voices
```

Optionen von `read`: `--voice`, `--style` (calm/happy/fairytale/factual, auch ruhig/froh/märchen/sachlich),
`--tempo 0,8…1,2`, `--lang`, `--bits 4|8`, `-o`, `--title`, `--work-dir` (eigener Projektordner),
`--voices-dir`, `--fresh` (angefangenes Projekt verwerfen), `--max-retries`. Fortschritt steht auf stderr
(`[ 5/10]  42 %  Rest 00:57  RTF 0.83`), Zusammenfassung auf stdout. Strg-C hält sauber an (Exit 130). Verdachtsfälle
stehen im Terminal und, wenn es welche gibt, in `<out>.protokoll.txt`.

`design-presets <Ordner>` erzeugt je Stimme und Stil 3 Kandidaten (`<id>-<stil>-<n>.wav`, 16 bit, Finder-Leertaste)
mit dem festen Lesetext aus `Resources/ReadAloud` (ca. 10–12 s), Seeds stabil aus Stimme/Stil/Nummer.
Die Engine nutzt dafür jetzt den **Streaming-Pfad** von VoiceDesign (`generateStream`); gemessene Spitze siehe unten.
`adopt-presets` nimmt je Stimme/Stil den kleinsten verbliebenen Index und schreibt ALAC + `.txt`.

## Messwerte Ende-zu-Ende (Release, `vorleser-cli`, Base 4-bit, Referenz-Cache warm)

Dateien: `spike-output/phase1/` (Quelltexte in `docs/phase1-beispiele/`).

| | Brief de (≈1.500 Zeichen, 10 Abschnitte) | Text pt (≈ 800 Zeichen, 6 Abschnitte) |
| --- | --- | --- |
| Audiodauer MP3 | 1:53 | 0:56 |
| Gesamtzeit (inkl. Laden, Export) | 95,8 s | 53,6 s |
| Rechenzeit Sprache / Audio | 92,6 s / 106,3 s | 51,6 s / 52,4 s |
| **RTF Sprache / gesamt** | **0,87 / 0,90** | **0,99 / 1,02** |
| Spitze `phys_footprint` | 5,0 GB | 4,9 GB |
| am Ende (Modell geladen) | 2,6 GB | 2,5 GB |
| Wiederholungen / Verdacht / ohne Audio | 0 / 0 / 0 | 0 / 0 / 0 |
| ffprobe | MP3, 44100 Hz, mono, 64 kb/s, LAME 3.100, ID3 (Titel, Interpret Helga, Album, Kommentar) | dto., Interpret Teresa, Kommentar „Lido com IA“ |

RTF 0,87–0,99 passt zu S1 (0,82–0,95); das Ziel 0,5 aus dem Plan ist damit weiter verfehlt (Vocello-Optimierungen
offen, siehe S1). Die Spitze von 5 GB ist der Footprint des ganzen Prozesses (Modell 2,5 GB + MLX-Arbeitsspeicher
+ Export), nicht die MLX-Spitze (3,1–3,2 GB je Abschnitt in S1).

### Fortsetzen nach hartem Abbruch

Brief de, `kill -9` nach dem 5. von 10 Abschnitten (PID-Kill, kein sauberes Anhalten), danach derselbe Befehl
ohne `--fresh`: Ausgabe `Projekt E1A3F81F (de), 10 Abschnitte, fortgesetzt: 5 schon fertig`, es wurden nur die
Abschnitte 6–10 erzeugt (5 Abschnitte, 58 s Rechenzeit), die MP3 hat 1:47 und enthält alle 10 Abschnitte.

## App

`LiveAudiobookService` (App/Service) ersetzt die Attrappe und übersetzt `AudiobookJob` → `SynthesisRequest` und
`SynthesisEvent` → `AudiobookEvent` (neu: `.chunkReady`). `PreviewAudiobookService` bleibt als Debug-Option
(`VORLESER_PREVIEW=1`; Demo-Bildschirme für Screenshots brauchen sie). Die Kopfzeile „VORSCHAU“ erscheint nur noch dann.
`project.yml` hängt `Speech` und `Pipeline` an.

- **Probe**: spielt die Referenz aus dem `VoiceStore` (derzeit nur Helga und Teresa, Stil „ruhig“).
- **Sofort vorlesen**: Texte mit geschätzter Dauer < 60 s (`Draft.isShort`, Zeichen ÷ `SpeechRate` ÷ Tempo) starten
  `InstantPlayer`: die fertigen Abschnitte werden nacheinander mit den MP3-Pausen abgespielt, sobald der erste da
  ist; gespeichert wird trotzdem. Schritt ③ zeigt einen Hinweis. Beim Fertigwerden wird erst zu Ende gehört.
- **Fertig**: Ton `Glass` plus Mitteilung (`UserNotifications`, nur wenn die App nicht vorne ist; Erlaubnis wird
  beim ersten Start angefragt).
- Neue Texte (de/pt-PT): `problem.noVoice`, `problem.modelMissing`, `working.instant`, `notify.done.*`.
- Debug ohne Klicken: `VORLESER_DEMO=convert VORLESER_TEXT_FILE=<txt> VORLESER_DATA_DIR=<ordner>
  VORLESER_RESULT_FILE=<txt> [VORLESER_SNAPSHOT=<png>]` tippt den Text ein, startet, wartet auf „Fertig“ und beendet
  die App.

Gemessen mit diesem Mechanismus (**Debug-Build**, kurzer Brief 270 Zeichen, instant = ja): Ende nach 52,7 s
(inkl. Abspielen), MP3 18,7 s, Interpret Helga, Kommentar „Mit KI vorgelesen“, Bildschirm „Fertig!“ ohne
Vorschau-Zeile (`spike-output/phase1/app-done.png`). Debug-Builds rechnen die Modellschleife unoptimiert, die
RTF ist dort nicht aussagekräftig. Nicht geprüft: Klang des Sofort-Vorlesens, Mitteilung (App war im Vordergrund),
Pause/Anhalten per Klick, Probe-Knopf per Klick.

### VoiceDesign im Streaming-Pfad (gemessen)

`design-presets --voice de-helga --style calm` (3 Kandidaten, 10,8–13,8 s Audio): RTF 0,56–0,60, Spitze
Footprint **3,4 GB** (S1: 9,8 GB ohne Streaming). Damit ist die S1-Auflage erfüllt.

## Offene Punkte

- **Hören**: Alles, was nach Klang beurteilt wird, ist offen (siehe Hörproben im Bericht): Verständlichkeit von
  Zahlen/Datum/Geld im Brief, Pausen und Lautheit der MP3, Brasilianisch vs. Portugiesisch, ob die Referenzen taugen.
- **Seitenzuordnung**: `DocumentImport` liefert keine Seite je Block. „Seite x von y“ ist eine Näherung nach
  Zeichenanteil (`SynthesisJob.pageIndices`). Besser: Seite je Block im Importer mitführen.
- **Pause** wirkt erst zwischen Abschnitten, nicht mitten im Abschnitt.
- **Abbruch** wartet, bis das Streamstück (0,32 s) zu Ende ist; die Engine rechnet den laufenden Abschnitt kurz
  weiter, bis die Task-Abbruchprüfung greift.
- **ETA** am Anfang unscharf: gewichtet nach Zeichen, die ersten (kurzen) Abschnitte sind überproportional teuer
  (Warmlauf). Nach 3–4 Abschnitten stimmt sie auf ca. 10–20 %.
- **RTF** ist in einem Debug-Build der App deutlich schlechter als im Release (kein Optimierer für MLX-Swift);
  für echte Messungen `scripts/install.sh` bzw. Release bauen.
- Spracherkennung (WER/CER) als dritte Prüfung ist nicht eingebaut (PLAN: „optional, an wenn S1 es günstig misst“;
  noch nicht gemessen).
- Nur 2 von 80 Referenzen eingecheckt; `design-presets` für alle Sprachen läuft eine Weile und braucht die Hörprobe.
- Modell-Einrichtung (Download, Prüfsummen) fehlt; die Engine liest den HF-Cache `~/.cache/huggingface/hub`.
