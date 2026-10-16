// Baut aus dem Wunsch die Anweisung für VoiceDesign (siehe docs/spikes/S3-stimme.md).
import Foundation
import TextPrep

/// Übersetzt einen Wunsch ins Englische (on-device). Gibt `nil` zurück, wenn es nicht geht
/// (Sprachpaket fehlt, Sprache nicht unterstützt); dann bleibt das Original.
public protocol DescriptionTranslating: Sendable {
    func translateToEnglish(_ text: String, from language: Language) async -> String?
}

/// Die fertige Anweisung samt Herkunft.
public struct VoicePrompt: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// Der Wunsch war schon Englisch.
        case english
        /// Übersetzt (Translation-Framework).
        case translated
        /// Konnte nicht übersetzt werden; das Original steht in der Anweisung.
        case original
        /// Unverändert vom Aufrufer (CLI `--raw`).
        case raw
    }

    public var text: String
    public var source: Source
    /// Der Wunsch auf Englisch bzw. im Original, wie er in `text` eingeflossen ist.
    public var wishText: String

    public init(text: String, source: Source, wishText: String) {
        self.text = text
        self.source = source
        self.wishText = wishText
    }
}

public enum VoicePromptBuilder {
    /// Satzbau nach den Vorgaben in `presets.json` („The voice of …, with a clear native German
    /// accent, speaking clearly.“). Der Wunsch der Nutzerin steht in der Mitte.
    public static func build(_ wish: VoiceWish, translator: (any DescriptionTranslating)?) async -> VoicePrompt {
        let original = wish.description.trimmingCharacters(in: .whitespacesAndNewlines)
        var wishText = original
        var source: VoicePrompt.Source = .original
        if wish.descriptionLanguage == .en {
            source = .english
        } else if let translator, let english = await translator.translateToEnglish(original, from: wish.descriptionLanguage ?? wish.readingLanguage),
                  !english.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            wishText = english.trimmingCharacters(in: .whitespacesAndNewlines)
            source = .translated
        }
        return VoicePrompt(text: assemble(wishText: wishText, wish: wish), source: source, wishText: wishText)
    }

    /// Nur der Zusammenbau (ohne Übersetzung); für Tests und Messungen.
    public static func assemble(wishText: String, wish: VoiceWish) -> String {
        var parts: [String] = []
        let who = [ageWord(wish.age), genderWord(wish.gender)].compactMap { $0 }.joined(separator: " ")
        if !who.isEmpty { parts.append("The voice of \(article(for: who)) \(who).") }
        parts.append(sentence(wishText))
        var accent = "A clear native \(englishName(wish.readingLanguage)) accent"
        if let region = wish.regionHint?.trimmingCharacters(in: .whitespacesAndNewlines), !region.isEmpty {
            accent += ", \(region)"
        }
        parts.append(accent + ", speaking clearly and naturally.")
        return parts.joined(separator: " ")
    }

    // MARK: Bausteine

    static func sentence(_ s: String) -> String {
        guard let last = s.last else { return s }
        return ".!?。！？".contains(last) ? s : s + "."
    }

    static func ageWord(_ a: VoiceAgeHint?) -> String? {
        switch a {
        case .young: "young"
        case .middleAged: "middle-aged"
        case .elderly: "elderly"
        case nil: nil
        }
    }

    static func genderWord(_ g: VoiceGender?) -> String? {
        switch g {
        case .female: "woman"
        case .male: "man"
        case nil: nil
        }
    }

    static func article(for phrase: String) -> String {
        guard let c = phrase.first else { return "a" }
        return "aeiou".contains(c) ? "an" : "a"
    }

    public static func englishName(_ l: Language) -> String {
        switch l {
        case .de: "German"
        case .pt: "Portuguese"
        case .en: "English"
        case .es: "Spanish"
        case .fr: "French"
        case .it: "Italian"
        case .ru: "Russian"
        case .zh: "Chinese"
        case .ja: "Japanese"
        case .ko: "Korean"
        }
    }
}
