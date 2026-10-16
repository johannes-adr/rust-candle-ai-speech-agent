# Spike S4 – PDFs und andere Dokumente einlesen

Stand: erster Durchgang mit **synthetischen** Test-PDFs. Echte PDFs vom Nutzer fehlen noch;
die Schwellen unten sind deshalb vorläufig und müssen mit ihnen bestätigt werden (siehe
„Bitte an den Nutzer“).

## Frage

Wie gut liefern PDFKit und Vision aus Briefen, Zeitungen, Büchern, Scans und Handy-Fotos
sauberen Lesetext (PLAN.md §2.4, §4.3 Schritt 1 und 3)? Welche Bereinigungsregeln und
OCR-Schwellen brauchen wir?

## Aufbau

- **Modul** `Packages/VorleserCore/Sources/DocumentImport`
  - `DocumentImporter` – `importDocument(at:)`, `importText(_:)`, `importDetailed(at:languageHint:)`
    (mit Messdaten: Seitenzahl, OCR-Seiten, Sprache, Bereinigungsbericht).
  - `PDFLineExtractor` – PDFKit: `selectionsByLine()` mit Position, Schriftgröße, Fettdruck.
  - `OCR` – Vision `VNRecognizeTextRequest` (accurate, Sprachkorrektur).
  - `PDFCleaner` – arbeitet nur auf dem **reinen Zeilenmodell** (`PageLine`: Text, Rect,
    Schriftgröße, Fett, Seite). Dadurch ohne PDF testbar.
  - `TextDocumentShim.swift` – **vorläufige** `TextDocument`/`TextBlock`; wird beim Zusammenführen
    mit TextPrep gelöscht (und `DocumentImport` hängt dann wieder von `TextPrep` ab).
- **Importwege:** PDF (PDFKit, Seiten ohne Text per OCR), .docx/.odt/.rtf/.rtfd/.doc/.html über
  `NSAttributedString`, .txt mit Kodierungserkennung (UTF-8, UTF-16 mit/ohne BOM, Windows-1252,
  ISO-Latin-1), Bilddateien (.jpg/.png/.heic/.tif) per OCR.
- **Testdaten:** `scripts/s4-fixtures/make-fixtures.swift` erzeugt die Fixtures (CoreText,
  erfundene Texte, nur Testdaten-Generator) nach `Tests/DocumentImportTests/Fixtures/`
  (zusammen ca. 430 KB, weil Schriften eingebettet sind und die zwei Bilddokumente JPEG enthalten).
- **Auswertung:** `swift run spike-s4 <ordner>` (siehe unten).

### Vision: `RecognizeDocumentsRequest` ist Hauptweg

Zuerst lief der Spike mit Xcode 16.3 / SDK 15.4, wo `RecognizeDocumentsRequest` (macOS 26) nicht
verfügbar war; dort war `VNRecognizeTextRequest` der einzige Weg. Mit Xcode 27.0 (Swift 6.4, SDK 27) und
Deployment-Target `.macOS(.v26)` (swift-tools-version 6.2) ist `RecognizeDocumentsRequest` jetzt
**Hauptweg** (`document.paragraphs` → Zeilen mit Absatz-Kennung, die die Bereinigung übernimmt).
`VNRecognizeTextRequest` bleibt Fallback (Fehler oder leeres Ergebnis) und per `spike-s4 --ocr-alt`
für Vergleiche abrufbar. Schiefstand-Korrektur und Seitenränder-Bereinigung laufen für beide Wege gleich.

Vergleich auf den OCR-Fixtures (Debug-Build, Zeit je Seite inkl. Rendern):

| Fixture | alt (`VNRecognizeTextRequest` + eigene Absatzregeln) | neu (`RecognizeDocumentsRequest`) |
| --- | --- | --- |
| `scan.pdf` | 4 Absätze + Titel, richtig; 0,5 s | 4 Absätze + Titel, richtig; 0,5 s (am Ende ein verirrtes „(“) |
| `foto.jpg` (2,5° schief) | 3 Absätze: zwei verschmolzen; 0,7 s | **4 Absätze, richtig**; 0,6 s; ein Lesefehler („Herm“ statt „Herrn“) |

Fazit: gleiche Geschwindigkeit, Absätze beim schiefen Foto deutlich besser (bisher die größte Lücke),
Texttreue vergleichbar (je ein kleiner Fehler pro Verfahren möglich). Mit echten Handy-Fotos prüfen.

## Was aus den Messungen gelernt wurde (Bauch-Entscheidungen, die sich als falsch erwiesen)

1. **PDFKit-Zeilen laufen über Spalten.** `selectionsByLine()` fasst Text auf einer Grundlinie zu
   einer Zeile zusammen, auch quer über beide Zeitungsspalten und über Tabellenzellen. Spaltenerkennung
   „über die x-Position der Zeilen“ reicht daher nicht. Lösung: Jede Zeile wird anhand der Wortabstände
   in **Stücke** geteilt (Lücke > max(5 pt, 0,8 × Zeichenhöhe)); die Bereinigung erkennt die Gasse
   und setzt Stücke derselben Zeile wieder zusammen, wenn es keine Gasse gibt.
2. **`PDFPage.characterBounds(at:)` ist unbrauchbar**: Die Indizes passen nicht zu `page.string`
   (die Boxen waren ab der zweiten Zeile verschoben). Stattdessen werden Wörter über
   `page.selection(for: NSRange).bounds(for:)` vermessen.
3. Beim Spaltenwechsel steht manchmal **kein Leerzeichen** zwischen Zeilenende links und Zeilenanfang
   rechts („Mehr-Bürgermeisterin“). Solche Wörter (Breite pro Zeichen unplausibel groß) werden
   zeichenweise geteilt.
4. **Vision-Rechtecke sind bei schiefen Fotos zu hoch** (achsenparallel). Höhe, Breite und Winkel
   kommen deshalb aus den gedrehten Textecken (`boundingBox(for:)`); der Seiten-Schiefstand
   (Median der Zeilenwinkel) wird herausgerechnet. Ohne das wurden Zeilen eines 2,5° schiefen Fotos
   in falsche Absätze zerrissen und Überschriften nicht erkannt.
5. OCR-Zeilenhöhen schwanken je nach Buchstaben (ohne Unterlängen kleiner). Deshalb für OCR:
   Abstände nur mit Zeilenmitte messen, großzügigere Größentoleranz, höherer Überschriften-Schwellwert.
6. Die Kombination PDFKit + stderr: PDFKit schreibt je Zeile „attributedStringScaled …“ nach stderr.
   Harmlos, aber laut; in der App unsichtbar, im CLI-Spike störend (mit `2>/dev/null` ausblenden).

## Gewählte Schwellen (`CleanerOptions`)

| Regel | Wert | Begründung |
| --- | --- | --- |
| Randband für Kopf-/Fußzeilen | oberste/unterste 10 % der Seitenhöhe | Briefköpfe/Fußzeilen liegen bei 3–6 % |
| Wiederkehr | auf ≥ **40 %** der Seiten (mind. 2), Ziffern/Satzzeichen ignoriert | PLAN sagte 50 %. Bei Büchern wechseln Kolumnentitel links/rechts; bei ungerader Seitenzahl hätte der seltenere unter 50 % gelegen. |
| Einzelne Seitenzahl | am Rand immer entfernt (auch bei 1 Seite): „12“, „- 12 -“, „Seite 3 von 10“, „Página 4 de 9“, römische Zahlen | |
| Überschrift (PDF) | Schrift ≥ 1,15 × Fließtext, ≤ 100 Zeichen, kein `.,;:` am Ende; oder ganze Zeile fett, ≤ 90 Zeichen (nicht wenn das ganze Dokument fett ist) | |
| Überschrift (OCR) | Höhe ≥ 1,2 × Fließtext **und** ≤ 60 Zeichen | OCR-Höhen schwanken ±15–25 %; ohne die Längengrenze wurden 90-Zeichen-Zeilen zu „Überschriften“ |
| Ebene | Rang der Schriftgrößen (größte = 1, max. 3); nur fett = 3 | |
| Fußnote | Schrift < 0,88 × Fließtext und unteres Seitendrittel (35 %) | |
| Fußnotenziffer | hochgestellte Ziffern im Text (kleine Schrift) und `Wort.1` am Satzzeichen | |
| Bildunterschrift | Absatz < 400 Zeichen, beginnt mit Abbildung/Abb./Bild/Foto/Tabelle/Figure/Figura/Tabela/Table … + Zahl | |
| Tabelle | Zeile mit ≥ 3 Stücken, oder 2 sehr kurzen (≤ 18 Zeichen), oder ≥ 60 % Zahlen-Token; erst **≥ 2 Zeilen in Folge** werden entfernt | einzelne Zahlenzeile im Fließtext bleibt |
| Spalten | freie Gasse (≥ 15 pt oder 1,5 % der Breite) im mittleren Bereich; ≥ 5 schmale Zeilen je Seite, ≥ 60 % der Zeilen schmal, ≥ 60 % senkrechte Überlappung; Ausreißer bis 4 % erlaubt | schützt Briefe mit Adresse links/Datum rechts |
| Absatzwechsel | Zeilenabstand > 1,3 × üblicher Abstand (Median); Einzug > 0,9 × Schriftgröße; Zeile < 60 % der Spaltenbreite und nächste groß/Ziffer; Satzende bei kürzerer Zeile (< 80 %) | Adressblöcke bleiben zeilenweise getrennt |
| Silbentrennung | Zeile endet auf `-`, nächste beginnt klein: zusammenziehen, wenn `NSSpellChecker` das zusammengesetzte Wort kennt, sonst Bindestrich behalten; weicher Trennstrich immer weg; „und/oder/e/ou/and“ nach Bindestrich: Leerzeichen („Ober- und Unterstufe“); ohne Wörterbuch für die Sprache: zusammenziehen | |
| Seite ohne Text → OCR | < 25 Buchstaben oder < 50 % Buchstaben unter den Nicht-Leerzeichen | fängt auch kaputte Textebenen |
| OCR-Auflösung | lange Seite 2900 px (≈ 250 dpi bei A4); Zeilen mit Sicherheit < 0,3 verworfen | |

## Ergebnisse je Testdokument (synthetisch)

Alle Zahlen: Debug-Build, M-Serie. „Absätze“ ohne Überschriften.

| Dokument | Erwartung | Ergebnis |
| --- | --- | --- |
| `behoerdenbrief.pdf` (2 S., de) | Kopf/Fuß, Tabelle raus, Betreff als Überschrift, Silbentrennung zu | **Klappt.** Kopfzeile und „Seite N von 2 · Telefon …“ entfernt, 5 Tabellenzeilen (Position/Grundmiete/…/Summe) entfernt, Betreff als Überschrift (Ebene 3), 4 Trennungen zusammengezogen, Adressblock bleibt zeilenweise. 15 Absätze, 0,1 s. **Nicht gelöst:** steht das Datum auf *derselben* Zeile wie die letzte Adresszeile, verschmilzt PDFKit beides zu einem Stück (Fixture wurde deshalb so gelegt, dass das nicht passiert). |
| `zeitung.pdf` (2 S., zweispaltig, Blocksatz) | Gasse erkennen, Spalten nacheinander, Schlagzeile = Titel, Bildunterschrift raus | **Klappt**, erst nach den Fixes 1–3. Lesereihenfolge links→rechts über die Gasse, Schlagzeile als Ebene 1 (= `title`), Zwischentitel (12 pt fett) Ebene 2, 57 Trennungen im Blocksatz zusammengezogen, 0 beibehalten, Kopf/Seitenzahl/Bildunterschrift raus. Lücke: Fixture-Seite 2 hat nur eine Spalte, der Spaltenwechsel *mitten im Absatz über eine Seite* ist nur im Zeilenmodell-Test abgedeckt. |
| `buch.pdf` (4 S., Blocksatz, Einzug) | Kapitelüberschriften, Kolumnentitel/Seitenzahlen/Fußnote raus, Trennung | **Klappt.** Titel 24 pt → Ebene 1, Kapitel 15 pt → Ebene 2, 36 Absätze, Absätze laufen über Seitenwechsel, Kolumnentitel (wechselnd links/rechts, deshalb 40 %), 4 Seitenzahlen, Fußnotentext und Fußnotenziffer entfernt, 24 Trennungen zusammengezogen, keine Reste („`\p{L}- ?\p{Ll}`“). |
| `portugiesisch.pdf` (2 S., pt) | Sprache pt, Akzente, Trennung | **Klappt.** Sprache `pt` erkannt, Kopf-/Fußzeile (Página N de 2) raus, „19,99 euros“ und Akzente intakt. „informá-la“ bleibt korrekt mit Bindestrich (zusammengesetzt wäre „informála“ unbekannt). Betreff über zwei Zeilen zu **einer** Überschrift zusammengefasst (die zweite Zeile „123/45-6“ enthält keine Buchstaben und ging zuerst verloren – behoben). |
| `scan.pdf` (nur Bild, 150 dpi, JPEG q 0,5) | automatisch OCR, Text korrekt | **Klappt.** Seite ohne Textebene erkannt, OCR 0,5 s/Seite, Text wörtlich korrekt („450,00 Euro“, „Schriftform.“), Titel als Überschrift, 4 Absätze richtig getrennt. |
| `foto.jpg` (2,5° schief, Schatten, Rauschen, 130 dpi) | OCR trotz Schiefstand | **Klappt, mit Lücke.** Text wörtlich korrekt, Titel erkannt. Zwei Absätze (3 und 4) wurden verschmolzen, weil der Absatzabstand nach Entzerrung/Herunterrechnen unter der Schwelle lag. Für echte Handy-Fotos (Perspektive, Biegung, Licht) ist das **nicht** aussagekräftig. |
| .docx / .odt / .rtf / .html | Überschriften, Absätze | **Klappt** (Rundlauf-Tests: Titel 22 pt → Ebene 1, Unterkapitel 15 pt → Ebene 2; HTML `h1`/`h2`). HTML lädt über WebKit und muss auf dem Hauptthread laufen (ist gekapselt). |
| .txt | Kodierung | UTF-8 (± BOM), UTF-16 (± BOM), Windows-1252, Latin-1 getestet. |

Tests: `swift test` – 34 Tests grün (Zeilenmodell, Fixtures, Kodierungen, Dateiformate).

## Fazit

- Der gewählte Weg trägt: PDFKit-Text + Zeilenmodell + eigene Bereinigung liefert auf den
  synthetischen Dokumenten saubere, vorlesbare Absätze; Scans und schiefe Fotos laufen durch Vision.
- Die Plan-Annahme „Spalten über die x-Position der Zeilen“ war zu naiv (PDFKit-Zeilen laufen über
  Spalten); jetzt wird nach Wortlücken geteilt. **PLAN.md §2.4/§4.3 ist angepasst**
  (Zeilen in Stücke teilen; `characterBounds` nicht verwenden; 40-%-Schwelle).
- Der Kopf/Fuß-Schwellwert wird von 50 % auf 40 % gesenkt (Bücher mit wechselndem Kolumnentitel).
- Alles Weitere hängt an **echten** Dokumenten. Synthetische PDFs sind sauberer als echte (keine
  kaputten Schriftkodierungen, keine Zierlinien, keine Fußzeilen mit drei Spalten, kein Fließtext
  um Bilder). Die Schwellen sind deshalb als Startwerte zu verstehen.

## Bekannte Lücken

- Datum/Infoblock auf derselben Zeile wie die Adresse (PDFKit verschmilzt, wenn der Abstand klein ist).
- Tabellen mit nur zwei Spalten und längeren Zellen werden nicht erkannt (sehen aus wie zwei Spalten).
  Eine Tabellen-Überschriftszeile ohne Zahlen bleibt erhalten, wenn sie weniger als 3 Zellen hat.
- Mehrseitige Zeitungsartikel, die auf Seite 2 an anderer Stelle weitergehen („Fortsetzung auf Seite 5“),
  sowie Textboxen/Infokästen mitten im Text.
- Kopf-/Fußzeile, die nur auf Seite 1 steht (Briefkopf), bleibt im Text. Das ist gewollt vorsichtig.
- Seiten, deren Textebene aus Müll besteht, aber ≥ 50 % Buchstaben enthält, werden nicht per OCR gelesen.
- Eingebettete Seitenrotation (`/Rotate`) und Querformat nicht gesondert behandelt.
- Zweispaltige Scans/Fotos: dieselbe Logik wie bei PDF, aber ungetestet.
- Vision-Sprachliste ändert sich; Sprachen, die Vision nicht kann, fallen auf automatische Erkennung zurück.
- Das Wörterbuch (`NSSpellChecker`) kennt nicht alle zusammengesetzten Wörter; dann bleibt ein
  Bindestrich im Wort stehen („Haupt-straße“). Das klingt vorgelesen kaum anders. Ob das stört,
  zeigen erst echte Bücher.

## Bitte an den Nutzer: ca. 10 echte PDFs

Bitte lege **ca. 10 echte Dateien** in einen Ordner, z. B. `~/Desktop/vorleser-testpdfs`
(Kopien genügen; sie werden **nur lokal gelesen**, nichts wird hochgeladen oder eingecheckt).
Bitte möglichst:

1. **Behördenbrief / Schreiben von der Krankenkasse oder Versicherung** (1–3 Seiten, mit Briefkopf und Fußzeile)
2. **Zeitung oder Zeitschrift**, mehrspaltig (2 Seiten reichen; gern mit Bild und Bildunterschrift)
3. **Buch** als PDF (Kapitel, Silbentrennung; ein Auszug von 5–10 Seiten genügt)
4. **Zweispaltiger Text** (wissenschaftlicher Artikel oder Prospekt)
5. **Scan** eines Briefs vom Scanner/Drucker (nur Bild, kein markierbarer Text)
6. **Handy-Foto** eines Briefes oder einer Buchseite (.jpg/.heic direkt aus dem Handy, ruhig schief und mit Schatten)
7. **Portugiesisches PDF** (Brief, Artikel oder Buchseiten)
8. ein PDF mit **Tabelle** (Rechnung, Kontoauszug)
9. ein PDF mit **Fußnoten** (Sachbuch, Gesetzestext)
10. ein „schwieriges“ PDF, das du selbst für unlesbar hältst (Formular, Flyer)

Bitte **keine** sensiblen Dokumente nehmen, die du nicht auch mir zeigen würdest (Ausweise, Konten);
schwärze oder wähle andere.

### Spike wiederholen

```sh
cd Packages/VorleserCore
swift run spike-s4 ~/Desktop/vorleser-testpdfs 2>/dev/null
# optional: Sprache vorgeben (sonst automatisch):  --lang pt   |  anderer Ausgabeordner:  --out pfad
```

Das schreibt je Datei `spike-output/S4/<name>.txt` (Überschriften mit `#`, Absätze durch Leerzeilen,
darüber eine Kopfzeile mit dem Bericht: was entfernt, welche Seiten zweispaltig, welche Trennungen
beibehalten) und `spike-output/S4/_Zusammenfassung.txt` (Seiten, OCR-Seiten, Sprache, Zahl der
Überschriften/Absätze, Sekunden). `spike-output/` ist ignoriert.

🎧/👀 **Frage an dich, je Datei:** Lies die .txt neben dem Original und sag mir kurz
(a) fehlt Text, (b) steht Text drin, der nicht vorgelesen werden soll (Kopfzeile, Fußnote, Tabelle),
(c) sind Absätze/Überschriften an den falschen Stellen, (d) bei Spalten: stimmt die Reihenfolge?
Danach stelle ich die Schwellen in `CleanerOptions` nach und ergänze diese Datei um die echten Ergebnisse.
