// Übersetzt den Wunsch mit dem Translation-Framework (on-device, kein Netz) ins Englische.
// Nur wenn das Sprachpaket schon installiert ist; es wird nie etwas nachgeladen oder gefragt.
import Foundation
import TextPrep
import Translation

public struct SystemDescriptionTranslator: DescriptionTranslating {
    public init() {}

    public func translateToEnglish(_ text: String, from language: Language) async -> String? {
        let source = Locale.Language(identifier: language.rawValue)
        let target = Locale.Language(identifier: "en")
        guard source.minimalIdentifier != target.minimalIdentifier else { return text }
        let availability = LanguageAvailability()
        guard await availability.status(from: source, to: target) == .installed else { return nil }
        do {
            let session = TranslationSession(installedSource: source, target: target)
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            return nil
        }
    }

    /// Ist das Sprachpaket für diese Sprache nach Englisch installiert?
    public static func isInstalled(_ language: Language) async -> Bool {
        if language == .en { return true }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: language.rawValue), to: Locale.Language(identifier: "en"))
        return status == .installed
    }
}
