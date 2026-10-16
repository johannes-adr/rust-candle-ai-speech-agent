import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Prüft, ob ein Wort in der Sprache des Dokuments bekannt ist (für die
/// Silbentrennung am Zeilenende). Austauschbar, damit Tests ohne Wörterbuch laufen.
public struct WordChecker: Sendable {
    /// Liefert true/false, wenn ein Wörterbuch für die Sprache da ist, sonst nil.
    public var isKnown: @Sendable (_ word: String, _ language: String?) -> Bool?

    public init(isKnown: @escaping @Sendable (String, String?) -> Bool?) {
        self.isKnown = isKnown
    }

    /// Standard: `NSSpellChecker` des Systems.
    public static let system = WordChecker { word, language in
        SystemSpellChecker.shared.isKnown(word, language: language)
    }

    /// Kein Wörterbuch: Der Aufrufer entscheidet nach Heuristik.
    public static let none = WordChecker { _, _ in nil }
}

/// Kapselt `NSSpellChecker` hinter einem Schloss (der Checker ist nicht für
/// parallelen Zugriff gedacht).
final class SystemSpellChecker: @unchecked Sendable {
    static let shared = SystemSpellChecker()
    private let lock = NSLock()

    func isKnown(_ word: String, language: String?) -> Bool? {
        #if canImport(AppKit)
        lock.lock()
        defer { lock.unlock() }
        let checker = NSSpellChecker.shared
        guard let language, let code = resolve(language, in: checker.availableLanguages) else { return nil }
        let range = checker.checkSpelling(
            of: word, startingAt: 0, language: code, wrap: false,
            inSpellDocumentWithTag: 0, wordCount: nil
        )
        return range.location == NSNotFound
        #else
        return nil
        #endif
    }

    /// Wählt aus den installierten Wörterbüchern eines, das mit „de“, „pt“ … beginnt.
    private func resolve(_ language: String, in available: [String]) -> String? {
        if let exact = available.first(where: { $0 == language }) { return exact }
        return available.first { $0.hasPrefix(language + "_") || $0.hasPrefix(language + "-") }
    }
}
