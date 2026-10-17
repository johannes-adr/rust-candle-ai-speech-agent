import CoreGraphics
import Foundation
import TextPrep

/// Schwellen der PDF-Bereinigung (PLAN.md §4.3 Schritt 3). Begründung: docs/spikes/S4-pdfs.md.
public struct CleanerOptions: Sendable {
    /// Oberer/unterer Seitenrand (Anteil der Seitenhöhe), in dem Kopf-/Fußzeilen gesucht werden.
    public var edgeBand: CGFloat = 0.10
    /// Anteil der Seiten, auf denen eine Randzeile wiederkehren muss (Ziffern ignoriert).
    public var repeatThreshold: Double = 0.4
    /// Ab diesem Verhältnis zur Fließtextgröße gilt eine Zeile als Überschrift.
    public var headingSizeRatio: CGFloat = 1.15
    /// Kleiner als dieses Verhältnis (im unteren Seitendrittel) = Fußnote.
    public var footnoteSizeRatio: CGFloat = 0.88
    /// Zeilenabstand über diesem Vielfachen des üblichen Abstands = neuer Absatz.
    public var paragraphPitchFactor: CGFloat = 1.3
    /// Einzug (in Schriftgrößen) ab dem eine Zeile einen neuen Absatz beginnt.
    public var indentFactor: CGFloat = 0.9
    /// Kürzer als dieser Anteil der Spaltenbreite = Zeile endet bewusst (Adresse, Absatzende).
    public var shortLineRatio: CGFloat = 0.6
    /// Überschriften sind kurz; längere Zeilen mit großer Schrift sind Fließtext.
    public var maxHeadingLength = 100
    /// Bei OCR schwankt die Zeilenhöhe je nach Buchstaben (Ober-/Unterlängen); deshalb ein höherer Wert.
    public var ocrHeadingSizeRatio: CGFloat = 1.2
    /// Bei OCR zusätzlich: Überschriften sind höchstens so lang.
    public var ocrMaxHeadingLength = 60
    public var minLinesPerColumn = 5

    public init() {}
}

/// Bringt Zeilen mit Position in saubere Blöcke: Kopf-/Fußzeilen und Seitenzahlen
/// raus, Spalten in Lesereihenfolge, Silbentrennung zusammen, Zeilen zu Absätzen,
/// Überschriften erkennen, Fußnoten/Tabellen/Bildunterschriften überspringen.
public struct PDFCleaner: Sendable {
    public var options: CleanerOptions
    public var wordChecker: WordChecker

    public init(options: CleanerOptions = CleanerOptions(), wordChecker: WordChecker = .system) {
        self.options = options
        self.wordChecker = wordChecker
    }

    // MARK: - Einstieg

    public func clean(pages: [PageLayout], language: String? = nil) -> (document: TextDocument, report: CleaningReport) {
        var report = CleaningReport()
        let allText = pages.flatMap(\.lines).map(\.text).joined(separator: " ")
        let lang = language ?? TextHelpers.detectLanguage(allText)
        report.language = lang

        // 1. Kopf-/Fußzeilen und Seitenzahlen
        let kept = removeHeadersFooters(pages: pages, report: &report)

        // 2. Fließtextgröße
        let allKept = kept.flatMap(\.lines)
        let body = bodyFontSize(allKept)
        report.bodyFontSize = Double(body)
        let bodyIsBold = boldShare(allKept) > 0.5

        // 3. Tabellen (Zeilen mit mehreren Zellen, ≥ 2 Zeilen in Folge) raus, solange die Zeilen noch Zeilen sind
        let noTables = kept.map { removeTables(page: $0, report: &report) }

        // 4. Spalten und Lesereihenfolge je Seite, dann Fußnoten raus
        var stream: [OrderedLine] = []
        for page in noTables {
            let (ordered, twoColumns) = order(page: page)
            if twoColumns { report.twoColumnPages.append(page.index) }
            for o in ordered {
                if isFootnote(o.line, pageHeight: page.size.height, body: body) {
                    report.removedFootnoteLines += 1
                    continue
                }
                stream.append(o)
            }
        }

        // 5. Blöcke bauen
        let pitch = typicalPitch(stream, body: body)
        var builder = BlockBuilder(
            options: options, body: body, bodyIsBold: bodyIsBold, pitch: pitch,
            language: lang, checker: wordChecker,
            ocrPages: Set(pages.filter(\.fromOCR).map(\.index))
        )
        for o in stream { builder.add(o) }
        let (blocks, hyphenJoined, hyphenKept) = builder.finish(report: &report)
        report.hyphenJoined = hyphenJoined
        report.hyphenKept = hyphenKept

        var title: String?
        if let first = blocks.first(where: { if case .heading(let l, _) = $0 { return l == 1 } else { return false } }),
           case .heading(_, let t) = first {
            title = t
        }
        return (TextDocument(title: title, blocks: blocks), report)
    }

    // MARK: - Kopf-/Fußzeilen

    static let pageNumberPattern = try! NSRegularExpression(
        pattern: #"^\W*(?:(?:seite|page|página|pagina|pág\.|p\.|s\.)\s*)?(?:\d{1,4}|[ivxlcdm]{1,6})(?:\s*(?:von|of|de|di|sur|/)\s*\d{1,4})?\W*$"#,
        options: [.caseInsensitive]
    )

    private func isEdge(_ line: PageLine, in page: PageLayout) -> Bool {
        let h = page.size.height
        guard h > 0 else { return false }
        let y = line.rect.midY
        return y > h * (1 - options.edgeBand) || y < h * options.edgeBand
    }

    /// Schlüssel für den Vergleich: klein, ohne Ziffern, ohne Satzzeichen am Rand.
    static func repeatKey(_ text: String) -> String {
        let noDigits = text.lowercased().filter { !$0.isNumber }
        let collapsed = noDigits.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols))
    }

    static func isPageNumber(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard t.count <= 24 else { return false }
        let r = NSRange(t.startIndex..., in: t)
        return pageNumberPattern.firstMatch(in: t, range: r) != nil
    }

    private func removeHeadersFooters(pages: [PageLayout], report: inout CleaningReport) -> [PageLayout] {
        let n = pages.count
        var pagesWithKey: [String: Set<Int>] = [:]
        for p in pages {
            for l in p.lines where isEdge(l, in: p) {
                let key = Self.repeatKey(l.text)
                if !key.isEmpty { pagesWithKey[key, default: []].insert(p.index) }
            }
        }
        let needed = max(2, Int((Double(n) * options.repeatThreshold).rounded(.up)))
        let repeated = Set(pagesWithKey.filter { $0.value.count >= needed }.keys)

        var result: [PageLayout] = []
        var seenRemoved = Set<String>()
        for var p in pages {
            p.lines = p.lines.filter { l in
                guard isEdge(l, in: p) else { return true }
                if Self.isPageNumber(l.text) { report.removedPageNumbers += 1; return false }
                let key = Self.repeatKey(l.text)
                if repeated.contains(key) {
                    if seenRemoved.insert(key).inserted { report.removedHeaderFooter.append(l.text) }
                    return false
                }
                return true
            }
            result.append(p)
        }
        return result
    }

    // MARK: - Größen

    /// Häufigste Schriftgröße, gewichtet nach Zeichenzahl (auf 0,5 pt gerundet).
    func bodyFontSize(_ lines: [PageLine]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for l in lines { weights[(l.fontSize * 2).rounded() / 2, default: 0] += l.text.count }
        return weights.max { $0.value < $1.value }?.key ?? 11
    }

    private func boldShare(_ lines: [PageLine]) -> Double {
        let total = lines.reduce(0) { $0 + $1.text.count }
        guard total > 0 else { return 0 }
        return Double(lines.filter(\.isBold).reduce(0) { $0 + $1.text.count }) / Double(total)
    }

    private func typicalPitch(_ stream: [OrderedLine], body: CGFloat) -> CGFloat {
        var pitches: [CGFloat] = []
        for (a, b) in zip(stream, stream.dropFirst()) where a.line.page == b.line.page {
            let d = a.line.rect.midY - b.line.rect.midY
            if abs(a.line.fontSize - b.line.fontSize) < max(0.6, a.line.fontSize * 0.25), d > 0, d < a.line.fontSize * 3 {
                pitches.append(d)
            }
        }
        guard !pitches.isEmpty else { return body * 1.25 }
        pitches.sort()
        return pitches[pitches.count / 2]
    }

    // MARK: - Fußnoten und Tabellen

    private func isFootnote(_ l: PageLine, pageHeight: CGFloat, body: CGFloat) -> Bool {
        l.fontSize < body * options.footnoteSizeRatio && l.rect.midY < pageHeight * 0.35
    }

    static func isTabular(_ text: String) -> Bool {
        if text.contains("   ") || text.contains("\t") {
            let gaps = text.components(separatedBy: "   ").count - 1
            if gaps >= 2 { return true }
        }
        let tokens = text.split(separator: " ")
        guard tokens.count >= 3 else { return false }
        let numeric = tokens.filter { t in
            let s = t.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:%€$£()-–+/"))
            return s.isEmpty || s.allSatisfy { $0.isNumber || $0 == "," || $0 == "." }
        }
        return Double(numeric.count) / Double(tokens.count) >= 0.6
    }

    /// Entfernt Tabellen: Zeilen (Stücke mit gleicher `row`) gelten als Tabellenzeile bei ≥ 3 Zellen,
    /// bei 2 sehr kurzen Zellen oder nach Textmerkmalen; erst ≥ 2 Tabellenzeilen in Folge werden entfernt.
    private func removeTables(page: PageLayout, report: inout CleaningReport) -> PageLayout {
        // Zeilen bilden: Stücke mit gleicher row zusammen, sonst je Stück eine Zeile.
        var groups: [[Int]] = []
        var byRow: [Int: Int] = [:]
        for (i, l) in page.lines.enumerated() {
            if l.row >= 0, let g = byRow[l.row] { groups[g].append(i) } else {
                if l.row >= 0 { byRow[l.row] = groups.count }
                groups.append([i])
            }
        }
        func top(_ g: [Int]) -> CGFloat { g.map { page.lines[$0].rect.maxY }.max() ?? 0 }
        groups.sort { top($0) > top($1) }
        func isTableRow(_ g: [Int]) -> Bool {
            let ls = g.map { page.lines[$0] }
            if ls.count >= 3 { return true }
            if ls.count == 2, ls.allSatisfy({ $0.text.count <= 18 }) { return true }
            return ls.count == 1 && Self.isTabular(ls[0].text)
        }
        let flags = groups.map(isTableRow)
        var drop = Set<Int>()
        var i = 0
        while i < groups.count {
            if flags[i] {
                var j = i
                while j < groups.count, flags[j] { j += 1 }
                if j - i >= 2 {
                    for k in i..<j { for idx in groups[k] { drop.insert(idx) } }
                    report.removedTableLines += j - i
                }
                i = j
            } else { i += 1 }
        }
        var p = page
        p.lines = page.lines.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        return p
    }

    // MARK: - Spalten

    struct OrderedLine {
        var line: PageLine
        var colLeft: CGFloat
        var colWidth: CGFloat
    }

    /// Bringt die Zeilen einer Seite in Lesereihenfolge; erkennt zwei Spalten über
    /// eine freie senkrechte Gasse in der Seitenmitte.
    func order(page: PageLayout) -> (lines: [OrderedLine], twoColumns: Bool) {
        let lines = page.lines.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return ([], false) }
        let minX = lines.map(\.rect.minX).min()!
        let maxX = lines.map(\.rect.maxX).max()!
        let span = maxX - minX

        func singleColumn() -> [OrderedLine] {
            let sorted = lines.sorted { a, b in
                if abs(a.rect.maxY - b.rect.maxY) > 1 { return a.rect.maxY > b.rect.maxY }
                return a.rect.minX < b.rect.minX
            }
            return mergeRows(sorted.map { OrderedLine(line: $0, colLeft: minX, colWidth: span) })
        }

        guard lines.count >= options.minLinesPerColumn * 2, span > 100,
              let gutter = findGutter(lines: lines, minX: minX, span: span)
        else { return (singleColumn(), false) }

        func side(_ l: PageLine) -> Int {
            if l.rect.minX < gutter - 1, l.rect.maxX > gutter + 1 { return 0 }  // überspannt die Gasse
            return l.rect.midX < gutter ? -1 : 1
        }
        let leftLines = lines.filter { side($0) == -1 }
        let rightLines = lines.filter { side($0) == 1 }
        let leftX = leftLines.map(\.rect.minX).min() ?? minX
        let leftW = (leftLines.map(\.rect.maxX).max() ?? gutter) - leftX
        let rightX = rightLines.map(\.rect.minX).min() ?? gutter
        let rightW = (rightLines.map(\.rect.maxX).max() ?? maxX) - rightX

        let sorted = lines.sorted { $0.rect.maxY > $1.rect.maxY }
        var out: [OrderedLine] = []
        var left: [PageLine] = [], right: [PageLine] = []
        func flush() {
            out += left.sorted { $0.rect.maxY > $1.rect.maxY }.map { OrderedLine(line: $0, colLeft: leftX, colWidth: leftW) }
            out += right.sorted { $0.rect.maxY > $1.rect.maxY }.map { OrderedLine(line: $0, colLeft: rightX, colWidth: rightW) }
            left = []; right = []
        }
        for l in sorted {
            switch side(l) {
            case -1: left.append(l)
            case 1: right.append(l)
            default:
                flush()
                out.append(OrderedLine(line: l, colLeft: minX, colWidth: span))
            }
        }
        flush()
        return (mergeRows(out), true)
    }

    /// Setzt Stücke derselben PDFKit-Zeile, die in der Reihenfolge nebeneinander liegen
    /// (zu Unrecht geteilt, z. B. weite Wortabstände im Blocksatz), wieder zusammen.
    private func mergeRows(_ lines: [OrderedLine]) -> [OrderedLine] {
        var out: [OrderedLine] = []
        for o in lines {
            if var last = out.last, o.line.row >= 0, last.line.row == o.line.row, last.line.page == o.line.page,
               o.line.rect.minX >= last.line.rect.minX {
                last.line.text += " " + o.line.text
                last.line.rect = last.line.rect.union(o.line.rect)
                out[out.count - 1] = last
            } else {
                out.append(o)
            }
        }
        return out
    }

    /// Sucht eine freie senkrechte Gasse zwischen zwei Spalten. nil = einspaltig.
    private func findGutter(lines: [PageLine], minX: CGFloat, span: CGFloat) -> CGFloat? {
        let narrow = lines.filter { $0.rect.width < span * 0.62 }
        guard narrow.count >= options.minLinesPerColumn * 2, Double(narrow.count) >= 0.6 * Double(lines.count) else { return nil }

        // Überdeckung je 2-pt-Streifen zählen; einzelne Ausreißer-Zeilen (Zierlinien, ein Zitat) sind erlaubt.
        let bin: CGFloat = 2
        let nBins = Int(span / bin) + 1
        var cover = [Int](repeating: 0, count: nBins)
        for l in narrow {
            let a = max(0, Int((l.rect.minX - minX) / bin)), b = min(nBins - 1, Int((l.rect.maxX - minX) / bin))
            if a <= b { for k in a...b { cover[k] += 1 } }
        }
        let tolerance = max(1, Int(Double(narrow.count) * 0.04))
        let lo = Int(span * 0.25 / bin), hi = Int(span * 0.75 / bin)
        var best: (CGFloat, CGFloat)? = nil
        var runStart: Int?
        for k in lo...min(hi, nBins - 1) + 1 {
            let free = k <= min(hi, nBins - 1) && cover[k] <= tolerance
            if free { if runStart == nil { runStart = k } } else if let s0 = runStart {
                let g = (minX + CGFloat(s0) * bin, minX + CGFloat(k) * bin)
                if g.1 - g.0 >= max(6, span * 0.015), best == nil || g.1 - g.0 > best!.1 - best!.0 { best = g }
                runStart = nil
            }
        }
        guard let g = best else { return nil }
        let gutter = (g.0 + g.1) / 2
        let left = narrow.filter { $0.rect.maxX <= gutter }
        let right = narrow.filter { $0.rect.minX >= gutter }
        guard left.count >= options.minLinesPerColumn, right.count >= options.minLinesPerColumn else { return nil }
        // Beide Spalten müssen sich senkrecht deutlich überlappen.
        func range(_ ls: [PageLine]) -> (CGFloat, CGFloat) { (ls.map(\.rect.minY).min()!, ls.map(\.rect.maxY).max()!) }
        let (l0, l1) = range(left), (r0, r1) = range(right)
        let overlap = min(l1, r1) - max(l0, r0)
        let smaller = min(l1 - l0, r1 - r0)
        guard smaller > 0, overlap / smaller >= 0.6 else { return nil }
        return gutter
    }
}

// MARK: - Blockbau

extension PDFCleaner {
    struct BlockBuilder {
        let options: CleanerOptions
        let body: CGFloat
        let bodyIsBold: Bool
        let pitch: CGFloat
        let language: String?
        let checker: WordChecker
        let ocrPages: Set<Int>

        private var blocks: [TextBlock] = []
        private var captionsRemoved: [String] = []
        // laufender Absatz
        private var paraText = ""
        private var paraLast: OrderedLine?
        // laufende Überschrift (mehrzeilig)
        private var headingText = ""
        private var headingSize: CGFloat = 0
        private var headingLast: OrderedLine?
        private var headingSizes: [(text: String, size: CGFloat, bold: Bool)] = []
        private var joined: [String] = []
        private var kept: [String] = []

        init(options: CleanerOptions, body: CGFloat, bodyIsBold: Bool, pitch: CGFloat, language: String?, checker: WordChecker, ocrPages: Set<Int>) {
            self.options = options; self.body = body; self.bodyIsBold = bodyIsBold
            self.pitch = pitch; self.language = language; self.checker = checker; self.ocrPages = ocrPages
        }

        static let captionPattern = try! NSRegularExpression(
            pattern: #"^\s*(abbildung|abb\.|bild|foto|grafik|tabelle|tab\.|figure|fig\.|figura|tabela|table|imagem|foto|fotografia|gráfico|quadro|photo|image)\s*\d+"#,
            options: [.caseInsensitive]
        )

        // Überschrift?
        private func isHeadingLine(_ l: PageLine) -> Bool {
            let t = l.text
            let isOCR = ocrPages.contains(l.page)
            guard t.count <= (isOCR ? options.ocrMaxHeadingLength : options.maxHeadingLength), TextHelpers.letterCount(t) >= 2 else { return false }
            if let c = t.last, [".", ",", ";", ":"].contains(c) { return false }
            let ratio = isOCR ? options.ocrHeadingSizeRatio : options.headingSizeRatio
            if l.fontSize >= body * ratio { return true }
            if !bodyIsBold, l.isBold, t.count <= 90, abs(l.fontSize - body) < body * 0.15 + 0.5 { return true }
            return false
        }

        /// Zweite Zeile einer Überschrift, die selbst nicht „überschriftig“ aussieht (z. B. nur Zahlen).
        private func continuesHeading(_ l: PageLine) -> Bool {
            guard let last = headingLast, last.line.page == l.page, abs(last.line.fontSize - l.fontSize) < 1,
                  last.line.isBold == l.isBold, l.text.count <= options.maxHeadingLength else { return false }
            return last.line.rect.minY - l.rect.maxY < l.fontSize * 0.8 && last.line.rect.minY > l.rect.maxY - 1
        }

        mutating func add(_ o: OrderedLine) {
            let l = o.line
            let text = TextHelpers.stripFootnoteMarkers(l.text)
            guard !text.isEmpty else { return }

            if isHeadingLine(l) || continuesHeading(l) {
                flushParagraph()
                if let last = headingLast, last.line.page == l.page, abs(last.line.fontSize - l.fontSize) < 1,
                   last.line.rect.minY - l.rect.maxY < l.fontSize * 1.0, last.line.rect.minY > l.rect.maxY - 1 {
                    headingText += " " + text
                } else {
                    flushHeading()
                    headingText = text
                    headingSize = l.fontSize
                    headingSizes.append((text, l.fontSize, l.isBold))
                }
                headingLast = o
                return
            }
            flushHeading()

            if let last = paraLast, startsNewParagraph(prev: last, cur: o) {
                flushParagraph()
            }
            if paraLast == nil {
                paraText = text
            } else {
                paraText = joinLines(paraText, text)
            }
            paraLast = o
        }

        private mutating func flushHeading() {
            guard headingLast != nil else { return }
            let sizeIndex = blocks.count
            blocks.append(.heading(level: 0, text: headingText))
            headingLevelSlots.append((sizeIndex, headingSize, headingBoldOnly(headingSize)))
            headingText = ""; headingLast = nil
        }

        private func headingBoldOnly(_ size: CGFloat) -> Bool { size < body * options.headingSizeRatio }
        private var headingLevelSlots: [(index: Int, size: CGFloat, boldOnly: Bool)] = []

        private mutating func flushParagraph() {
            guard paraLast != nil else { return }
            let text = paraText.trimmingCharacters(in: .whitespaces)
            paraText = ""; paraLast = nil
            guard !text.isEmpty else { return }
            let r = NSRange(text.startIndex..., in: text)
            if text.count < 400, Self.captionPattern.firstMatch(in: text, range: r) != nil {
                captionsRemoved.append(text)
                return
            }
            // Reine Ziffern/Zeichen ohne Buchstaben (z. B. Reste) überspringen.
            guard TextHelpers.letterCount(text) > 0 else { return }
            blocks.append(.paragraph(text))
        }

        private func startsNewParagraph(prev: OrderedLine, cur: OrderedLine) -> Bool {
            let p = prev.line, c = cur.line
            let prevEnds = TextHelpers.endsWithTerminalPunctuation(p.text)
            let movedAway = c.page != p.page || c.rect.midY > p.rect.midY + 1  // Seiten- oder Spaltenwechsel
            if movedAway { return prevEnds }
            // Absätze der Texterkennung (RecognizeDocumentsRequest) übernehmen.
            if p.paragraph >= 0, c.paragraph >= 0 { return p.paragraph != c.paragraph }
            let sizeTolerance = ocrPages.contains(c.page) ? c.fontSize * 0.5 : 1.0  // OCR: Höhe schwankt je nach Buchstaben
            if abs(p.fontSize - c.fontSize) > sizeTolerance { return true }
            let step = p.rect.midY - c.rect.midY  // Mitte statt Unterkante: unempfindlich gegen Höhenschwankung (OCR)
            if step > pitch * options.paragraphPitchFactor { return true }
            let colWidth = max(cur.colWidth, 1)
            let prevShort = p.rect.width < colWidth * options.shortLineRatio
            let firstChar = c.text.first
            let nextLower = firstChar?.isLowercase ?? false
            if cur.line.rect.minX - cur.colLeft > c.fontSize * options.indentFactor,
               cur.line.rect.minX - cur.colLeft < colWidth * 0.5,
               prevEnds || prevShort { return true }
            if prevShort && (prevEnds || !nextLower) { return true }
            if prevEnds && p.rect.width < colWidth * 0.8 { return true }
            return false
        }

        /// Fügt zwei Zeilen zusammen, zieht Silbentrennung zusammen.
        private mutating func joinLines(_ a: String, _ b: String) -> String {
            // weicher Trennstrich: immer entfernen
            if a.hasSuffix("\u{00AD}") { return String(a.dropLast()) + b }
            if let lastChar = a.last, lastChar == "-" || lastChar == "\u{2010}" || lastChar == "¬" {
                let beforeIndex = a.index(before: a.endIndex)
                let prefixPart = String(a[..<beforeIndex])
                if let pc = prefixPart.last, pc.isLetter, let fc = b.first, fc.isLetter {
                    let leftWord = String(prefixPart.reversed().prefix { $0.isLetter }.reversed())
                    let rightWord = String(b.prefix { $0.isLetter })
                    if fc.isLowercase {
                        let joinedWord = leftWord + rightWord
                        switch checker.isKnown(joinedWord, language) {
                        case .some(true):
                            joined.append(joinedWord)
                            return prefixPart + b
                        case .none:
                            // Kein Wörterbuch: Kleinschreibung nach Trennstrich = Silbentrennung.
                            joined.append(joinedWord)
                            return prefixPart + b
                        case .some(false):
                            break
                        }
                        if Self.conjunctions.contains(rightWord.lowercased()) {
                            kept.append(leftWord + "-")
                            return a + " " + b
                        }
                    }
                    kept.append(leftWord + "-" + rightWord)
                    return a + b
                }
            }
            if let lc = a.last, let fc = b.first, TextHelpers.isCJK(lc), TextHelpers.isCJK(fc) { return a + b }
            return a + " " + b
        }

        static let conjunctions: Set<String> = ["und", "oder", "bzw.", "sowie", "e", "ou", "and", "or", "et", "ou", "y", "o", "und/oder"]

        mutating func finish(report: inout CleaningReport) -> ([TextBlock], [String], [String]) {
            flushHeading()
            flushParagraph()
            report.removedCaptions = captionsRemoved
            // Ebenen nach Rang der Größen vergeben.
            let bigSizes = Array(Set(headingLevelSlots.filter { !$0.boldOnly }.map { ($0.size * 2).rounded() / 2 })).sorted(by: >)
            // Größen innerhalb von 1 pt zu einer Ebene zusammenfassen.
            var clusters: [CGFloat] = []
            for s in bigSizes where clusters.last.map({ $0 - s >= 1 }) ?? true { clusters.append(s) }
            for slot in headingLevelSlots {
                let level: Int
                if slot.boldOnly {
                    level = min(max(clusters.count + 1, 3), 3)
                } else {
                    let rank = clusters.firstIndex { abs($0 - slot.size) < 1 } ?? clusters.count - 1
                    level = min(rank + 1, 3)
                }
                if case .heading(_, let t) = blocks[slot.index] { blocks[slot.index] = .heading(level: level, text: t) }
            }
            return (blocks, joined, kept)
        }
    }
}
