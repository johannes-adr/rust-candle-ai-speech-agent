// Fertige Stimmen aus Resources/Voices/presets.json (gelesen vom VoiceStore im Package).
import Foundation
import Speech
import TextPrep

enum VoiceStyle: String, CaseIterable, Sendable, Identifiable {
    case calm, happy, fairytale, factual
    var id: String { rawValue }
    /// Schlüssel in Localizable.xcstrings
    var titleKey: String { "style.\(rawValue)" }
    var symbol: String {
        switch self {
        case .calm: "leaf"
        case .happy: "sun.max"
        case .fairytale: "book"
        case .factual: "doc.text"
        }
    }
}

struct PresetVoice: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var isFemale: Bool
    /// Kurzbeschreibung je Oberflächensprache ("de", "pt").
    var descriptions: [String: String]
    /// Dateiname der Referenz je Stil.
    var references: [String: String]

    func description(for uiLanguage: String) -> String {
        descriptions[uiLanguage] ?? descriptions["de"] ?? ""
    }
}

/// Dünne Hülle um `VoiceStore` (Package `Speech`): dieselbe Quelle für Oberfläche und Engine.
struct VoiceLibrary: Sendable {
    let store: VoiceStore
    /// Ordner mit presets.json und den Referenzaufnahmen.
    var directory: URL { store.directory }

    init(directory: URL? = Bundle.main.resourceURL?.appending(path: "Voices", directoryHint: .isDirectory)) {
        self.store = VoiceStore(directory: directory ?? URL(fileURLWithPath: "/nonexistent"))
    }

    func voices(for language: Language) -> [PresetVoice] {
        store.presets(for: language).map(Self.convert)
    }

    func voice(id: String) -> PresetVoice? { store.preset(id: id).map(Self.convert) }

    /// Pfad der Referenzaufnahme, nur wenn die Datei wirklich da ist.
    func referenceURL(voiceID: String, style: String) -> URL? {
        store.referenceURL(voiceID: voiceID, style: style)
    }

    private static func convert(_ p: VoicePreset) -> PresetVoice {
        PresetVoice(id: p.id, name: p.name, isFemale: p.isFemale, descriptions: p.descriptions, references: p.references)
    }
}

/// Fester Lesetext für die eigene Aufnahme (Phase 3), je Sprache.
enum ReadAloudText {
    static func text(for language: Language, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.resourceURL?.appending(path: "ReadAloud/\(language.rawValue).txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
