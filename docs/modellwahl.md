# Modellwahl (Helfer-Einstellungen › Modell)

Der Helfer kann pro Aufgabe ein anderes Sprachmodell wählen, ohne Code zu ändern.

## Rollen

- **Vorlesen und Klonen** (`base`): das Hauptmodell für Vorlesen und Stimmenklonen.
- **Stimme beschreiben** (`voiceDesign`): erzeugt aus einer Beschreibung die Referenzstimme.

CustomVoice-Modelle werden nicht angeboten: ihre Sprecher sind fest und passen nicht zum Klon-Ablauf.

## Vorschläge

Eingebaut in `Packages/VorleserCore/Sources/ModelSetup/ModelChooser.swift` (`ModelSuggestions`):

- `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-{4bit,5bit,6bit,8bit,bf16}` (0,6 B: schneller, etwas schlechter)
- `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-{4bit,5bit,6bit,8bit,bf16}` (1,7 B: besser, langsamer)
- `mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-{4bit,5bit,6bit,8bit,bf16}`

Die Liste nennt nur Repos. Die Version (Commit) wird beim Wählen aufgelöst, nie fest kodiert.
Ein beliebiges anderes Hugging-Face-Repo lässt sich im Freitextfeld eintragen.

## Ablauf „Prüfen und laden“

1. Der Commit von `main` (bzw. der Revision des Repos) wird über die Hugging-Face-API aufgelöst.
2. Die Dateiliste mit Prüfsummen wird geholt. Nur Dateiliste und `config.json` werden gelesen, keine Gewichte.
3. Grobe Prüfung: Pflichtdateien da (`config.json`, `tokenizer_config.json`, `.safetensors`,
   `speech_tokenizer/`), `model_type` ist `qwen3_tts`, und `tts_model_type` passt zur Rolle
   (`base` bzw. `voice_design`). Sonst gibt es eine verständliche Meldung und nichts wird geladen.
4. Größe und freier Platz werden angezeigt. Dann lädt der bestehende Installer mit Fortschritt
   (Hugging-Face-Cache wird genutzt, wenn derselbe Stand dort liegt). Abbrechen lässt die Teildateien
   für den nächsten Versuch stehen.
5. Erst wenn das Modell vollständig und mit Prüfsummen geprüft im Modellordner liegt, wird die Wahl
   gespeichert. Die Sprachausgabe wird entladen; das neue Modell lädt beim nächsten Vorlesen.

Netz wird nur nach einem Klick auf „Prüfen und laden“ benutzt.

## Speicherort

Im Modellordner `~/Library/Application Support/Vorleser/Models`:

- `selection.json`: Rolle → gewähltes Modell (Repo und Commit)
- `manifests/<Ordnername>.json`: Dateiliste der gewählten Version
- `<Ordnername>/`: die geladenen Dateien (wie bisher)

Ohne `selection.json` gilt der eingebaute Standard aus `Manifests/models.json`. Dort wirkt die Einstellung
„Genauigkeit der Sprachausgabe“ (4 oder 8 Bit) auf das Hauptmodell. Eine eigene Wahl hat immer Vorrang.

„Zurück zum Standard“ löscht nur die Wahl. Die geladenen Dateien bleiben im Modellordner und
können später wieder gewählt werden. Platz wird dort nicht automatisch frei.

## Zentrale Auflösung

Engine, Einrichtungsassistent und CLI fragen nur `ModelSelection.current(role:bits:store:)`.
Die Dateiliste liefert `ModelStore.manifest(for:)` (eingebaut, sonst aus dem Modellordner).

## CLI

- `vorleser-cli models status` zeigt das gewählte bzw. eingebaute Modell je Rolle und Qualität.
- `vorleser-cli models use <base|voiceDesign> <repo> [--bits 4] [--revision main]` ändert den eingebauten
  Standard im Quellbaum (`models.json` und Manifest). Danach neu bauen. Dieselbe Prüfung wie in der App.

## Grenzen

- Nicht getestet: echte Modellläufe mit anderen Repos. Die Prüfung ist grob; ein Modell, das die Prüfung
  besteht, aber nicht läuft, wird erst beim ersten Vorlesen auffallen.
- Eine laufende Vorlesung wird nicht gegen Umschalten geschützt. Am besten zwischen zwei Vorlesungen wechseln.
- Die Modelle werden nicht automatisch gelöscht.
