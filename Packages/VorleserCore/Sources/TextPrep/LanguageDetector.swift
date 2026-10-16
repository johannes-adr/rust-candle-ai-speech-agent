import Foundation
import NaturalLanguage

/// Ergebnis der Spracherkennung.
public struct LanguageDetection: Sendable, Equatable {
    public var language: Language
    /// Wahrscheinlichkeit der besten Sprache (0…1).
    public var confidence: Double
    /// Abstand zur zweitbesten Sprache.
    public var margin: Double
    /// Alle Kandidaten.
    public var candidates: [Language: Double]
    /// Wahr, wenn der Nutzer gefragt werden sollte.
    public var isUncertain: Bool
}

/// Erkennt die Sprache eines Textes, beschränkt auf die zehn Qwen-Sprachen.
public struct LanguageDetector: Sendable {
    public var minConfidence: Double
    public var minMargin: Double
    /// Nur so viele Zeichen werden ausgewertet (Geschwindigkeit bei langen Dokumenten).
    public var sampleLimit: Int

    public init(minConfidence: Double = 0.6, minMargin: Double = 0.25, sampleLimit: Int = 20_000) {
        self.minConfidence = minConfidence
        self.minMargin = minMargin
        self.sampleLimit = sampleLimit
    }

    /// `nil`, wenn nichts erkannt wurde (leerer Text, nur Zahlen).
    public func detect(_ text: String) -> LanguageDetection? {
        let sample = String(text.prefix(sampleLimit))
        guard sample.contains(where: { $0.isLetter }) else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = Language.allCases.map { $0.nlLanguage }
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: 10)
        var candidates: [Language: Double] = [:]
        for (nl, p) in hypotheses {
            if let l = Language(nlLanguage: nl) { candidates[l, default: 0] += p }
        }
        let ranked = candidates.sorted { $0.value > $1.value }
        guard let best = ranked.first else { return nil }
        let second = ranked.dropFirst().first?.value ?? 0
        let margin = best.value - second
        return LanguageDetection(
            language: best.key,
            confidence: best.value,
            margin: margin,
            candidates: candidates,
            isUncertain: best.value < minConfidence || margin < minMargin
        )
    }
}

extension Language {
    var nlLanguage: NLLanguage {
        switch self {
        case .de: .german
        case .pt: .portuguese
        case .en: .english
        case .es: .spanish
        case .fr: .french
        case .it: .italian
        case .ru: .russian
        case .zh: .simplifiedChinese
        case .ja: .japanese
        case .ko: .korean
        }
    }

    init?(nlLanguage: NLLanguage) {
        switch nlLanguage {
        case .german: self = .de
        case .portuguese: self = .pt
        case .english: self = .en
        case .spanish: self = .es
        case .french: self = .fr
        case .italian: self = .it
        case .russian: self = .ru
        case .simplifiedChinese, .traditionalChinese: self = .zh
        case .japanese: self = .ja
        case .korean: self = .ko
        default: return nil
        }
    }
}
