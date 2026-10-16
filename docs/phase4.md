# Phase 4: Stimme beschreiben (Design → Klon)

Stand: 16.10.2026 · M4, 24 GB, macOS 26.6 · Messdateien: `spike-output/phase4/` · Spike: [S3](spikes/S3-stimme.md)

## Ablauf

1. Wunsch (Freitext in der Oberflächensprache) → `VoicePromptBuilder`: englischer Rahmen, Wunsch bei installiertem
   Sprachpaket per Translation-Framework ins Englische (sonst Original), optional Geschlecht, Alter, Herkunft.
2. `VoiceDesigner` lädt VoiceDesign, erzeugt **2 Vorschläge** (eigene Seeds) mit dem festen Lesetext der Lesesprache
   (`Resources/ReadAloud`) im Streaming-Pfad, prüft jeden (`ChunkQC`: NaN, Stille, Clipping, Dauer; zusätzlich 7–20 s),
   wiederholt bei Verdacht bis zu 3-mal mit neuem Seed, und **entlädt VoiceDesign** (auch bei Fehler/Abbruch).
3. Gewählter Vorschlag wird als Stimme gespeichert; Base klont sie danach beim Vorlesen (lädt erst dann).

## Package

- `Pipeline/VoiceDesigner.swift`: `actor VoiceDesigner(engine:translator:)`, `propose(_ wish: VoiceWish, referenceText:, count:, seedBase:, onProgress:) -> DesignResult`
  (`proposals: [DesignProposal]` mit samples, seed, attempts, QC-Bericht), `VoiceWish`, `VoiceGender`, `VoiceAgeHint`, `VoiceDesignError`.
  Begründung für `Pipeline` statt `Speech`: braucht `ChunkQC` (AudioOut) und `SpeechRate`; `Speech` bleibt Engine und Stimmen.
- `Pipeline/VoicePrompt.swift`: `VoicePromptBuilder.build/assemble`, `VoicePrompt` (text, source: english/translated/original/raw), Protokoll `DescriptionTranslating`.
- `Pipeline/SystemDescriptionTranslator.swift`: Translation-Framework, nur installierte Pakete.
- `Speech/DesignedVoices.swift`: `RecordedVoiceStore.saveDesigned(...)`, `isDesigned`, `designedList`. Gespeichert im Format der eigenen
  Stimmen (`own-<id>.caf/.txt/.json`, `kind: designed`, Zusatzfelder `wish`, `prompt`, `seed`) unter
  `~/Library/Application Support/Vorleser/Voices/`. `VoiceStore.designedVoices(for:)`; `recordedVoices(for:)` zeigt sie nicht mehr
  (eigene Reihe auf ②).
- `MLXQwenEngine.memoryReport()` (MLX aktiv/Zwischenspeicher/Spitze).

## CLI

```bash
vorleser-cli design-voice "ruhige, warme Stimme einer älteren Frau" --lang de --translate \
  [--wish-lang de] [--gender f|m] [--age young|middle|elderly] [--region "from Lisbon, Portugal"] [--raw] \
  [--count 2] [--seed N] [--out Ordner] [--prefix design] [--keep 1|2 --name "Oma" [--store-dir Ordner]] \
  [--read-text "Text"]
```
Schreibt `<prefix>-1.wav`, `-2.wav`; mit `--keep` wird gespeichert, mit `--read-text` danach mit Base vorgelesen
(`<prefix>-gelesen.wav`) und der Speicher je Schritt ausgegeben. Ohne `--store-dir` landet die Stimme in Application Support.

## App

Auf ② ersetzt `StyleSection` die Stilknöpfe: dieselben vier plus **„Eigener Wunsch …“**. Der Ablauf (`App/DescribeVoice`):
Wunsch (großes Textfeld, 4 Beispielknöpfe, „Sprechen statt tippen“ + Hinweis auf die Diktiertaste) → Warten (Balken, „Stimme 1 von 2 …“,
Abbrechen fragt nach) → zwei Karten „Vorschlag 1/2“ (Anhören, Diese nehmen; „Nochmal andere Vorschläge“) → Name → zurück zu ②
mit der neuen Stimme gewählt. Beschriebene Stimmen erscheinen auf ② unter „Meine beschriebenen Stimmen“ mit Probe; bei ihnen
entfallen die Stilknöpfe (Hinweistext), `style` ist nil. Alle Texte `describeVoice.*` (de, pt-PT). Eine gemeinsame Engine
(`SharedSpeechEngine`) für Vorlesen und Beschreiben, damit nie zwei Modelle zugleich geladen sind.
Bildschirmfotos (Vorschau-Dienst): `spike-output/phase4/app/`. Dienst-Attrappe nur bei `VORLESER_PREVIEW=1`.

Änderungen an bestehenden Dateien: `AppModel` (Screen `.describeVoice`, Property `describe`, `voiceName`/`styleKey` statt Direktzugriff),
`RootView` (1 Fall), `VoiceView` (`StyleSection`, `DesignedVoicesSection`), `LiveAudiobookService` (gemeinsame Engine),
`AppModel+OwnVoice` (`isOwnVoiceSelected` nur für Aufnahmen), `AppModel+Launch` (Demos), `RecordedVoices`/`VoiceStore` (Felder, Filter),
`vorleser-cli` (neuer Befehl, `readAloudText` nicht mehr privat), `Package.swift` (Linker-Flag CLI).

## Messwerte (Release-CLI, `design-voice`, 4-bit, Seed 2026)

Dateien: `spike-output/phase4/{de,pt}-e2e-*.wav`, Logs `*-e2e.log`. Der Mac wurde parallel von anderen Prozessen belastet
(Load 5–9); Zeiten sind obere Schätzungen.

| | de „ruhige, warme Stimme einer älteren Frau“ | pt-PT „voz calma e calorosa de uma senhora de Lisboa“ |
| --- | --- | --- |
| Anweisung (übersetzt) | Calm, warm voice of an older woman. A clear native German accent, … | Calm and warm voice of a lady from Lisbon. A clear native Portuguese accent, from Lisbon, Portugal, … |
| Vorschlag 1 / 2: Dauer | 12,9 / 16,8 s | 14,4 / 15,1 s |
| Zeit je Vorschlag | 6,2 / 9,5 s (RTF 0,48 / 0,56) | 6,5 / 10,2 s (RTF 0,45 / 0,68) |
| Versuche | 1 / 1 | 1 / 1 |
| Gesamt Design (inkl. Laden) | 17,9 s | 18,9 s |
| Spitze Footprint Design (MLX) | 3,44 GB (2,96 GB) | 3,22 GB (2,93 GB) |
| nach Entladen: geladenes Modell / MLX aktiv | keins / 0,00 GB | keins / 0,00 GB |
| Footprint nach Entladen | 0,14 GB nach 1 s (direkt danach 1,4 GB, Metal gibt verzögert frei) | 0,14 GB / 1,3 GB |
| Base: Laden, Footprint danach | 1,0 s, 2,51 GB (MLX aktiv 2,45 GB) | 0,7 s, 2,51 GB |
| Vorlesen mit der neuen Stimme | 9,8 s Audio, RTF 0,91, Spitze Footprint 5,63 GB (MLX 3,14 GB) | 12,0 s Audio, RTF 1,37 (Last), Spitze 5,92 GB |

**Beleg „nie zwei Modelle gleichzeitig“:** Das Programm gibt nach dem Entladen das geladene Modell aus (`keins`) und die MLX-Gewichte
aktiv mit 0,00 GB; erst dann wird Base geladen (MLX aktiv 2,45 GB = nur Base). Außerdem Test `designerUnloadsBaseBeforeLoadingDesign`
(Fake-Engine, `maxLoadedAtOnce == 1`). Die Footprint-Spitze beim Vorlesen (5,6–5,9 GB) entspricht Phase 1 (5,0 GB) plus kurzem Rest
des verzögert freigegebenen Metal-Speichers (nicht weiter untersucht).

Qualität (🎧, nicht objektiv prüfbar): die Dateien `de-e2e-1/2.wav`, `pt-e2e-1/2.wav` (Vorschläge) und `*-gelesen.wav`
(Briefsatz mit Vorschlag 1 bzw. 2) anhören: Klingt die Stimme „ruhig, warm, älter“? Bleibt sie im Brieftext dieselbe (Design → Klon)?
Gespeichert in `spike-output/phase4/voices/` (nicht Application Support).

## Tests

`swift test`: `VoiceDesignerTests` (Prompt-Bau, Übersetzung/Rückfall, 2 Vorschläge + Entladen, Base vor Design entladen, Wiederholung mit neuem
Seed bei NaN/Stille, kein Vorschlag → Fehler und entladen, Fehler, Abbruch), `DesignedVoiceTests` (Speichern/Laden in temporärem Ordner,
Trennung von Aufnahmen). App-Tests `DescribeVoiceTests` (Ablauf, Zurück, Abbrechen fragt, Fehlermeldungen, Übersetzer im App-Prozess).

## Offen / ehrlich

- Klang aller Proben ungehört; Wirkung „ruhig“ vs „fröhlich“ auf das Tempo ist schwach (S3).
- Diktat-Knopf sendet `startDictation:` (Systemdiktat) und wurde nicht mit echtem Diktat getestet; sonst Hinweis auf die Diktiertaste.
- Ohne installiertes Sprachpaket (z. B. Russisch) geht das Original in den englischen Rahmen; Wirkung nicht gemessen.
- Stabilität über 30 Abschnitte (S3) nicht gemessen. Beschriebene Stimmen lassen sich noch nicht im Helfer-Fenster löschen/umbenennen
  (Store kann es: `RecordedVoiceStore.delete/rename`).
- Wartebildschirm zeigt grobe Stufen, keinen echten Prozentwert; Vorschlag 2 kann ~10 s dauern. Während des Wartens bleibt Base entladen,
  das spätere Vorlesen lädt es neu (ca. 1 s).
- pt-PT/pt-BR: Wunsch „aus Lissabon“ wird nur im Rahmentext genutzt; die App setzt keinen Herkunftshinweis automatisch (Entscheidung PLAN §7 offen).
