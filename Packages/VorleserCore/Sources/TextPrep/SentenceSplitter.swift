import Foundation
import NaturalLanguage

/// Teilt Text in Sätze: `NLTokenizer(.sentence)` plus Korrekturen für
/// Abkürzungen („z. B.“, „Dr.“), Ordnungszahlen („am 3. Mai“) und Initialen.
public struct SentenceSplitter: Sendable {
    public init() {}

    public func split(_ text: String, language: Language) -> [String] {
        let raw = tokenize(text, language: language)
        guard !language.isCJK else { return raw }
        var result: [String] = []
        for sentence in raw {
            if let prev = result.last, shouldMerge(prev: prev, next: sentence, language: language) {
                result[result.count - 1] = prev + " " + sentence
            } else {
                result.append(sentence)
            }
        }
        return result
    }

    private func tokenize(_ text: String, language: Language) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(language.nlLanguage)
        var out: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out
    }

    private func shouldMerge(prev: String, next: String, language: Language) -> Bool {
        let startsLower = next.first.map { $0.isLowercase } ?? false
        // Kleingeschrieben weiter: war kein Satzende.
        if startsLower { return true }
        // Abkürzung am Ende des vorigen „Satzes“.
        for abbr in Abbreviations.list(for: language) {
            let pattern = #"(?<![\p{L}\p{N}])"# + Abbreviations.pattern(for: abbr) + "$"
            if prev.matches(pattern, .caseInsensitive) {
                // „usw.“ / „etc.“ beenden den Satz, wenn danach ein Großbuchstabe folgt.
                return !abbr.mayEndSentence
            }
        }
        // Deutsch: „am 3. Mai“, „1. Platz“ – Zahl mit Punkt ist eine Ordnungszahl.
        if language == .de, prev.matches(#"(?:^|\s)\d{1,2}\.$"#) { return true }
        // Initialen („J. Smith“).
        if prev.matches(#"(?<![\p{L}])\p{Lu}\.$"#) { return true }
        return false
    }
}
