// Fertige Stimmen aus Resources/Voices/presets.json (gelesen vom VoiceStore im Package).
import Foundation
import VorleserSpeech
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

    init(
        directory: URL? = Bundle.main.resourceURL?.appending(path: "Voices", directoryHint: .isDirectory),
        customDirectory: URL = VoiceLibrary.defaultCustomDirectory
    ) {
        self.store = VoiceStore(directory: directory ?? URL(fileURLWithPath: "/nonexistent"), customDirectory: customDirectory)
    }

    /// Eigene Stimmen liegen in Application Support (nicht im Paket). Debug: unter `VORLESER_DATA_DIR/Voices`.
    static var defaultCustomDirectory: URL {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let dir = env["VORLESER_DATA_DIR"], env["VORLESER_CUSTOM_VOICES_DIR"] == nil {
            return URL(fileURLWithPath: dir, isDirectory: true).appending(path: "Voices", directoryHint: .isDirectory)
        }
        #endif
        return RecordedVoiceStore.defaultDirectory
    }

    /// Eigene (aufgenommene) Stimmen der Sprache, für Schritt ②.
    func recordedVoices(for language: Language) -> [PresetVoice] {
        store.recordedVoices(for: language).map(Self.convert)
    }

    func voices(for language: Language) -> [PresetVoice] {
        store.presets(for: language).map(Self.convert)
    }

    func voice(id: String) -> PresetVoice? {
        if let own = store.custom?.info(id: id) { return Self.convert(own) }
        return store.preset(id: id).map(Self.convert)
    }

    /// Pfad der Referenzaufnahme, nur wenn die Datei wirklich da ist.
    func referenceURL(voiceID: String, style: String) -> URL? {
        // Eigene Stimmen haben nur eine Aufnahme, unabhängig vom Stil.
        if let own = store.custom?.info(id: voiceID) { return store.custom?.audioURL(id: own.id) }
        return store.referenceURL(voiceID: voiceID, style: style)
    }

    private static func convert(_ r: RecordedVoiceInfo) -> PresetVoice {
        PresetVoice(id: r.id, name: r.name, isFemale: false, descriptions: [:], references: [:])
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
