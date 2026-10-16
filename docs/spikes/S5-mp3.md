# Spike S5 – MP3-Encoder und Audio-Ausgabe

**Frage (PLAN.md §5):** Baut `SwiftLAME` (mit Xcode 26)? Wenn nicht: LAME 3.100 als
eigenes C-Target. ID3v2 setzen, Datei in Musik/Finder prüfen.

**Ergebnis in einem Satz:** LAME 3.100 liegt als eigenes C-Target `CLAME` im Package;
`SwiftLAME` baut zwar, taugt aber nicht für unseren Ablauf. ffprobe bestätigt MPEG-1
Layer III, 64 kbit/s CBR, mono, 44 100 Hz, ID3v2 und korrekte Dauer.

## Umgebung (weicht vom Plan ab)

| | Plan | tatsächlich |
| --- | --- | --- |
| Xcode | 26 | **Xcode 16.3, Swift 6.1, SDK 15.4** |
| macOS-Ziel im Package | 26 | `.macOS(.v15)` |
| Prüfwerkzeuge | – | Homebrew `ffprobe`/`ffmpeg`, **nur in Tests**, nicht zur Laufzeit |

Die Frage „baut mit Xcode 26?“ konnte deshalb nicht wörtlich beantwortet werden.
Alles unten gilt für Xcode 16.3 / Swift 6.1 (Strict Concurrency, Swift-6-Sprachmodus).
Mit Xcode 26 ist nichts anderes zu erwarten, weil wir nur C und AVFoundation nutzen.
Bei der Umstellung einmal `swift test` laufen lassen.

## Aufbau

1. **SwiftLAME prüfen.** Revision `e8256a8151594f47f103c742f684253c6c44871d` (HEAD beim
   Spike; einziges Tag `0.1.0` = `45d1b021…`) in ein Wegwerf-Package mit
   Swift-Tools 6.0 und macOS 15 eingebunden und gebaut.
2. **LAME 3.100** von `downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz`
   geholt. SHA-256 `ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e`
   (stimmt mit der veröffentlichten Prüfsumme überein).
3. **Eigenes Target** `Sources/CLAME`: `libmp3lame/*.c|h` ohne `mpglib_interface.c`
   (kein Decoder), ohne x86-Intrinsics (`vector/lame_intrin.h` nur als Header, wird
   vom Quelltext eingebunden), `include/lame.h` als öffentlicher Header, `COPYING`,
   `LICENSE`, `README.lame` aus dem Original. Eine **handgeschriebene `config.h`** für
   macOS/arm64 (little endian, nur Encoder, `#undef DEBUG`).
4. **Swift-Seite** (`Sources/AudioOut`), siehe unten „Öffentliche API“.
5. **Tests** mit synthetischen Signalen, siehe unten.

## Ergebnisse

### SwiftLAME

- **Baut:** ja (7 s, ohne Fehler). Es ist aber ein Dateikonverter:
  `SwiftLameEncoder(sourceUrl:configuration:destinationUrl:)` liest eine Audiodatei
  und schreibt eine MP3. Das C-Target `LAME` ist **nicht** als Produkt exportiert.
- **Reicht nicht aus**, weil wir brauchen:
  - Streaming von `[Float]`-Blöcken (Speicher flach, kein Umweg über eine WAV-Datei),
  - ID3v2-Tags in UTF-16 (Titel mit Umlauten, Kyrillisch, CJK),
  - Zugriff auf den Info/Xing-Header (Dauer stimmt auch bei CBR),
  - unveränderte Kontrolle über `lame_set_*` (CBR, mono, 44,1 kHz, Qualität).
  Nichts davon ist in `SwiftLAME` erreichbar.
- **Zusätzliches Risiko:** Das C-Target setzt `unsafeFlags`. SwiftPM erlaubt das nur für
  Wurzel-Packages und Abhängigkeiten per fester Revision, nicht per Versionsbereich. Das
  hätte uns an einen einzelnen Commit eines kleinen Repos gebunden.
- Das Repo hat seit dem ersten Tag kaum Pflege; wir würden es ohnehin selbst
  besitzen wollen.

### LAME als eigenes C-Target

- **Baut** ohne Fehler (nur Warnungen aus altem C-Code, z. B. `-Wshift-negative-value`).
- Zwei Stolpersteine, beide in `config.h` gelöst und dort kommentiert:
  - `ieee754_float32_t` & Co. müssen als `typedef` bereitstehen.
  - SwiftPM definiert im Debug-Build `DEBUG`; dann druckt LAME Diagnose
    (`count1: real: …`) auf stdout. Mit `#undef DEBUG` ist das aus.
- `lame_encode_buffer_ieee_float` erwartet ±1,0 Vollaussteuerung (Header-Kommentar,
  durch den Test mit Dekodierung bestätigt).
- `lame_set_write_id3tag_automatic(0)`: Den ID3v2-Tag holt `MP3Writer` per
  `lame_get_id3v2_tag` und schreibt ihn zuerst; am Ende ersetzt er den von LAME
  reservierten leeren ersten Frame durch den **Info-Header** (`lame_get_lametag_frame`),
  genau wie das LAME-Frontend. Ohne diesen Schritt melden Player bei CBR-Dateien
  gelegentlich eine falsche Dauer.
- Tags gehen als UTF-16 mit Byte-Order-Mark (`id3tag_set_textinfo_utf16`,
  `id3tag_set_comment_utf16`), ID3v2 only (kein ID3v1-Block am Ende).
- Geschrieben wird in `<Name>.mp3.part` und erst bei `finalize()` umbenannt.

### ffprobe-Ausgabe (Beispieldatei, 3 Töne + Pausen, 2 Kapitel)

```
Input #0, mp3, from 'Vorleser Testton.mp3':
  Metadata:
    encoder         : LAME 64bits version 3.100 (http://lame.sf.net)
    title           : Vorleser Testton
    artist          : Testsprecherin
    album           : Vorleser Testton
    comment         : Mit KI vorgelesen
  Duration: 00:00:07.85, start: 0.025057, bitrate: 64 kb/s
  Stream #0:0: Audio: mp3 (mp3float), 44100 Hz, mono, fltp, 64 kb/s

codec_name=mp3                      format_name=mp3
sample_rate=44100                   duration=7.850000
channels=1  channel_layout=mono     bit_rate=64000
```

- Erwartete Dauer: 3 × 2,0 s + 0,35 s (Satz) + 1,5 s (Kapitel) = 7,85 s. **Treffer auf
  die Hundertstelsekunde**, also arbeitet der Info-Header.
- Das erste Datenpaket nach dem ID3-Tag beginnt bei Byte 273 mit `Info`.
- Kapiteldateien: `01 Erster Teil.mp3` (4,35 s, `track=1/2`), `02 Zweiter Teil.mp3`
  (2,00 s, `track=2/2`). Die Kapitelpause (1,5 s) steht nur in der Gesamtdatei.
- Gegenprobe mit `ffmpeg -af ebur128`: **−18,5 LUFS** integriert (Ziel −18; eigene Messung
  vor dem Kodieren −18,0), True-Peak −10,8 dBFS. Die 0,5 LU Abweichung kommen vom
  Kodieren mit 64 kbit/s und unterschiedlichem Gating bei so kurzen Tonsignalen;
  im Test mit sprachähnlichem Signal liegt die Abweichung unter 1 LU.

### Bausteine und Messungen (alle per Test belegt)

| Baustein | Prüfung | Ergebnis |
| --- | --- | --- |
| Lautheit (BS.1770-4, K-Gewichtung, Gate −70 LUFS / −10 LU) | 997 Hz, 0 dBFS, Vollaussteuerung bei 24/44,1/48 kHz | −3,01 LUFS (Toleranz 0,1) |
| | 997 Hz, −20 dBFS | −23,01 LUFS |
| | 50 Hz | leiser als 997 Hz (Hochpass wirkt) |
| | Ton + 20 s Stille + Ton | −23,0 ±0,25 (Gate ignoriert Stille) |
| Resampling | 1 kHz bei 16/22,05/24/48 kHz → 44,1 kHz | Frequenz ±2 Hz, Amplitude ±0,02, Länge exakt |
| | 15 kHz bei 44,1 → 24 kHz (oberhalb Nyquist) | Restpegel < −60 dBFS (bandbegrenzt) |
| Tempo | 0,8× / 1,1× / 1,2× auf 440-Hz-Sinus | Dauer ±2 %, Frequenz ±8 Hz, Tonhöhe bleibt |
| Pausen | Satz/Absatz/Kapitel | 0,35 / 0,8 / 1,5 s auf das Sample genau |
| Fades | 10 ms Halbkosinus | Anfang/Ende < 0,01, kein Sprung |
| Begrenzer | Sinus ×2,5 | Sample-Peak ≤ −1,5 dBFS, True-Peak (4× Überabtastung) ≤ −1,5 dBFS +1 % |
| ChunkQC | NaN/Inf, Clipping, Stille, Dauer 0,5×/2× | wie erwartet, Bericht ist `Codable` |
| CAF | Round-trip Float32, 24 kHz | bitgleich; `*.part.caf` zählt nicht als fertig |

Gesamt: `swift test` mit 40 Tests grün (3,4 s).

## Entscheidung

**LAME 3.100 als eigenes C-Target `CLAME`; kein SwiftLAME.**

Gründe: Streaming-API, UTF-16-Tags, Info-Header und volle Parameterkontrolle sind mit
SwiftLAME nicht erreichbar; wir kontrollieren Quelle, Version und Lizenzdateien selbst;
der Build hängt nicht von einem fremden Repo ab. Kosten: etwa 1 MB C-Quelltext im Repo
(bewusst ohne Decoder und ohne x86-Code) und eine handgepflegte `config.h`.

Keine Abhängigkeit von Homebrew: `lame` und `ffmpeg` werden nur in Tests genutzt und
dort übersprungen, wenn sie fehlen (nur die MP3-Prüfung per ffprobe/ffmpeg).

## Lizenzhinweis

LAME steht unter der **GNU LGPL 2** (`Sources/CLAME/COPYING`, `LICENSE`). Das Original
liegt unverändert bei; geändert ist nur die Auswahl der Dateien und die eigene
`config.h`. Für den privaten Gebrauch ist das unproblematisch. **Bei Weitergabe der App**
muss der Empfänger LAME austauschen können: LAME als dynamische Bibliothek bauen oder die
Objektdateien beilegen (siehe PLAN.md §4.5), und den Lizenztext in „Über Vorleser“ nennen.
Aktuell wird `CLAME` statisch eingebunden; das ist für den Eigengebrauch in Ordnung.

## Öffentliche API (Modul `AudioOut`)

- `ChunkQC.analyze(samples:sampleRate:characterCount:config:)` → bereinigte Samples + `ChunkQCReport`
  (`Codable`, `QCIssue`: `nonFinite`, `clipping`, `silent`, `tooShort`, `tooLong`, `empty`).
- `Resampler.resample(_:from:to:)`: `AVAudioConverter`, Qualität max, Mastering-Algorithmus.
- `TempoShifter.apply(_:sampleRate:tempo:)`: 0,8–1,2, `AVAudioUnitTimePitch` offline.
- `Loudness.integratedLUFS`, `LoudnessMeter` (streamend), `PeakLimiter.limit/truePeak`.
- `CAFFile.write/read`, `ChunkStore` (`chunks/0001.caf`, `existingIndices()` für Fortsetzen).
- `MP3Writer` (`append(_:)`, `finalize()`, `abort()`) mit `MP3Tags`, `MP3Settings`.
- `AudioExporter.export(chunks:to:options:progress:)` → `ExportResult`:
  zwei Durchgänge (messen, schreiben); Gesamtdatei plus optional Kapitelordner.

## Grenzen / offen

- **Hören kann ich nicht.** Ob Fades, Pausen und Tempo-Qualität gut klingen, ist
  ungeprüft (Beispiel-MP3 unten).
- Die Dauerplausibilität nutzt eine feste Sprechrate (14 Zeichen/s). Sie muss in S1/S2
  je Sprache und Stimme kalibriert werden; für CJK ist die Zeichenzahl umzurechnen.
- Tempo wird je Abschnitt gerendert; die Anlaufverzögerung des Time-Pitch-Geräts wird
  abgeschnitten, ein winziger Rest im Millisekundenbereich geht in den Fade.
- Der Begrenzer arbeitet je Abschnitt (Abschnitte sind an den Rändern ausgeblendet, daher
  keine Sprünge an den Nähten). Ein echter Mehrkanal-/Dauer-True-Peak-Limiter ist es nicht.
- Kodierter MP3-Überschwinger (~0,5–1 dB über dem Vor-Kodier-Peak) ist durch den Abstand
  −1,5 dBFS abgedeckt, aber nicht garantiert; im Test < −0,8 dBFS.
- Xcode 26 / macOS 26 nicht getestet (siehe Umgebung).

## Bitte an den Nutzer 🎧

Beispieldateien liegen unter `spike-output/S5/` (ignoriert, nicht im Repo):

- `Vorleser Testton.mp3` (7,85 s, drei Töne mit zwei Pausen)
- `Kapitel/01 Erster Teil.mp3`, `Kapitel/02 Zweiter Teil.mp3`

Bitte im **Finder** (Leertaste, dann „Informationen“ bzw. Cmd+I) und in der **Musik-App**
öffnen und prüfen:

1. Steht bei `Vorleser Testton.mp3` **Dauer 0:08** (7,85 s), Titel „Vorleser Testton“,
   Interpret „Testsprecherin“, Album „Vorleser Testton“, Kommentar „Mit KI vorgelesen“?
2. Zeigt die Musik-App bei den Kapitel-Dateien Titel „Erster Teil“/„Zweiter Teil“ und
   Titelnummer 1 von 2 bzw. 2 von 2?
3. Spielt alles ohne Knacken an den Nahtstellen (Töne 220 → 330 → 440 Hz)? Springt die
   Zeitleiste beim Verschieben an die richtige Stelle?

Wiederholen lässt es sich mit:
`VORLESER_SPIKE_OUT=<Ordner> swift test --filter SpikeSample` im Ordner `Packages/VorleserCore`.
