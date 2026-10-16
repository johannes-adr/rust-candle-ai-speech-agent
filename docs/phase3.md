# Phase 3: Eigene Stimme

Stand: 16.10.2026 · Gerät: M4, 24 GB, macOS 26.6, Xcode 27 (Swift 6.4).

Die Oma nimmt einen festen Lesetext auf (ca. 12 s); daraus wird eine Stimme, mit der Base
(ICL-Klonen, Transkript = Lesetext) jedes Dokument vorliest. Der Helfer kann im Einstellungsfenster
eine vorhandene Aufnahme als Stimme hinzufügen. Alles bleibt lokal.

## Aufbau

```
Packages/VorleserCore/Sources/
  VoiceCapture/                 NEU, ohne MLX und ohne VorleserSpeech
    AudioRecorder.swift         AudioRecording (Protokoll), MicrophoneRecorder (AVAudioEngine), MicrophonePermission
    LevelMeter.swift            LevelReading (RMS/Spitze in dBFS), LevelMeter
    RecordingAnalyzer.swift     Prüfung, Trimmen, Pegel angleichen; RecordingIssue (mit Hinweis-Schlüssel)
    TranscriptScoring.swift     normalisieren, WER/CER; ReadingChecker (Lese-Check)
    SystemTranscriber.swift     SpeechTranscriber (macOS 26) bzw. SFSpeechRecognizer, kein ungefragter Download
    VoiceImporter.swift         ReferenceTrimmer (10–15 s aus der Mitte) und Import mit Transkript
    AudioFiles.swift            beliebige Audiodatei → Mono-Float, WAV schreiben
  Speech/ (Modul VorleserSpeech)
    RecordedVoices.swift        RecordedVoiceStore: speichern (nur mit Zustimmung), laden, umbenennen, löschen
    VoiceStore.swift            lädt zusätzlich eigene Stimmen (`customDirectory`), `voice(id:)` kennt `own-…`
  vorleser-cli/VoiceCommands.swift   import-voice, delete-voice
App/OwnVoice/                   alles Neue der App
  OwnVoiceFlow.swift            @Observable: Schritte, Countdown, Aufnahme, Prüfung, Speichern
  OwnVoiceView.swift            Bildschirme (Lesetext, 3-2-1, Pegel, Anhören, Zustimmung+Name, Mikrofon verweigert)
  OwnVoiceCards.swift           Karten aufgenommener Stimmen in ②, ehrlicher Hinweis, Stil-Knöpfe ausblenden
  OwnVoiceSettings.swift        Helfer: Liste, Löschen mit Nachfrage, Import aus Datei
  AppModel+OwnVoice.swift       Navigation
```

### Warum ein eigenes Modul `VoiceCapture`?

- Das Package-Target `Speech` hieß wie Apples **Speech-Framework** (`SpeechAnalyzer`, `SFSpeechRecognizer`).
  `import Speech` fand je nach Bauzustand (liegt `Speech.swiftmodule` schon im Produktordner?) das
  eine oder das andere Modul („unable to resolve module dependency: Cmlx“). **Deshalb heißt das Target
  jetzt `VorleserSpeech`** (Ordner `Sources/Speech` unverändert). Alle `import Speech` wurden angepasst;
  neuer Code muss `import VorleserSpeech` schreiben. Apples Framework heißt wieder einfach `Speech`.
- `VoiceCapture` braucht kein MLX: schneller zu bauen und zu testen, und die Modelltests (kein
  `default.metallib` unter `swift test`) bleiben außen vor.
- Gespeichert wird in `Speech` (`RecordedVoiceStore`), weil dort `Voice`, `VoiceKind.recorded` und
  `ReferenceFiles.writeALAC` liegen.

## Aufnahme und Prüfung

`RecordingAnalyzer.analyze(samples:sampleRate:)` liefert die bereinigte Aufnahme und einen Bericht:

| Prüfung | Schwelle (`RecordingCheckConfig`) | Hinweis (Schlüssel) |
| --- | --- | --- |
| Stille | nichts oder Sprechpegel < −60 dBFS | `ownVoice.hint.silent` (blockiert) |
| zu kurz | < 8 s nach dem Trimmen | `ownVoice.hint.tooShort` (blockiert) |
| zu lang | > 18 s | `ownVoice.hint.tooLong` |
| zu leise | Sprechpegel (90. Perzentil der 50-ms-RMS) < −38 dBFS | „Bitte etwas näher ans Mikrofon“ |
| zu laut / übersteuert | Pegel > −9 dBFS, oder Anteil Samples am Anschlag > 0,1 % | „Bitte etwas leiser sprechen“ |
| Grundrauschen | Rauschen (Mittel der leisesten 10 % der Blöcke = Pausen) > −45 dBFS, oder Abstand Sprache zu Rauschen < 20 dB | „Es ist zu laut im Raum“ |
| NaN/Inf | irgendein Wert | `ownVoice.hint.failed` (blockiert), wird auf 0 gesetzt |

- Stille an Anfang und Ende wird mit `AudioOut.ChunkQC.analyze` abgeschnitten; die Schwelle folgt dem
  geschätzten Rauschen (−55 … −30 dBFS), 0,15 s Rand bleiben.
- Danach wird die Spitze auf −3 dBFS angeglichen (höchstens ±12 dB; Übersteuertes wird nicht angehoben).
- Blockierende Hinweise: „So behalten“ entfällt. Alle anderen sind Hinweise; „Trotzdem behalten“ geht.
- Die Schwellen sind aus synthetischen Signalen und Erfahrungswerten abgeleitet, **nicht an echten
  Mikrofonaufnahmen kalibriert**. Das braucht den Test mit der echten Oma/dem echten Mikrofon (Phase 5).

Pegelanzeige: `MicrophoneRecorder.start()` liefert einen `AsyncStream<LevelReading>` (ca. 16 Werte/s,
neuester gewinnt). `meterFraction` bildet −60 … 0 dBFS auf 0 … 1 ab; zusätzlich sagt ein Satz („Gut so.“,
„Ich höre Sie noch kaum …“, „Das ist sehr laut …“), damit es auch ohne Farbe verständlich ist.
Die Aufnahme nimmt in der Rate des Eingabegeräts auf (Mono-Mischung) und begrenzt auf 60 s, die App
stoppt nach 25 s selbst.

## Spracherkennungs-Check

`ReadingChecker.check` erkennt die (bereinigte) Aufnahme und vergleicht mit dem festen Lesetext:

- **Fehlerrate**: Wörter (WER) bzw. bei zh/ja/ko Zeichen (CER); Editierabstand ÷ Länge des Lesetexts.
  Normalisiert wird auf Kleinbuchstaben, ohne Satzzeichen/Symbole, bei Alphabetsprachen auch ohne Akzente.
- **> 30 %** → „Bitte nochmal, der Text war schwer zu verstehen“ (Hinweis, „Trotzdem behalten“ geht).
- **Transkript für das Klonen ist immer der feste Lesetext** (Test: `testHappyPathRecordReviewConsentSave`).

`SystemTranscriber` (on-device, ohne Netz):

1. `SpeechTranscriber`, wenn für die Sprache ein Gebietsschema **installiert** ist
   (`SpeechTranscriber.installedLocales`). Bevorzugte Region je Sprache: de-DE, pt-PT, en-US, es-ES, fr-FR,
   it-IT, ru-RU, zh-CN, ja-JP, ko-KR.
2. Sonst `SFSpeechRecognizer` mit `requiresOnDeviceRecognition`, wenn die Sprache unterstützt ist und die
   Nutzerin es erlaubt hat (Systemdialog erst beim ersten Bedarf, `NSSpeechRecognitionUsageDescription`
   steht in der Info.plist).
3. Sonst `.unchecked`: es bleibt bei Dauer und Pegel; die Nutzerin merkt davon nichts.

**Kein ungefragter Download**: ist ein Gebietsschema nur „unterstützt, nicht installiert“, kommt
`assetsNotInstalled`. Installieren ist eine eigene Aktion für den Helfer:
`vorleser-cli import-voice … --install-speech-assets` (`SystemTranscriber.installAssets(for:)`,
`AssetInventory`). Die App löst keinen Download aus.

## Speichern

`RecordedVoiceStore` (Standard `~/Library/Application Support/Vorleser/Voices/`, überschreibbar mit
`VORLESER_CUSTOM_VOICES_DIR`; in Debug-Builds der App mit `VORLESER_DATA_DIR` → `…/Voices`). Je Stimme:

```
own-1a2b3c4d.caf    ALAC, mono, Rate des Aufnahmegeräts
own-1a2b3c4d.txt    Wortlaut (bei Aufnahme der feste Lesetext)
own-1a2b3c4d.json   id, name, language, kind: recorded, createdAt, consent: true, consentAt,
                    source: recording|import, durationSeconds, transcriptSource: reading|provided|recognized
```

- `save(…, consent:)` wirft ohne `consent == true` `consentMissing` und schreibt nichts. `list()` ignoriert
  Einträge mit `consent != true`. Die JSON-Datei wird zuletzt geschrieben, erst damit gilt die Stimme als da.
- `VoiceStore(directory:customDirectory:)` löst `own-…`-IDs auf (`voice(id:style:fallback:)`, der Stil
  spielt keine Rolle). `locateDefault` und die CLI setzen den Standardordner.
- `MLXQwenEngine.prepare` bringt die Referenz wie immer auf die vom Modell gemeldete Rate. Die Obergrenze
  der Referenz ist von 15 auf **20 s** gestiegen, damit eine etwas langsam gelesene Aufnahme nicht mitten im
  Text abgeschnitten wird (Text und Audio müssen zusammenpassen).
- **Löschen** gibt es nur im Helfer-Fenster, mit Nachfrage („…endgültig löschen?“). Ist die gelöschte Stimme
  gerade in ② gewählt, springt die Auswahl auf eine fertige Stimme zurück.

## Audio-Import (Helfer)

`VoiceImporter.prepare(fileURL:language:providedText:)`:

1. Lesen (wav, m4a, mp3, caf, aif, flac …), Mono, Ränder trimmen.
2. **10–15 s aus der Mitte**, Schnitt an Pausen (`ReferenceTrimmer`: Pausen ≥ 0,25 s, Fenster nahe der Mitte
   und nahe 12,5 s); ohne Pausen 12 s um die Mitte mit Rändern an der leisesten Stelle. Dateien bis 15 s
   bleiben ganz.
3. Pegel- und Rauschprüfung wie bei der Aufnahme; Stille/zu kurz bricht ab.
4. Transkript des **Ausschnitts** per `SystemTranscriber`, oder vom Helfer angegeben (`--text`; dann nur
   für Dateien bis 15 s, weil Text und Ausschnitt sonst nicht zusammenpassen).

**x-vector-only-Modus**: `mlx-audio-swift` v0.1.5 bietet ihn öffentlich **nicht** an
(`prepareReferenceConditioning(refAudio:refText:language:)` verlangt immer `refText`; der Sprecher-Vektor wird
intern zusätzlich berechnet). Darum gibt es **keinen Import ohne Transkript**: Erkennung oder `--text`,
sonst Fehlermeldung mit dem Weg dorthin. Ein Eintrag in PLAN §7 („offen“) wäre nur nötig, wenn der Nutzer
das ohne Text will; dann müsste man Vocello vendoren oder `Qwen3TTS` patchen.

```bash
vorleser-cli import-voice aufnahme.m4a --lang de --name "Oma" --consent [--text "Wortlaut"] \
    [--custom-dir <Ordner>] [--install-speech-assets]
vorleser-cli voices                      # listet auch die eigenen Stimmen
vorleser-cli read brief.pdf --voice own-1a2b3c4d
vorleser-cli delete-voice own-1a2b3c4d
vorleser-cli check-reading ausgabe.mp3 --lang de --text "…"   # Pegel, NaN, Rück-Erkennung, WER/CER
```

## Ablauf in der App (PLAN §3)

Nach „Meine eigene Stimme“ in ②:

1. **Lesetext** (aus `Resources/ReadAloud/<sprache>.txt`, 32 pt) und der rote Knopf „Aufnehmen“.
   Ist das Mikrofon verweigert: freundlicher Bildschirm, der den Weg beschreibt („Einstellungen öffnen →
   Datenschutz und Sicherheit → Mikrofon → Vorleser“), mit „Einstellungen öffnen“ und „Nochmal versuchen“.
2. **3 – 2 – 1** (große Zahl, `OwnVoiceFlow.runCountdownAndRecord`), dann **Pegelanzeige** und „Fertig“.
3. **Prüfung** („Einen Moment bitte“), dann **Anhören** und **„So behalten“ / „Nochmal“**. Bei Problemen
   stehen die Hinweise da; „Trotzdem behalten“ statt „So behalten“; bei Stille/zu kurz nur „Nochmal“.
4. **Zustimmung** („Das ist meine Stimme, oder ich habe die Erlaubnis.“, Pflicht: „Speichern“ bleibt aus)
   und **Name** (Vorgabe „Meine Stimme“).
5. Zurück zu ② mit der neuen Stimme **ausgewählt**. Aufgenommene Stimmen erscheinen als Karten in einer
   zweiten Reihe (Name, „Ihre eigene Stimme“, „Probe“). Die Stil-Knöpfe sind dann ausgeblendet, stattdessen:
   „Ihre Stimme klingt so, wie Sie sie aufgenommen haben …“; das Tempo bleibt.

Auf jedem Bildschirm gibt es „Zurück“ (Aufnahme verwerfen, Zustimmung zurücknehmen, am Ende zu ②).

## Tests

- `VoiceCaptureTests` (21): Pegelmesser, Aufnahme sauber / zu leise / übersteuert / zu laut / Rauschen /
  zu kurz / Stille / zu lang / NaN, WER/CER (Wörter, Akzente, CJK), Lese-Check (ok / Abweichung / Grenze 30 % /
  nicht verfügbar), Regionenwahl, Zuschneiden an Pausen, Import (mit Text, erkannt, ohne Erkennung, Stille).
  Alle mit synthetischen Signalen.
- `SpeechTests/RecordedVoiceTests` (6): Zustimmung Pflicht (nichts auf der Platte), Hin und Zurück (ALAC lesbar,
  Metadaten, umbenennen, löschen), leere Eingaben, Standardname, Eintrag ohne Zustimmung wird ignoriert,
  `VoiceStore` löst eigene Stimmen auf.
- `App-Tests/OwnVoiceTests`: Ablauf mit Aufnahme-Attrappe (Happy Path inkl. „Transkript = Lesetext“, Zustimmung,
  Stille, zu leise, Abweichung, Mikrofon verweigert, Zurück überall, 3-2-1), Bibliothek/Auswahl/Löschen,
  Navigation, Kontrast des roten Knopfs (≥ 7:1), alle Schlüssel im Katalog.

## Nicht testbar / offen

- **Das Mikrofon selbst** (`MicrophoneRecorder`, Systemdialog, Pegelanzeige in Echtzeit, die echte
  Erlaubnis-Abfrage) ist nur von Hand prüfbar. Bitte einmal in der App durchspielen.
- Die Prüfschwellen sind nicht an echten Aufnahmen kalibriert.
- Ob `SpeechTranscriber` für de/pt/… auf dem Gerät **installiert** ist, hängt vom Mac ab (System-
  einstellungen › Tastatur › Diktierfunktion bzw. `--install-speech-assets`). Ohne Daten bleibt der Check bei
  Dauer/Pegel. Russisch lief zum Start von macOS 26 nur über `SFSpeechRecognizer` (Erlaubnis nötig).
- Eine eigene Stimme wird nur für ihre Aufnahmesprache angeboten (Karten je Sprache). Sprachübergreifendes
  Klonen geht in der Engine, hat aber Akzent (PLAN §2.1) und ist in der Oberfläche nicht vorgesehen.
- Hörprobe der geklonten Stimme: siehe unten (E2E).

## E2E-Messung (16.10.2026, Release-CLI, Base 4-bit)

„Aufnahme“ = die S1-Referenz `spike-output/S1/refs/ref-de.wav` (9,7 s, von VoiceDesign erzeugt, kein Mensch;
das Mikrofon ist damit nicht abgedeckt):

```bash
export VORLESER_CUSTOM_VOICES_DIR=$PWD/spike-output/phase3/voices
vorleser-cli import-voice spike-output/S1/refs/ref-de.wav --lang de --name "E2E Testlauf" --consent
vorleser-cli read - --voice own-20daf766 --lang de -o spike-output/phase3/e2e-eigene-stimme-de.mp3 --fresh < text.txt
vorleser-cli check-reading <mp3> --lang de --text "<Text>"     # Pegel, NaN, Rück-Erkennung, WER
```

| Schritt | Ergebnis |
| --- | --- |
| Import | SpeechTranscriber `de-DE` war installiert und erkannte den Text **ohne** `--text`: „Guten Tag, ich bin Ihre Vorleserin. Ich lese Ihnen heute gerne einen Brief oder eine Geschichte vor. Ganz in Ruhe.“ (gegen `ref-de.txt`: nur „gern/gerne“ und Satzzeichen anders). Referenz 9,2 s bei 24 kHz, Pegel −14,0 dBFS, Rauschen −74 dBFS, keine Hinweise |
| Vorlesen kurz | 1 Abschnitt (ca. 230 Zeichen), 13,7 s Audio, 0 Wiederholungen, 0 Verdachtsfälle, NaN/Inf: 0, RTF 2,06 |
| Vorlesen lang | 3 Abschnitte, 35,6 s Audio, 0 Wiederholungen, 0 Verdachtsfälle, NaN/Inf: 0, RTF Sprache 1,99, Spitzenspeicher 5,1 GB (am Ende 2,6 GB) |
| Rück-Erkennung (SpeechTranscriber) | kurz: **WER 2,5 %** („gern“ → „gerne“), lang: **WER 0,0 %** |

**RTF**: Die Zahlen sind **nicht vergleichbar** mit S1/Phase 1 (0,82–0,95): Während der Messung lief auf dem Mac
parallel viel anderes (Lastmittel 9–16; andere Agenten bauen und rechnen). Der Weg ist derselbe wie bei fertigen
Stimmen (`prepare` einmal, dann Abschnitte), die eigene Stimme macht ihn nicht langsamer. Bei ruhigem Mac
wiederholen, bevor jemand die Zahl zitiert.

Hörproben (Ordner `spike-output/phase3/`, von der Versionsverwaltung ignoriert): `00-referenz-ref-de.wav` (die
„Aufnahme“), `e2e-eigene-stimme-de.mp3`, `e2e-eigene-stimme-de-lang.mp3`. Frage: Klingt die MP3 nach derselben
Sprecherin wie die Referenz, und stört etwas (Tempo, Betonung, Rauschen)?
