// Fertige Stimmen aus Resources/Voices/presets.json (vorläufig, siehe Hinweis dort).
import Foundation
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

struct VoiceLibrary: Sendable {
    /// Ordner mit presets.json und den Referenzaufnahmen.
    let directory: URL
    private let voices: [Language: [PresetVoice]]

    init(directory: URL? = Bundle.main.resourceURL?.appending(path: "Voices", directoryHint: .isDirectory)) {
        let dir = directory ?? URL(fileURLWithPath: "/nonexistent")
        self.directory = dir
        self.voices = Self.load(from: dir.appending(path: "presets.json"))
    }

    func voices(for language: Language) -> [PresetVoice] { voices[language] ?? [] }

    func voice(id: String) -> PresetVoice? { voices.values.joined().first { $0.id == id } }

    /// Pfad der Referenzaufnahme, nur wenn die Datei wirklich da ist.
    func referenceURL(voiceID: String, style: String) -> URL? {
        guard let name = voice(id: voiceID)?.references[style] else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private struct File: Decodable {
        struct Voice: Decodable {
            var id: String
            var name: String
            var gender: String
            var description: [String: String]
            var reference: [String: String]
        }
        struct Lang: Decodable { var voices: [Voice] }
        var languages: [String: Lang]
    }

    private static func load(from url: URL) -> [Language: [PresetVoice]] {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return [:] }
        var out: [Language: [PresetVoice]] = [:]
        for (code, lang) in file.languages {
            guard let language = Language(rawValue: code) else { continue }
            out[language] = lang.voices.map {
                PresetVoice(
                    id: $0.id, name: $0.name, isFemale: $0.gender == "f", descriptions: $0.description,
                    references: $0.reference)
            }
        }
        return out
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
