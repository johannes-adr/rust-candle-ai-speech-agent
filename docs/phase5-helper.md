# Phase 5: Helfer-Einstellungen, iPhone-Kamera, Foto-OCR

Stand: 16.10.2026 · M4, macOS 26.6, Xcode 27 (Swift 6.4). Bildschirmfotos: `spike-output/phase5/`.

## 1. Helfer-Einstellungen (⌘,)

`App/Helper/`, Einstieg `HelperSettingsView` (ersetzt den Inhalt von `SettingsView`). Normale Systemgröße (15 pt), oben der Hinweis
„Dieses Fenster ist für den Helfer“. Reiter:

| Reiter | Inhalt |
| --- | --- |
| Helfer | Name, Telefon, „So sieht der Hilfe-Knopf aus“ (Vorschau mit denselben Größen wie `HelpOverlay`) |
| Ablage | Ordner (Standard Musik › Vorgelesen), im Finder zeigen, „Kapitel zusätzlich als einzelne Dateien“ |
| Qualität | „Schneller (empfohlen)“ = 4-bit, „Etwas genauer“ = 8-bit mit ehrlichem Hinweis (Spike S1: ca. 12 % langsamer, ca. +0,4 GB); Tempo-Standard; Abschnitt „Einrichtung“ (`SetupSettingsSection`) |
| Stimmen | alle Stimmen (fertig/aufgenommen/beschrieben), Probe, Umbenennen, Löschen mit Nachfrage (nur eigene und beschriebene), Import einer Audiodatei (`VoiceImportForm`, vorher `OwnVoiceSettingsSection`) |
| Hörbücher | Größe auf der Platte, „Zwischendateien aufräumen“ (nur fertige Projekte, mit Nachfrage), Löschen mit Nachfrage (die fertige Datei bleibt) |
| Protokolle | Verdachtsfälle/Fehler der letzten Läufe mit Text, „Protokoll kopieren“, „Ordner der Logs öffnen“ |

### UserDefaults-Schlüssel (`AppSettings`)

`helperName`, `helperPhone`, `outputDirectory`, **`modelBits`** (Int 4 | 8, Standard 4; derselbe Schlüssel liest `SetupState`),
`defaultTempo` (`slower|normal|faster`, wirkt in `makeDraft`), `chaptersAsFiles` (Bool, Standard `true`).
Bei 8-bit ohne eingerichtetes Hauptmodell zeigt der Reiter „muss einmal eingerichtet werden“ und einen Knopf zum Assistenten
(`ModelStore.status` über `SetupState.shared.service`). Die Qualität wirkt beim nächsten Laden der Sprachausgabe; die Engine
wird dort nicht umgebaut (Sache von ModelStore/Setup).

### Package

- `Projects/ProjectMaintenance.swift`: `diskUsage`, `overview`, `cleanIntermediates` (löscht nur `chunks/`, nur bei `state == .finished`
  und vorhandener MP3; setzt `Project.intermediatesRemoved`, damit `reconcile` das Projekt nicht wieder „offen“ macht).
- `Projects/ProblemProtocol.swift`: `ProblemProtocol.problems/render`, `ProjectStore.recentProblems`.
- `Projects/EventLog.swift`: Textprotokoll `~/Library/Logs/Vorleser/vorleser.log` (Rotation bei 512 KB). `App/Helper/AppLog` schreibt in
  `os.Logger` (Subsystem `de.vorleser.app`, Kategorien import/work/camera/helper) **und** in die Datei. Nie Dokumenttext.
- `Pipeline`: `SynthesisRequest.writeChapterFiles` (Standard `true`), von `AudiobookJob` durchgereicht.

## 2. „Vom iPhone fotografieren“ (Continuity Camera)

Startbildschirm ①: dritte, breite Karte unter „Datei auswählen“ / „Text eintippen“ (`CameraCard`). Ein Klick startet.

**Gewählter Weg: `AVCaptureDevice` vom Typ `.continuityCamera`** mit eigener großer Oberfläche (Live-Bild, großer Knopf „Foto machen“),
Foto per `AVCapturePhotoOutput` (JPEG). Begründung: Die Menü-Variante („Von iPhone importieren“ über `NSServicesMenuRequestor`) gibt es nur als kleines
Systemmenü, lässt sich nicht von einem eigenen Knopf auslösen und verletzt damit die Oma-Regeln (Schrift, kein Rechtsklick/Menü); `ImageCaptureCore` ist für
Kameras am Kabel/Netz, nicht für Continuity. Der Preis: keine Dokumenten-Erkennung des iPhones, das Zuschneiden ersetzt unsere OCR (Drehung, Schiefstand, Rand).

Info.plist (aus `project.yml`): `NSCameraUsageDescription` (de/pt in `InfoPlist.xcstrings`) und `NSCameraUseContinuityCameraDeviceType = YES`
(sonst meldet macOS das iPhone nur als externe Kamera; `findPhone` nimmt zur Sicherheit auch `.external` mit „iPhone/iPad“ im Namen).

Ablauf (`CameraFlow`, `CameraViews`): iPhone suchen (freundlicher Hinweis, sucht jede Sekunde weiter; „Kamera nicht erlaubt“ mit Knopf zu den
Systemeinstellungen) → Live-Bild → Foto → „Ist die Seite gut zu lesen?“ (Ja, weiter / Nochmal fotografieren) → „Noch eine Seite?“ (Noch eine Seite /
Fertig, jetzt lesen) → Lesen („Seite 2 von 3“) → bei unlesbaren Seiten eine Meldung (Trotzdem weiter / Neu fotografieren) → Schritt ②.
Zurück ist immer da; mit aufgenommenen Fotos fragt „Fotos verwerfen?“ nach. Fotos liegen nur kurz in einem temporären Ordner und werden nach dem Lesen gelöscht.
Titel/Quelle: Titel aus dem ersten Satz, `sourceKind = "image"`, Hash über alle Bilder.

Kamera-Attrappe `DemoCamera` (nur Debug) für Tests und Bildschirmfotos.

## 3. Foto-OCR (`DocumentImport/PhotoImport.swift`)

`DocumentImporter.importPhotos(at:languageHint:progress:)`: mehrere Bilder → ein Dokument in der Reihenfolge der Dateien (Seitenzahlen und wiederkehrende
Kopfzeilen entfernt die vorhandene Bereinigung über alle Seiten), `ImportResult.rotatedPages` / `unreadablePages`. Einzelne Bilddateien (`importDetailed`) laufen jetzt denselben Weg.

- **Drehung 90/180/270°**: `PhotoOrientation.uprightTurns` lässt eine schnelle Erkennung (1400 px) in allen vier Lagen laufen und wählt die mit der größten Summe
  „Sicherheit × Buchstaben“; nur wenn sie ≥ 1,6-fach besser als die Ausgangslage ist (und ≥ 25), wird gedreht. Ist die Ausgangslage schon klar gut (≥ 400), wird nicht weiter probiert.
- **Ränder**: angeschnittene Zeilen (berühren die äußeren 1,2 % des Bildes) werden verworfen; berührt mehr als ein Viertel der Zeilen den Rand
  (sehr enges Foto), bleibt alles. Nur für Fotos, nicht für PDF-Scans.
- **Schiefstand**: wie bisher aus den Zeilenwinkeln (`OCR.finish`).
- **Gelernt (Stillstand)**: Mehrere gleichzeitige synchrone `VNRecognizeTextRequest`-Aufrufe aus dem Swift-Concurrency-Pool ließen die Tests
  hängen (Vision wartet auf einen Thread, den es selbst belegt). Alle synchronen Vision-Aufrufe laufen jetzt über `VisionQueue` (eigene serielle Warteschlange).

## Tests

- Package: `MaintenanceTests` (Aufräumen nur `chunks/` und nur bei fertigen Projekten, MP3 bleibt, Löschen, Protokoll, Protokolldatei), `chapterFilesCanBeSwitchedOff`,
  `PhotoImportTests` (3 Seiten in Reihenfolge, Seitenzahlen weg, Drehung 90/180/270 an synthetischen Seiten und am Fixture `foto.jpg`, Schiefstand 3°, angeschnittener Rand, leere/kaputte Seiten, Randfilter, Drehhelfer).
- App: `HelperTests` (Einstellungen persistieren inkl. `modelBits`, eingebaute Stimmen nicht löschbar, eigene löschen/umbenennen, Aufräumen, Protokolltext),
  `CameraFlowTests` (Attrappe: kein iPhone → Warten → Start, Erlaubnis verweigert, zwei Seiten, Wiederholen, Fehlaufnahme/iPhone weg, Zurück fragt nach,
  leeres Ergebnis, unlesbare Seiten, echtes Lesen von zwei Fixture-Fotos bis Schritt ②).

## Entwicklungshilfen (Debug)

`VORLESER_DEMO=settings-helper|settings-folder|settings-quality|settings-voices|settings-books|settings-logs|home|camera-waiting|camera-denied|camera-shoot|camera-review|camera-more`,
`VORLESER_DEMO_PHOTO=<jpg>`, `VORLESER_SNAPSHOT=<png>`, `VORLESER_DATA_DIR`. Beispieldaten legt `HelperDemos.seed` im Datenordner an. Die Einstellungs-Demos rendern
denselben Inhalt in einem eigenen Fenster; die Reiterleiste erscheint im Bildschirmfoto nicht (liegt außerhalb des Inhalts).

## Offen / ehrlich

- **Nur mit iPhone prüfbar**: Erkennung des iPhones, Live-Bild, echte Aufnahme (Auslösen, Fokus, Auflösung), Verhalten beim Abziehen/Sperren, Kameraerlaubnis-Dialog beim ersten Mal,
  Wirkung von `NSCameraUseContinuityCameraDeviceType`. Ohne Gerät getestet wurde alles bis zur Kamera-Schnittstelle (Attrappe).
- Echte Handyfotos (Perspektive, Biegung, Schatten, Hand am Rand) fehlen weiterhin; die Schwellen der Drehung und des Randfilters stammen aus synthetischen Seiten.
- Perspektivkorrektur (Trapez) ist nicht eingebaut; Vision liest leicht trapezförmige Seiten, stark verzerrte nicht gesondert.
- Reihenfolge der Seiten lässt sich nur durch „Nochmal fotografieren“ der letzten Seite ändern, nicht beliebig umsortieren.
- 8-bit-Wahl: Der Hinweis fragt nur den Modellspeicher; ob die Engine im laufenden Betrieb umschaltet, entscheidet Setup/ModelStore.
- Systemdialoge (Ordnerauswahl, Bestätigungen im Einstellungsfenster) sind klein; das ist im Helferfenster gewollt.
- Reiter-Bildschirmfotos zeigen nur den Inhalt; „Probe“ spielt mit AVAudioPlayer (nicht per Bildschirmfoto prüfbar).
