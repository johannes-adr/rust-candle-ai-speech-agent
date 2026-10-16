# Die Mac-App (Phase 2, Oberfläche)

Stand: Oberfläche ①–④ ist klickbar. Die Sprachausgabe fehlt noch: Dahinter steht eine
**Attrappe** (siehe unten).

## Aufbau

```
project.yml                 XcodeGen → Vorleser.xcodeproj (nicht eingecheckt)
App/
  VorleserApp.swift         Einstieg: Hauptfenster + Einstellungen (⌘,)
  Model/                    @Observable: AppModel (Ablauf), AppSettings, PlayerModel
  Service/                  AudiobookService (Protokoll), PreviewAudiobookService, VoiceLibrary
  UI/                       Style (Konstanten, Farben, Knöpfe), RootView, StartView, VoiceView,
                            WorkingView (③, ④, Hinweise), SettingsView, Formatting
  Localizable.xcstrings     alle UI-Texte, de + pt-PT
  InfoPlist.xcstrings       Mikrofon-/Spracherkennungstexte, App-Name
App-Tests/OmaRulesTests     prüft Oma-Regeln, Übersetzungen, Presets, Lesetexte
Resources/Voices/           presets.json (vorläufig) + später die Referenzaufnahmen
Resources/ReadAloud/        fester Lesetext je Sprache (10) für die eigene Aufnahme
scripts/install.sh          Release bauen → /Applications/Vorleser.app
scripts/check-strings.sh    prüft, dass jeder Schlüssel de und pt-PT hat
```

Logik gehört ins Package; die App benutzt `DocumentImport` (Import, `importText`),
`TextPrep` (Spracherkennung, Abschnitte), `Projects` (Liste, Fortsetzen, Restzeit) und
`AudioOut`. Das Package wurde nicht verändert.

## Bauen und starten

```bash
brew install xcodegen
xcodegen generate
xcodebuild -scheme Vorleser -configuration Debug build
xcodebuild -scheme Vorleser -configuration Debug test     # Oma-Regeln, Strings
scripts/check-strings.sh
scripts/install.sh                                         # Release nach /Applications
```

Signieren: Standard ist „Sign to Run Locally“. Mit Personal Team:
`VORLESER_TEAM=<Team-ID> scripts/install.sh` (oder in Xcode das Team wählen). Kein Sandbox,
kein Hardened Runtime.

### Entwicklungshilfen (nur Debug)

Umgebungsvariablen: `VORLESER_DATA_DIR` (eigener Datenordner statt Application Support und
Musik), `VORLESER_PREVIEW_SECONDS` (Dauer der Simulation), `VORLESER_DEMO=start|text|voice|language|working|done|problem`,
`VORLESER_SNAPSHOT=<png>` (rendert das Fenster in eine Datei und beendet die App),
`VORLESER_APPEARANCE=light|dark`. Beispiel siehe `spike-output/app/`.

## Schnittstelle AudiobookService

`App/Service/AudiobookService.swift`: `start(_ job:) -> AsyncStream<AudiobookEvent>`,
`pause()`, `resume()`, `cancel()`, `hasSample`, `playSample`, `stopSample`, `listenAhead`.
Ereignisse: `.preparing`, `.progress`, `.finishing`, `.finished`, `.failed(reasonKey:)`,
`.stopped`. Fehler werden als Übersetzungsschlüssel gemeldet, nie als Rohtext.

## Was die Attrappe ist

`PreviewAudiobookService` simuliert nur die Arbeit. Echt sind: Abschnittsplanung (TextPrep),
Projekt im `ProjectStore`, CAF-Abschnitte, Restzeitschätzung, Lautheit und LAME-MP3 (AudioOut),
Fortsetzen. Unecht: Statt Sprache entsteht ein leiser 0,5-s-Ton je Abschnitt; die Dauer
der Simulation ist fest (Standard 5 s). Die Kopfzeile zeigt deshalb „VORSCHAU“. Ersetzen:
eine Klasse mit demselben Protokoll in `AppModel.init` (`makeService`) einsetzen und
`Speech` in `project.yml` zur Abhängigkeitsliste ergänzen.

## Abweichungen und offene Punkte

- **Systemdialoge sind klein**: Dateiauswahl (`NSOpenPanel`), Teilen-Menü (`ShareLink` statt
  `NSSharingServicePicker`) und der Ordner-Dialog der Einstellungen sind Systemfenster und
  halten Schrift ≥ 20 pt nicht ein. Eigene Dialoge (Hilfe, „Anhalten?“) sind groß.
- **Einstellungsfenster** ist für Helfer, daher normale Systemgröße (15 pt).
- Deaktivierte Knöpfe (z. B. „Probe“ ohne Aufnahme) sind absichtlich blass; dabei steht ein
  erklärender Satz in voller Größe.
- Tempo-Stufen: 0,9 / 1,0 / 1,1 (Bereich des Packages 0,8–1,2).
- Portugiesisch: Oberfläche und Texte als **pt-PT**; die Entscheidung PT/BR ist offen
  (PLAN.md §7). Nur `Localizable.xcstrings`/`InfoPlist.xcstrings` und die Beschreibungen in
  `presets.json` wären zu ändern.
- „Eigene Stimme“ führt zu „Kommt bald“ (Phase 3). „Eigener Wunsch …“ (Phase 4) fehlt.
- „Kurzer Text sofort vorlesen“ (ohne Schritt ③) ist nicht umgesetzt; ebenso Mitteilung
  nach Fertigstellung (nur Klang `Glass`).
- Hörproben und Referenzaufnahmen fehlen: „Probe“ ist deaktiviert, bis
  `Resources/Voices/<id>-<stil>.caf` existiert.
- Gleiche Titel überschreiben dieselbe MP3 im Ablageordner (`ProjectStore.outputURL`).
- Kontrast ≥ 7:1 ist rechnerisch für alle Schrift-Farbpaare in Hell und Dunkel getestet
  (`OmaRulesTests`); Größen ebenfalls. Ob es für die Oma wirklich gut lesbar ist,
  zeigt erst der Usability-Test (Phase 5).
