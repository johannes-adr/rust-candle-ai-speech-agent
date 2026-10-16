# Spike S2 – Sprachen, Normalisierung, Abschnittslänge

Status: **vorbereitet, noch nicht gemessen.** Die Testdaten und die Textpipeline
(`TextPrep`) stehen. Die Messung mit Sprachsynthese und Rückerkennung folgt,
sobald die Engine aus S1 läuft. Dieses Dokument enthält deshalb keine Messwerte
und keine Entscheidung; beides wird nach der Messung ergänzt.

## Fragen (aus PLAN.md §5)

1. Was liest das Modell **von selbst** richtig (Zahlen, Datum, Geld,
   Abkürzungen, Fremdwörter), und wo braucht es unsere Normalisierung?
2. Wie hoch ist die Fehlerrate bei **250 / 500 / 900 Zeichen** je Durchgang?
   (Bestätigt oder verschiebt das die Abschnittsgröße 200–500, CJK ca. 70–170?)
3. Hilft eine **niedrigere Temperatur** (oder anderes Sampling) bei langen
   Abschnitten?

Ergebnis speist: Normalisierungsregeln je Sprache, Abschnittsgröße, Sampling.

## Testdaten (liegt im Repo)

`docs/spikes/S2-saetze/`

| Datei | Inhalt |
|---|---|
| `<lang>.txt` | Satz-Set, gegliedert mit `# Kategorie`: Zahlen, Datum und Uhrzeit, Geld und Einheiten, Abkürzungen/Telefon, Fremdwörter/URLs. Ein Satz je Zeile. |
| `<lang>-laenge-250.txt`, `-500`, `-900` | Fließtext ohne Zahlen aus ganzen Sätzen, ungefähr so lang (tatsächliche Länge in Zeichen steht unten). |

Sprachen: de, pt, en, es, fr, it, ru, zh, ja, ko. Deutsch und Portugiesisch
haben je 4–5 Sätze pro Kategorie, die anderen acht 2–4.

Für **zh/ja/ko** gelten die Längen 85 / 170 / 300 Zeichen (ca. ⅓), Dateien
heißen `zh-laenge-85.txt` usw. Die Ziele sind Näherungen, weil nur an
Satzgrenzen geschnitten wird:

| Ziel | de | pt | en | es | fr | it | ru |
|---|---|---|---|---|---|---|---|
| 250 | 309 | 295 | 297 | 309 | 261 | 260 | 249 |
| 500 | 505 | 501 | 566 | 573 | 536 | 524 | 504 |
| 900 | 930 | 949 | 902 | 919 | 984 | 952 | 957 |

| Ziel (CJK) | zh | ja | ko |
|---|---|---|---|
| 85 | 85 | 88 | 81 |
| 170 | 172 | 194 | 180 |
| 300 | 303 | 313 | 314 |

Die Sätze sind von Hand geschrieben und **nicht von Muttersprachlern geprüft**.
Für die Messung reicht das; fällt ein Satz durch ungewöhnliche Formulierung
auf, vor dem Auswerten korrigieren.

## Aufbau der Messung

Voraussetzung: Engine aus S1 (Base-Modell mit Klon-Referenz, `generate` mit
Seed und Sampling-Parametern), Referenzstimme je Sprache aus `Resources/Voices`.

### Teil A – Wie viel liest das Modell selbst richtig?

Für jeden Satz der Kategorien-Sets, je Sprache:

- Lauf **A0** mit dem **Originaltext** (keine Normalisierung).
- Lauf **A1** mit `spokenText` aus `Normalizers.make(for:)`.
- Je 3 Seeds, Standard-Sampling.
- Rückerkennung (siehe unten), Vergleich mit der **erwarteten Aussprache**:
  - de/pt: `spokenText` (Golden-Files in `Tests/TextPrepTests/Golden`).
  - übrige Sprachen: `spokenText` des Basis-Normalizers (nur Zahlen, Prozent,
    Abkürzungen). Datum, Geld, Einheiten sind dort nicht ausgebaut; sie werden
    nur bewertet, nicht erwartet.
- Auswertung je Kategorie: Fehlerrate A0 gegen A1. **Regel erst ausbauen, wo
  A0 deutlich schlechter ist als A1.** Wo A0 gleich gut ist, bleibt die Regel
  aus (PLAN §4.3).

### Teil B – Abschnittslänge

- Je Sprache die drei Längenvarianten, je 3 Seeds, Standard-Sampling.
- Gemessen wird je Lauf:
  - WER (CER für zh/ja/ko) gegen den Eingabetext (ohne Zahlen, deshalb ohne
    Normalisierung vergleichbar),
  - Dauer des Audios gegen Erwartung (Zeichen je Sekunde der kurzen Variante
    als Maßstab); Abweichung > 25 % zählt als Auffälligkeit,
  - Wiederholungen oder Abbruch (Rückerkennung liefert deutlich mehr oder
    weniger Wörter),
  - NaN/Clipping, Stille am Ende, RTF, Spitzenspeicher.
- Ergebnis: Kurve Fehlerrate gegen Länge je Sprache. Daraus folgt, ob 500
  (CJK 170) als Obergrenze hält oder die Grenze sinken muss.

### Teil C – Sampling

- Auf der 900-Zeichen-Variante in de und pt (Rest nur, wenn dort ein Effekt
  zu sehen ist): Temperatur und gegebenenfalls Top-k/Top-p variieren. Die
  konkreten Parameter und Werte stehen erst fest, wenn die API aus S1 bekannt
  ist; hier **nichts festlegen**, was nicht gemessen ist.
- Je Einstellung 5 Seeds. Kennzahlen wie in Teil B, zusätzlich Streuung
  zwischen den Seeds (nützlich für die Wiederholungslogik).

### Rückerkennung

- macOS 26 `SpeechTranscriber` für alle Sprachen, die er kennt.
- **Russisch:** laut CLAUDE.md hatte `SpeechTranscriber` zum Start kein Russisch.
  Dann `SFSpeechRecognizer`, sonst nur Dauerprüfung (Teil A/B ohne WER).
- Vor dem Vergleich beide Seiten normalisieren: Kleinschreibung, Satzzeichen
  weg, Zahlen als Wörter (damit „1984“ und „neunzehnhundertvierundachtzig“
  nicht als Fehler zählen, wenn der Erkenner Ziffern liefert).
- Wichtig: Der Erkenner macht eigene Fehler. Gemessen wird deshalb immer **A1
  gegen A0 und Längen gegeneinander**, nicht eine absolute Güte. Bei
  auffälligen Fällen eine Probe anhören lassen.

## Ablage der Ergebnisse

- Rohdaten (JSON je Lauf: Sprache, Satz-ID, Variante, Seed, Sampling, Dauer,
  RTF, Speicher, Erkennungstext, WER/CER): `spike-output/S2/results.json`
  (ignoriert, nicht eingecheckt).
- Audio: `spike-output/S2/<lang>/<satz-id>-<variante>-s<seed>.wav`.
- Tabellen und Fazit: dieses Dokument, Abschnitt „Ergebnisse“ unten.

## 🎧 Hörprobe (durch den Nutzer, nach der Messung)

Das kann ich nicht beurteilen, deshalb eine kleine Auswahl:

- je Sprache der 900-Zeichen-Text, Seed mit der **schlechtesten** und der
  **besten** Rückerkennung (zeigt, ob WER mit dem Höreindruck übereinstimmt),
- de/pt: je ein Datum-, Geld- und Telefonsatz mit und ohne Normalisierung,
- Frage: „Klingt die Aussprache der Zahlen natürlich, und wo bricht die
  Stimme bei langen Texten ein?“

## Was `TextPrep` dafür bereits liefert

- `LanguageDetector` (Sprache + Sicherheit),
- `Normalizers.make(for:options:)` mit Golden-Files je Sprache,
  pt-PT als Standard, `PortugueseVariant.brazil` umschaltbar (die Entscheidung
  PT vs. BR ist offen und kann in S2 anhand der Hörprobe getroffen werden),
- `ChunkPlanner` mit Zielbereich je Sprache (`ChunkPlanner.lengthRange`),
  der in Teil B getestete Wert.

## Bekannte Grenzen der Normalisierung (vor der Messung)

Das sind Lücken im Code, keine Messergebnisse:

- Außerhalb von de/pt gibt es kein Datum, keine Uhrzeit, kein Geld, keine
  Einheiten; Währungssymbole bleiben dort stehen.
- Russische Zahlwörter stehen im Nominativ („в одна тысяча … году“ ist
  grammatisch falsch); Kasus und Geschlecht fehlen.
- Deutsche Ordnungszahlen außerhalb von Datumsangaben bekommen immer die
  Endung „-te“ („der zweite Platz“), unabhängig vom Fall.
- Jahreszahlen werden in de/en für 1100–1999 als Jahr gelesen, auch wenn es
  eine Menge ist („1200 Besucher“ → „zwölfhundert“, im Deutschen gebräuchlich).
- Bloße Domains ohne `www.` oder `http` werden nicht als Adresse erkannt.

## Ergebnisse

_Noch nicht gemessen._

| Teil | Status |
|---|---|
| A – Selbst richtig gelesen | offen |
| B – Abschnittslänge | offen |
| C – Sampling | offen |

Entscheidung und Anpassung von PLAN.md folgen nach der Messung.
