import Foundation
import NaturalLanguage

/// Kleine Textwerkzeuge, die Importer und Bereinigung gemeinsam nutzen.
enum TextHelpers {
    static let terminalPunctuation: Set<Character> = [".", "!", "?", "…", "。", "！", "？", "”", "»", "\"", "“", ")"]

    /// Ersetzt Ligaturen, Sonderleerzeichen und Steuerzeichen; trimmt.
    static func normalize(_ raw: String) -> String {
        var s = raw
        let map: [(String, String)] = [
            ("\u{FB00}", "ff"), ("\u{FB01}", "fi"), ("\u{FB02}", "fl"), ("\u{FB03}", "ffi"), ("\u{FB04}", "ffl"),
            ("\u{00A0}", " "), ("\u{2009}", " "), ("\u{202F}", " "), ("\u{200B}", ""), ("\u{FEFF}", ""),
            ("\t", " "), ("\r", " "), ("\n", " "), ("\u{2028}", " "),
        ]
        for (a, b) in map where s.contains(a) { s = s.replacingOccurrences(of: a, with: b) }
        while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func endsWithTerminalPunctuation(_ s: String) -> Bool {
        guard let c = s.trimmingCharacters(in: .whitespaces).last else { return false }
        return terminalPunctuation.contains(c)
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3000...0x9FFF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0xFF00...0xFFEF).contains(v)
    }

    static func letterCount(_ s: String) -> Int { s.reduce(0) { $0 + ($1.isLetter ? 1 : 0) } }

    /// Sprache des Textes (nur die 10 Qwen-Sprachen), als Kürzel wie „de“.
    static func detectLanguage(_ text: String) -> String? {
        let sample = String(text.prefix(20_000))
        guard letterCount(sample) >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [
            .german, .portuguese, .english, .spanish, .french, .italian, .russian,
            .simplifiedChinese, .traditionalChinese, .japanese, .korean,
        ]
        recognizer.processString(sample)
        guard let lang = recognizer.dominantLanguage else { return nil }
        switch lang {
        case .simplifiedChinese, .traditionalChinese: return "zh"
        default: return lang.rawValue
        }
    }
}
