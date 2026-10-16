import AppKit
import Foundation
import PDFKit

/// Liest Zeilen mit Position, Schriftgröße und Fettdruck aus einer PDF-Seite (PDFKit).
enum PDFLineExtractor {
    /// Zeilen einer Seite aus der Textebene. Leer, wenn die Seite keinen Text hat.
    static func lines(of page: PDFPage, index: Int) -> [PageLine] {
        let bounds = page.bounds(for: .cropBox)
        guard let selection = page.selection(for: bounds) else { return [] }
        var result: [PageLine] = []
        for line in selection.selectionsByLine() {
            let rect = line.bounds(for: page)
            guard rect.width > 0, rect.height > 0 else { continue }
            let (text, size, bold) = analyze(line.attributedString, fallbackSize: rect.height * 0.85)
            let clean = TextHelpers.normalize(text)
            guard !clean.isEmpty else { continue }
            result.append(PageLine(clean, rect: rect, fontSize: size, isBold: bold, page: index))
        }
        return result
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
            let superscript = (attrs[.superscript] as? Int ?? 0) > 0 || (attrs[NSAttributedString.Key("NSSuperScript")] as? Int ?? 0) > 0
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
