import CoreGraphics
import Foundation
import TextPrep
import Testing
@testable import DocumentImport

/// Tests der Bereinigung auf dem reinen Zeilenmodell (ohne PDF).
@Suite struct PDFCleanerTests {
    static let pageSize = CGSize(width: 595, height: 842)

    /// Zeile mit Oberkante y (PDF-Koordinaten, y wächst nach oben).
    static func line(_ t: String, x: CGFloat = 70, y: CGFloat, w: CGFloat? = nil, size: CGFloat = 11,
                     bold: Bool = false, page: Int = 0) -> PageLine {
        PageLine(t, rect: CGRect(x: x, y: y - size * 1.2, width: w ?? CGFloat(t.count) * size * 0.5, height: size * 1.2),
                 fontSize: size, isBold: bold, page: page)
    }

    /// Wörterbuch-Attrappe.
    static func checker(_ known: Set<String>) -> WordChecker {
        WordChecker { w, _ in known.contains(w.lowercased()) }
    }

    func clean(_ pages: [[PageLine]], known: Set<String> = [], language: String? = "de") -> (TextDocument, CleaningReport) {
        let layouts = pages.enumerated().map { PageLayout(index: $0.offset, size: Self.pageSize, lines: $0.element) }
        return PDFCleaner(wordChecker: Self.checker(known)).clean(pages: layouts, language: language)
    }

    /// Volle Zeile Fließtext (Breite 455), damit sie nicht als kurz gilt.
    static func body(_ t: String, y: CGFloat, page: Int = 0, x: CGFloat = 70) -> PageLine {
        line(t, x: x, y: y, w: 455, page: page)
    }

    func paragraphs(_ d: TextDocument) -> [String] {
        d.blocks.compactMap { if case .paragraph(let p) = $0 { p } else { nil } }
    }

    // MARK: Kopf-/Fußzeilen, Seitenzahlen

    @Test func removesRepeatingHeaderFooterIgnoringDigits() {
        var pages: [[PageLine]] = []
        for p in 0..<4 {
            pages.append([
                Self.line("Musterbuch Verlag", y: 820, page: p),
                Self.body("Das ist der Text der Seite und er geht weiter ohne Ende \(p)", y: 700, page: p),
                Self.body("noch eine Zeile Text die zum selben Absatz gehört.", y: 686, page: p),
                Self.line("Seite \(p + 1) von 4", y: 40, page: p),
            ])
        }
        let (doc, report) = clean(pages)
        let all = paragraphs(doc).joined(separator: " ")
        #expect(!all.contains("Musterbuch"))
        #expect(!all.contains("von 4"))
        #expect(all.contains("Das ist der Text"))
        #expect(report.removedHeaderFooter == ["Musterbuch Verlag"])
        #expect(report.removedPageNumbers == 4)  // „Seite N von 4“ zählt als Seitenzahl
    }

    @Test func removesLonePageNumberEvenOnSinglePage() {
        let (doc, report) = clean([[
            Self.body("Ein ganz normaler Satz auf einer einzigen Seite.", y: 700),
            Self.line("17", x: 290, y: 40, w: 12),
        ]])
        #expect(paragraphs(doc) == ["Ein ganz normaler Satz auf einer einzigen Seite."])
        #expect(report.removedPageNumbers == 1)
    }

    @Test func keepsEdgeLineThatDoesNotRepeat() {
        let (doc, _) = clean([
            [Self.line("Briefkopf nur auf Seite eins", y: 820), Self.body("Text auf Seite eins ist lang genug hier.", y: 700)],
            [Self.body("Text auf Seite zwei ebenfalls vorhanden.", y: 700, page: 1)],
        ])
        #expect(paragraphs(doc).joined().contains("Briefkopf"))
    }

    // MARK: Silbentrennung

    @Test func joinsHyphenWhenWordKnown() {
        let (doc, report) = clean([[
            Self.body("Wir prüfen die Sil-", y: 700),
            Self.body("bentrennung im ganzen Dokument.", y: 686),
        ]], known: ["silbentrennung"])
        #expect(paragraphs(doc) == ["Wir prüfen die Silbentrennung im ganzen Dokument."])
        #expect(report.hyphenJoined == ["Silbentrennung"])
    }

    @Test func keepsHyphenWhenWordUnknownOrUppercase() {
        let (doc, report) = clean([[
            Self.body("Schreiben Sie uns eine E-", y: 700),
            Self.body("Mail oder rufen Sie die Nord-", y: 686),
            Self.body("südbahn an, bitte noch heute.", y: 672),
        ]], known: [])
        #expect(paragraphs(doc) == ["Schreiben Sie uns eine E-Mail oder rufen Sie die Nord-südbahn an, bitte noch heute."])
        #expect(report.hyphenKept.count == 2)
    }

    @Test func hyphenBeforeConjunctionKeepsSpace() {
        let (doc, _) = clean([[
            Self.body("Die Ober-", y: 700),
            Self.body("und Unterstufe ist gemeint, sagt man.", y: 686),
        ]], known: [])
        #expect(paragraphs(doc) == ["Die Ober- und Unterstufe ist gemeint, sagt man."])
    }

    @Test func removesSoftHyphen() {
        let (doc, _) = clean([[
            Self.body("Das Wort Trennstrich\u{00AD}", y: 700),
            Self.body("zeichen steht hier komplett.", y: 686),
        ]])
        #expect(paragraphs(doc) == ["Das Wort Trennstrichzeichen steht hier komplett."])
    }

    // MARK: Absätze

    @Test func paragraphBreaksOnGapAndIndent() {
        let (doc, _) = clean([[
            Self.body("Erster Absatz erste Zeile, die ziemlich lang ist und", y: 700),
            Self.body("auf der zweiten Zeile endet. Das war's.", y: 686.8),
            Self.body("Zweiter Absatz nach größerem Abstand, der weiter geht", y: 660),
            Self.body("bis zur nächsten Zeile mit Einzug am Anfang.", y: 646.8),
            Self.line("Dritter Absatz mit Einzug beginnt hier und läuft", x: 70 + 18, y: 633, w: 437),
            Self.body("noch ein bisschen weiter bis zum Ende.", y: 619.8),
        ]])
        let p = paragraphs(doc)
        #expect(p.count == 3)
        #expect(p[0].hasPrefix("Erster Absatz") && p[0].hasSuffix("Das war's."))
        #expect(p[1].hasPrefix("Zweiter Absatz"))
        #expect(p[2].hasPrefix("Dritter Absatz"))
    }

    @Test func shortUnpunctuatedLinesStaySeparate() {
        // Adressblock: kurze Zeilen ohne Satzzeichen bleiben getrennt.
        let (doc, _) = clean([[
            Self.line("Frau", y: 700, w: 30),
            Self.line("Maria Mustermann", y: 686, w: 90),
            Self.line("Beispielweg 7", y: 672, w: 70),
            Self.body("Und hier folgt ein langer Fließtext, der eine volle Zeile belegt und", y: 640),
            Self.body("auf der nächsten Zeile weiter geht, bis der Satz endet.", y: 626),
        ]])
        #expect(paragraphs(doc).count == 4)
    }

    @Test func paragraphContinuesAcrossPages() {
        let (doc, _) = clean([
            [Self.body("Der Satz beginnt auf der ersten Seite und", y: 100)],
            [Self.body("endet erst auf der zweiten Seite.", y: 790, page: 1)],
        ])
        #expect(paragraphs(doc) == ["Der Satz beginnt auf der ersten Seite und endet erst auf der zweiten Seite."])
    }

    // MARK: Überschriften

    @Test func detectsHeadingsBySizeAndBold() {
        let (doc, _) = clean([[
            Self.line("Kapitel Eins", x: 200, y: 760, size: 24, bold: true),
            Self.line("Der Anfang", y: 720, size: 15, bold: true),
            Self.body("Ein erster Satz im Fließtext, der lang genug ist,", y: 690),
            Self.body("damit er sich als Fließtext durchsetzt und mehr.", y: 676),
            Self.line("Fett gedruckte Zwischenzeile", y: 650, bold: true),
            Self.body("Noch mehr Text, der folgt und der ebenfalls lang ist,", y: 630),
            Self.body("sodass die Fließtextgröße eindeutig bleibt, ja.", y: 616),
            Self.body("Und noch eine Zeile, damit die Mehrheit klar ist.", y: 602),
        ]])
        #expect(doc.blocks[0] == .heading(level: 1, text: "Kapitel Eins"))
        #expect(doc.blocks[1] == .heading(level: 2, text: "Der Anfang"))
        #expect(doc.blocks[3] == .heading(level: 3, text: "Fett gedruckte Zwischenzeile"))
        #expect(doc.title == "Kapitel Eins")
    }

    @Test func headingEndingWithPeriodIsNotAHeading() {
        let (doc, _) = clean([[
            Self.line("Das ist ein großer Satz.", y: 760, size: 20),
            Self.body("Fließtext Fließtext Fließtext Fließtext Fließtext Fließtext", y: 700),
            Self.body("Fließtext Fließtext Fließtext Fließtext Fließtext Fließtext", y: 686),
        ]])
        #expect(!doc.blocks.contains { if case .heading = $0 { true } else { false } })
    }

    // MARK: Spalten

    @Test func orderTwoColumnsLeftThenRight() {
        var lines: [PageLine] = [Self.line("Große Schlagzeile über beide Spalten", x: 50, y: 780, w: 495, size: 22, bold: true)]
        for i in 0..<8 {
            lines.append(Self.line("links \(i) text text text", x: 50, y: 700 - CGFloat(i) * 12, w: 240, size: 10))
            lines.append(Self.line("rechts \(i) text text text", x: 305, y: 700 - CGFloat(i) * 12, w: 240, size: 10))
        }
        let (doc, report) = clean([lines])
        #expect(report.twoColumnPages == [0])
        let text = paragraphs(doc).joined(separator: " ")
        let l7 = text.range(of: "links 7")!, r0 = text.range(of: "rechts 0")!, l0 = text.range(of: "links 0")!
        #expect(l0.lowerBound < l7.lowerBound)
        #expect(l7.lowerBound < r0.lowerBound)
        #expect(doc.blocks.first == .heading(level: 1, text: "Große Schlagzeile über beide Spalten"))
    }

    @Test func singleColumnWithShortLinesIsNotSplit() {
        var lines: [PageLine] = []
        for i in 0..<8 {  // nur linke Hälfte belegt (Gedicht)
            lines.append(Self.line("Zeile \(i) des Gedichts", x: 70, y: 700 - CGFloat(i) * 14, w: 150))
        }
        let (_, report) = clean([lines])
        #expect(report.twoColumnPages.isEmpty)
    }

    // MARK: Fußnoten, Bildunterschriften, Tabellen

    @Test func dropsFootnotesInLowerPageArea() {
        let (doc, report) = clean([[
            Self.body("Der Haupttext steht oben auf der Seite und ist lang genug,", y: 700),
            Self.body("damit die Fließtextgröße klar bei elf Punkt liegt, ja.", y: 686),
            Self.body("Noch eine Zeile, die den Absatz sicher stützt und weiter geht.", y: 672),
            Self.line("1 Vgl. Meyer, Reisen im 19. Jahrhundert, Berlin 1987.", y: 150, size: 8),
        ]])
        #expect(!paragraphs(doc).joined().contains("Meyer"))
        #expect(report.removedFootnoteLines == 1)
    }

    @Test func stripsFootnoteMarkers() {
        #expect(TextHelpers.stripFootnoteMarkers("könnte er verschwinden.1") == "könnte er verschwinden.")
        #expect(TextHelpers.stripFootnoteMarkers("so sagt man,12 und weiter") == "so sagt man, und weiter")
        #expect(TextHelpers.stripFootnoteMarkers("siehe Abschnitt 3.1 zeigt") == "siehe Abschnitt 3.1 zeigt")
        #expect(TextHelpers.stripFootnoteMarkers("Wort¹ und Wort²³") == "Wort und Wort")
        #expect(TextHelpers.stripFootnoteMarkers("Preis 19,99 Euro") == "Preis 19,99 Euro")
    }

    @Test func dropsCaptions() {
        let (doc, report) = clean([[
            Self.body("Ein Absatz mit genug Text, der klar den Fließtext bildet,", y: 700),
            Self.body("und der über mehrere Zeilen läuft, damit es passt.", y: 686),
            Self.line("Abbildung 3: Der geplante Radweg an der Hauptstraße.", y: 640, w: 255),
            Self.body("Danach geht der Text ganz normal weiter mit mehr Worten und", y: 600),
            Self.body("noch einer Zeile, sodass der Absatz sicher steht.", y: 586),
        ]])
        #expect(!paragraphs(doc).joined().contains("Abbildung"))
        #expect(report.removedCaptions.count == 1)
    }

    @Test func dropsTableRowsButKeepsSingleTabularLine() {
        func cell(_ t: String, x: CGFloat, y: CGFloat, row: Int) -> PageLine {
            var l = Self.line(t, x: x, y: y, w: 60)
            l.row = row; l.cells = 3
            return l
        }
        var lines: [PageLine] = [
            Self.body("Vor der Tabelle steht ein normaler Satz, der lang genug ist,", y: 700),
            Self.body("und noch eine Zeile, die den Absatz sicher beendet.", y: 686),
        ]
        for (i, r) in [("Position", "Monatlich", "Jährlich"), ("Miete", "450,00", "5.400,00"), ("Summe", "645,50", "7.746,00")].enumerated() {
            let y = 640 - CGFloat(i) * 16
            lines += [cell(r.0, x: 70, y: y, row: i), cell(r.1, x: 250, y: y, row: i), cell(r.2, x: 400, y: y, row: i)]
        }
        lines.append(Self.body("Nach der Tabelle geht der Text weiter, auch wieder lang genug,", y: 560))
        lines.append(Self.body("bis zum Ende des Absatzes und noch ein Stück weiter.", y: 546))
        let (doc, report) = clean([lines])
        let text = paragraphs(doc).joined(separator: " ")
        #expect(!text.contains("Monatlich") && !text.contains("5.400,00"))
        #expect(text.contains("Vor der Tabelle") && text.contains("Nach der Tabelle"))
        #expect(report.removedTableLines == 3)

        // Eine einzelne Zeile mit vielen Zahlen allein bleibt stehen (keine Tabelle).
        let (single, _) = clean([[
            Self.body("Im Jahr 2023 stiegen die Preise um 5,2 Prozent im Mittel, hieß es,", y: 700),
            Self.body("und das ist eine ganz normale Zeile Fließtext hier.", y: 686),
        ]])
        #expect(paragraphs(single).count == 1)
    }

    // MARK: Sprache

    @Test func detectsLanguage() {
        #expect(TextHelpers.detectLanguage("Das ist ein längerer deutscher Satz, der sicher erkannt werden sollte, weil er lang genug ist.") == "de")
        #expect(TextHelpers.detectLanguage("Agradecemos o seu pedido de apoio à habitação, que deu entrada nos nossos serviços ontem.") == "pt")
        #expect(TextHelpers.detectLanguage("Hi") == nil)
    }

    @Test func pageNumberPatterns() {
        for s in ["12", "- 12 -", "Seite 3 von 10", "Página 4 de 9", "iv", "Page 7"] { #expect(PDFCleaner.isPageNumber(s), "\(s)") }
        for s in ["Kapitel 3", "2025 war ein Jahr", "Seite eins"] { #expect(!PDFCleaner.isPageNumber(s), "\(s)") }
    }
}
