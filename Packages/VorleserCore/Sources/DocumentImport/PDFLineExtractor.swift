import AppKit
import Foundation
import PDFKit

/// Liest Zeilen mit Position, Schriftgröße und Fettdruck aus einer PDF-Seite (PDFKit).
///
/// PDFKit fasst Text auf gleicher Grundlinie zu einer „Zeile“ zusammen, auch über
/// Spalten und Tabellenzellen hinweg. Deshalb wird jede Zeile an großen waagerechten
/// Lücken (über die Zeichenpositionen) in Stücke geteilt; die Bereinigung setzt die
/// Spalten dann wieder richtig zusammen.
enum PDFLineExtractor {
    /// Lücke ab dieser Höhenanteile (Zeichenhöhe) trennt zwei Stücke.
    static let gapFactor: CGFloat = 0.8
    static let minGap: CGFloat = 5

    /// Zeilen einer Seite aus der Textebene. Leer, wenn die Seite keinen Text hat.
    static func lines(of page: PDFPage, index: Int) -> [PageLine] {
        let bounds = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: bounds) else { return [] }
        let pageString = (page.string ?? "") as NSString
        var result: [PageLine] = []
        var rowID = 0
        for line in selection.selectionsByLine() {
            var fragments: [PageLine] = []
            for ri in 0..<line.numberOfTextRanges(on: page) {
                let r = line.range(at: ri, on: page)
                guard r.location != NSNotFound, r.location + r.length <= pageString.length else { continue }
                fragments += split(range: r, of: pageString, page: page, pageIndex: index)
            }
            if fragments.isEmpty {
                // Fallback: ganze Zeile ohne Teilung
                let rect = line.bounds(for: page)
                let (text, size, bold) = analyze(line.attributedString, fallbackSize: rect.height * 0.85)
                let clean = TextHelpers.normalize(text)
                if rect.width > 0, !clean.isEmpty {
                    fragments.append(PageLine(clean, rect: rect, fontSize: size, isBold: bold, page: index))
                }
            }
            for var f in fragments {
                f.row = rowID
                f.cells = fragments.count
                result.append(f)
            }
            rowID += 1
        }
        return result
    }

    /// Teilt einen Textbereich an großen Lücken zwischen Wörtern.
    /// (`PDFPage.characterBounds(at:)` ist hier unbrauchbar: Die Indizes passen nicht zu `page.string`.
    /// Deshalb werden Wortgrenzen über `selection(for: NSRange)` vermessen.)
    private static func split(range: NSRange, of string: NSString, page: PDFPage, pageIndex: Int) -> [PageLine] {
        let lineStr = string.substring(with: range) as NSString
        // Wörter mit Versatz im Bereich
        var words: [NSRange] = []
        var i = 0
        while i < lineStr.length {
            while i < lineStr.length, isSpace(lineStr.character(at: i)) { i += 1 }
            let st = i
            while i < lineStr.length, !isSpace(lineStr.character(at: i)) { i += 1 }
            if i > st { words.append(NSRange(location: st, length: i - st)) }
        }
        guard !words.isEmpty else { return [] }

        // Atome: Wörter; Wörter mit unplausibel großer Breite (Spaltenwechsel ohne Leerzeichen,
        // z. B. „Mehr-“ links und „Bürgermeisterin“ rechts) werden zeichenweise geteilt.
        var atoms: [(NSRange, CGRect)] = []
        for w in words {
            let abs = NSRange(location: range.location + w.location, length: w.length)
            guard let rect = page.selection(for: abs)?.bounds(for: page), rect.width > 0 else { continue }
            if w.length >= 3, rect.width / CGFloat(w.length) > rect.height * 0.8 {
                atoms += splitByCharacters(abs, page: page)
            } else {
                atoms.append((abs, rect))
            }
        }
        guard !atoms.isEmpty else { return [] }

        var pieces: [(NSRange, CGRect)] = []
        var cur = atoms[0]
        for atom in atoms.dropFirst() {
            if atom.1.minX - cur.1.maxX > max(minGap, atom.1.height * gapFactor) {
                pieces.append(cur)
                cur = atom
            } else {
                cur = (NSRange(location: cur.0.location, length: atom.0.location + atom.0.length - cur.0.location), cur.1.union(atom.1))
            }
        }
        pieces.append(cur)

        var out: [PageLine] = []
        for (r, rect) in pieces where !rect.isNull {
            guard let sel = page.selection(for: r) else { continue }
            let (text, size, bold) = analyze(sel.attributedString, fallbackSize: rect.height * 0.85)
            let clean = TextHelpers.normalize(text)
            if !clean.isEmpty {
                out.append(PageLine(clean, rect: rect, fontSize: size, isBold: bold, page: pageIndex))
            }
        }
        return out
    }

    /// Teilt ein Wort an Lücken zwischen einzelnen Zeichen (nur für verdächtig breite Wörter).
    private static func splitByCharacters(_ range: NSRange, page: PDFPage) -> [(NSRange, CGRect)] {
        var out: [(NSRange, CGRect)] = []
        var cur: (NSRange, CGRect)?
        for i in range.location..<(range.location + range.length) {
            let r = NSRange(location: i, length: 1)
            guard let b = page.selection(for: r)?.bounds(for: page), b.width > 0 else { continue }
            if let c = cur {
                if b.minX - c.1.maxX > max(minGap, b.height * gapFactor) {
                    out.append(c)
                    cur = (r, b)
                } else {
                    cur = (NSRange(location: c.0.location, length: i + 1 - c.0.location), c.1.union(b))
                }
            } else {
                cur = (r, b)
            }
        }
        if let c = cur { out.append(c) }
        return out
    }

    private static func isSpace(_ c: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Text ohne hochgestellte Ziffern (Fußnotenverweise), dazu Größe und Fettdruck.
    /// Größe und Fettdruck gelten für die Mehrheit der Zeichen.
    static func analyze(_ attributed: NSAttributedString?, fallbackSize: CGFloat) -> (String, CGFloat, Bool) {
        guard let attributed, attributed.length > 0 else { return ("", fallbackSize, false) }
        // Größte Schriftgröße der Zeile ist die Bezugsgröße für „klein = hochgestellt“.
        var maxSize: CGFloat = 0
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { v, range, _ in
            if let f = v as? NSFont, range.length > 0 { maxSize = max(maxSize, f.pointSize) }
        }
        if maxSize == 0 { maxSize = fallbackSize }

        var text = ""
        var sizeWeights: [CGFloat: Int] = [:]
        var boldChars = 0, totalChars = 0
        let full = attributed.string as NSString
        attributed.enumerateAttributes(in: NSRange(location: 0, length: attributed.length)) { attrs, range, _ in
            let piece = full.substring(with: range)
            let font = attrs[.font] as? NSFont
            let size = font?.pointSize ?? maxSize
            let superscript = (attrs[.superscript] as? Int ?? 0) > 0
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            let isMarker = !trimmed.isEmpty && trimmed.allSatisfy { $0.isNumber || "*†‡".contains($0) }
            if isMarker, size < maxSize * 0.8 || superscript, !text.isEmpty {
                return  // Fußnotenverweis weglassen
            }
            text += piece
            for ch in piece where !ch.isWhitespace {
                sizeWeights[(size * 2).rounded() / 2, default: 0] += 1
                totalChars += 1
                if let font, isBold(font) { boldChars += 1 }
            }
        }
        let size = sizeWeights.max { $0.value < $1.value }?.key ?? fallbackSize
        let bold = totalChars > 0 && Double(boldChars) / Double(totalChars) > 0.6
        return (text, size, bold)
    }

    static func isBold(_ font: NSFont) -> Bool {
        if font.fontDescriptor.symbolicTraits.contains(.bold) { return true }
        let name = font.fontName.lowercased()
        return name.contains("bold") || name.contains("black") || name.contains("heavy") || name.contains("semibold")
    }
}
