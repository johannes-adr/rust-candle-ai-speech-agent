# Phase 5: Einrichtung (Modelle einmalig laden)

Stand: Modellordner, Manifeste, Download, Import aus dem Hugging-Face-Cache und der
Einrichtungsassistent für den Helfer sind umgesetzt. Nach der Einrichtung braucht die App kein Netz.

## Aufbau

**Package `ModelSetup`** (eigenes Modul, ohne MLX). Begründung: Die Einrichtung muss ohne
Sprach-Engine laufen und getestet werden können; die Tests laufen in unter einer Sekunde statt nach
dem Bau von MLX. `VorleserSpeech` hängt davon ab (`ModelSpec` ist jetzt ein `typealias` für `ModelRef`).

| Typ | Aufgabe |
| --- | --- |
| `ModelRef` | Repo + Commit-Hash, Ordnername `<repo mit -->@<revision>` |
| `ModelManifest` | Dateiliste mit Größe und SHA-256, Pfadprüfung, `bundled(for:)` |
| `ModelStore` | `~/Library/Application Support/Vorleser/Models`, Status `missing/partial/ready/corrupt`, `verify` (voll), `locate` |
| `SpaceCheck` | benötigt gegen frei, Puffer 1 GiB + 10 % |
| `HFCacheImporter` | Quelle im HF-Cache per SHA-256 prüfen, `clonefile` (APFS, kein Platzverbrauch) |
| `ModelInstaller` | `plan(_:)` und `install(_:repair:)` als `AsyncThrowingStream<InstallEvent>` |
| `ManifestFetcher` | HF-API → Manifest (nur Entwickler, `vorleser-cli models manifest`) |

Manifeste liegen in `Packages/VorleserCore/Sources/ModelSetup/Manifests/<repo mit -->.json`
(nicht `Resources/Models/`: SwiftPM-Ressourcen müssen im Target liegen). Erzeugt mit
`vorleser-cli models manifest <repo> <revision> -o …`; die Git-Blob-ID jeder kleinen Datei wurde
gegen die API geprüft, LFS-Dateien nehmen `lfs.sha256`. `README.md` und `.gitattributes` fehlen
absichtlich. Neue Revision pinnen = neu erzeugen, `ModelSpec.pinned` ändern.

### Ablauf von `install`

1. Platzprüfung (nur was wirklich neu auf die Platte kommt; klonbare Cache-Dateien zählen 0).
2. Je Modell ein Zwischenordner `Models/.staging/<ordner>`. Fertige Dateien dort haben den
   endgültigen Namen, Teildateien `*.part`.
3. Je Datei: schon da → weiter; Datei im HF-Cache derselben Revision → SHA-256 der Quelle prüfen,
   klonen; sonst Download `https://huggingface.co/<repo>/resolve/<rev>/<pfad>` mit `Range`-Fortsetzen
   (Teildatei wird beim Fortsetzen neu gehasht), Prüfsumme nach der Datei, bei Fehler wird die
   Teildatei gelöscht.
4. Prüfmarke `.vorleser-ready.json` schreiben, dann ein einziges `rename` des Zwischenordners
   nach `Models/<ordner>`. Es gibt nie einen halb gefüllten Zielordner.
5. Pause = Task abbrechen; Teildateien bleiben, ein neuer Aufruf macht weiter.
   `repair: true` prüft auch fertige Modelle voll (gleiche Größe, anderer Inhalt).

Fehler: `notEnoughSpace`, `offline` (auch Verbindungsabbruch und zu früh geschlossene Antwort,
Teildatei bleibt), `server(status)`, `checksumMismatch`, `io`.

### Engine

`MLXQwenEngine(bits:store:cacheRoot:fallbackToHuggingFaceCache:)` sucht zuerst im `ModelStore`
(`locate`: Prüfmarke + Größen aller Dateien). Nur für Entwickler fällt sie auf den HF-Cache zurück
(Standard `true`; die App prüft vorher über `SetupState` ausschließlich den ModelStore und zeigt sonst
„noch nicht eingerichtet“). `tokenizer.json` fehlt in den Repos; `mlx-audio-swift` erzeugt es beim
ersten Laden lokal aus `vocab.json` + `merges.txt` im Modellordner (zusätzliche Dateien stören den
Status nicht).

### Kein Netz beim Laden

Quelltext: `Qwen3TTSModel.fromModelDirectory` liest nur lokale Dateien (Gewichte, Tokenizer über
`AutoTokenizer.from(modelFolder:)`, Sprach-Tokenizer, Sprecher-Encoder). Belege:

- Test `loadingFromStoreDoesNotTouchTheNetwork`: `URLProtocol`-Falle (greift für `URLSession.shared`,
  Kontrolle im Test), echtes Laden aus dem ModelStore, null Anfragen. Eigene `URLSession(configuration:)`
  sieht die Falle nicht.
- Deshalb zusätzlich auf Prozessebene: `scripts/offline-check.sh` liest einen Satz vor unter
  `sandbox-exec (deny network*)`; das Skript prüft vorher, dass die Sperre wirkt (curl scheitert).
  Ergebnis: Satz ohne Netz erzeugt (`spike-output/phase5/modellordner-ohne-netz.mp3`, 5,6 s, Debug-Build, RTF dort 3,3).

## Cache-Import auf diesem Mac (gemessen)

`vorleser-cli models install --voice-design`: Base-4bit und VoiceDesign-4bit (4,65 GB) in 2,3 s aus dem
HF-Cache übernommen. Datenträger (Data-Volume), freie KiB vorher/nachher: 11 749 684 → 11 749 440,
also **244 KiB** Unterschied bei 4,65 GB (clonefile). `models verify` (volle SHA-256) 1,1 s je Modell
(Cache warm). Die Cache-Dateien dürfen danach nicht verändert werden; löscht man den HF-Cache, gehören
die Blöcke dem ModelStore und der Platz wird erst dann „teuer“.

## Assistent (App/Setup)

- `SetupState.shared` entscheidet beim Start: Hauptmodell nicht bereit → `NotSetUpView` statt ①
  („Vorleser ist noch nicht eingerichtet. Bitte rufen Sie <Helfer> an.“, Telefonnummer groß, Knöpfe
  „Einrichten (für Helfer)“ und „Nochmal schauen“). Neu prüfen beim Zurückkehren in die App.
- `SetupAssistantView` ersetzt das Fenster: Willkommen → Was wird geladen (Größen, freier Platz,
  Dauer bei 50 MBit/s, Haken für VoiceDesign, Qualität) → Laden (Balken, Prozent, Restzeit, Anhalten /
  Fortsetzen) → Prüfen (volle SHA-256) → Fertig → Name/Telefon des Helfers (`AppSettings.helperName/Phone`,
  derselbe Ort wie in den Einstellungen) → „Fertig – übergeben“.
- Bit-Tiefe liest `SetupState` aus `UserDefaults` Schlüssel `modelBits` (4 oder 8, Standard 4).
  Die Helfer-Einstellungen müssen diesen Schlüssel schreiben.
- Texte `setup.*` (de + pt-PT). UI-Wörter ohne „Modell“ („Sprachdaten“), wegen `OmaRulesTests`.
- Debug: `VORLESER_DEMO=setup-welcome|setup-plan|setup-space|setup-loading|setup-problem|setup-checking|setup-done|setup-helper|notsetup`
  mit Dienst ohne Netz, Bilder in `spike-output/phase5/`. `VORLESER_SKIP_SETUP=1` übergeht die Weiche;
  `VORLESER_PREVIEW=1` ebenfalls.

### Einbinden in die Einstellungen

`SetupSettingsSection()` (`App/Setup/SetupSettingsSection.swift`) zeigt den Zustand beider Pakete und
den Knopf „Einrichtung erneut prüfen“. Sie ist **nicht** in `SettingsView` eingehängt (paralleler Umbau):
eine Zeile `SetupSettingsSection()` in der `Form` genügt.

## Befehle

```bash
vorleser-cli models status
vorleser-cli models install [--bits 4|8] [--voice-design] [--no-cache-import] [--repair]
vorleser-cli models verify
vorleser-cli models manifest <repo> <revision> -o <Datei>
scripts/offline-check.sh
VORLESER_NETWORK_TESTS=1 swift test --filter realHuggingFace   # echter Server, nur winzige Dateien + Range
```

## Offene Punkte

- Echter Download der Gewichte (GB) wurde nicht getestet (Vorgabe): geprüft sind winzige echte Dateien,
  `Range`-Antwort 206 über die CDN-Weiterleitung und alles Übrige gegen `URLProtocol`-Mock.
- Dauer-Schätzung vor dem Laden ist fest 50 MBit/s; erst während des Ladens gibt es eine gemessene Restzeit.
- Base-8bit ist nicht im ModelStore (nur 4-bit und VoiceDesign importiert); `install --bits 8` übernimmt es aus dem Cache.
- Hugging Face ist die einzige Quelle; fällt ein Commit dort weg, schlägt die Einrichtung fehl.
- „Eigener Wunsch …“ ohne VoiceDesign-Paket zeigt weiter die bestehende Meldung `problem.modelMissing`.
- Sichtprüfung am Bildschirm (Lesbarkeit für Helfer) steht aus; nur Bildschirmfotos der Demos.
