# S3: Stimme beschreiben (Englisch oder Lesesprache, pt-PT oder pt-BR)

Stand: 16.10.2026 · M4, macOS 26.6, VoiceDesign 4-bit (Streaming-Pfad) · Dateien: `spike-output/phase4/s3-sprache/`, `spike-output/phase4/s3-pt/`
(Messungen liefen teils, während andere Prozesse den Mac auslasteten; Zeiten sind grob, Tonhöhen und Tempo davon unberührt.)

## Frage 1: Beschreibung auf Englisch oder in der Lesesprache?

Aufbau: 3 Wünsche (A ältere Frau, ruhig, langsam, Großmutter; B junge Frau, fröhlich, schnell; C älterer Mann, tief, ruhig)
je in Englisch und in der Lesesprache (de, pt), gleiche Seeds, je 2 Proben, rohe Anweisung (`design-voice --raw`).
Messung in Python (nur Spike): Zeichen/s (Lesetempo), Median-F0 (Autokorrelation, grob, Oktavfehler möglich).

| Sprache | Wunsch | Zeichen/s en / nativ | F0 Hz en / nativ |
| --- | --- | --- | --- |
| de | A ruhig, ältere Frau | 11,8 / 11,4 | 180 / 178 |
| de | B fröhlich, jung | 12,6 / 11,5 | 280 / 304 |
| de | C Mann, tief | 12,6 / 14,1 | **134 / 211** |
| pt | A | 11,2 / 13,3 | 187 / 194 |
| pt | B | 14,8 / 13,7 | 290 / 222 |
| pt | C | 10,0 / 11,6 | **108 / 168** |

Objektiv:
- Beide Varianten setzen die grobe Richtung um: junge Stimme höher als alte (de +113 Hz, pt +65 Hz über beide Varianten), „schnell/fröhlich“ im Schnitt schneller als „langsam/ruhig“ (de 12,0 vs 11,6; pt 14,2 vs 12,2 Zeichen/s), aber **das Tempo-Signal ist schwach** (Streuung zwischen Seeds so groß wie der Effekt, n = 2).
- Beim „tiefen Mann“ liegt die **englische** Anweisung klar tiefer (108/134 Hz) als die in der Lesesprache (168/211 Hz, also eher Frauenlage). Englisch folgt dem Geschlecht verlässlicher.
- Fazit: Englisch ist mindestens gleich gut, bei Geschlecht besser; kein Beleg, dass die Lesesprache etwas gewinnt. Stichprobe klein (24 Proben).

**Entscheidung:** Anweisung auf Englisch (fester englischer Rahmen im Stil von `presets.json`), der Wunsch wird mit dem Translation-Framework **on-device** ins Englische gebracht, aber nur, wenn das Sprachpaket schon installiert ist (`LanguageAvailability.status == .installed`; installiert hier: de, pt, es, fr, it, zh, ja, ko; Russisch nur „supported“). Sonst bleibt das Original im englischen Rahmen (`VoicePrompt.source == .original`); ob das schlechter ist, ist nicht gemessen. Beispiel: „ruhige, warme Stimme einer älteren Frau“ → „Calm, warm voice of an older woman.“

Stolperstein: Das Translation-Framework meldet bei Programmen, die gegen SDK 26.0 gelinkt sind (SwiftPM-Standard), installierte Pakete als „supported“ und übersetzt nicht. Die App (xcodebuild, SDK 27) ist nicht betroffen (App-Test `testSystemTranslatorWorksInAppProcess` grün). Für `vorleser-cli` setzt `Package.swift` deshalb `-platform_version macos 26.0 27.0` beim Linken.

## Frage 2: pt-PT oder pt-BR per Beschreibung

`design-voice "voz calma e calorosa de uma senhora" --lang pt --gender f --age elderly --region "from Lisbon, Portugal, European Portuguese"` bzw. `"from São Paulo, Brazil, Brazilian Portuguese"`, Seed 7, je 2 Proben.

| Probe | Dauer | Zeichen/s | F0 Hz | RMS dBFS |
| --- | --- | --- | --- | --- |
| lisboa-1 / -2 | 15,8 / 19,1 s | 11,4 / 9,4 | 140 / 190 | −19,6 / −20,9 |
| saopaulo-1 / -2 | 16,2 / 16,4 s | 11,1 / 11,0 | 171 / 186 | −24,0 / −20,3 |

Objektiv unterscheiden sich die Gruppen nicht klar (Lissabon eher langsamer/mit mehr Pausen; F0 gleich). Die Variante hört man, nicht messen. **Das ist ein reiner Hörtest.**

### 🎧 Hörfragen (bitte anhören)

Ordner `spike-output/phase4/s3-pt/`:
1. `lisboa-1.wav`, `lisboa-2.wav`: Klingt das europäisch-portugiesisch (geschlossene Vokale, „r“, Betonung)? Oder brasilianisch?
2. `saopaulo-1.wav`, `saopaulo-2.wav`: Klingt das brasilianisch? Merkbar anders als Lissabon?
3. Welche Variante soll die Oberfläche (pt-PT oder pt-BR) für portugiesische Stimmen nehmen? (Die Referenz `pt-teresa-calm` ist laut Phase 1 brasilianisch.)

Ordner `spike-output/phase4/s3-sprache/` (`<de|pt>-<A|B|C>-<en|nat>-<1|2>.wav`):
4. Stimmen B (jung, fröhlich) gegenüber A (alt, ruhig): Stimmt der Eindruck? Englisch und Lesesprache gleich gut?
5. Stimme C (Mann): Ist `*-C-nat-*` wirklich weniger männlich als `*-C-en-*`?

## Stabilität über 30 Abschnitte

**Offen.** Nicht gemessen (keine Zeit). Zu prüfen: eine beschriebene Stimme (Referenz 13–17 s) liest 30 Abschnitte à 300 Zeichen; Klangbild über die Abschnitte (F0-Drift, Tempo), Anteil Wiederholungen.

## Weitere Beobachtungen

- Referenzen für ruhige Stimmen sind **länger als der Plan annahm**: der feste Lesetext (ca. 180 Zeichen) dauert 12–19 s (11–12 Zeichen/s statt 15,8 der Presets). Der Designer akzeptiert 7–20 s; Plan sagt 10–15 s (länger = nur mehr Latenz beim Vorbereiten).
- Erste Läufe zeigten 1–3 Versuche pro Vorschlag (alte Grenze 16 s); mit 20 s fast immer sofort brauchbar.
