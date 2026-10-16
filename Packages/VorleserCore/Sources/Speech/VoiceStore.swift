// Fertige Stimmen aus `Resources/Voices`: `presets.json` plus je Stimme und Stil
// `<id>-<stil>.caf` (ALAC) mit dem Wortlaut in `<id>-<stil>.txt`.
import Foundation
import TextPrep

/// Eine fertige Stimme aus `presets.json`.
public struct VoicePreset: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var language: Language
    public var isFemale: Bool
    /// Kurzbeschreibung für die Oberfläche je Oberflächensprache ("de", "pt").
    public var descriptions: [String: String]
    /// Englische Beschreibung für VoiceDesign (`vorleser-cli design-presets`), ohne Stil.
    public var design: String?
    /// Dateiname der Referenz je Stil.
    public var references: [String: String]

    public func description(for uiLanguage: String) -> String {
        descriptions[uiLanguage] ?? descriptions["de"] ?? ""
    }
}

public struct VoiceStore: Sendable {
    /// Ordner mit `presets.json` und den Referenzaufnahmen.
    public let directory: URL
    /// Reihenfolge der Stile laut `presets.json`.
    public let styles: [String]
    /// Englische Stilbeschreibung für VoiceDesign.
    public let styleDesign: [String: String]
    private let byLanguage: [Language: [VoicePreset]]
    /// Eigene (aufgenommene/importierte) Stimmen; `nil` = nur eingebaute Stimmen.
    public let custom: RecordedVoiceStore?

    public init(directory: URL, customDirectory: URL? = nil) {
        self.directory = directory
        self.custom = customDirectory.map { RecordedVoiceStore(directory: $0) }
        let parsed = Self.parse(directory.appending(path: "presets.json"))
        self.styles = parsed.styles
        self.styleDesign = parsed.styleDesign
        self.byLanguage = parsed.voices
    }

    /// Sucht `Voices/presets.json`: Umgebung `VORLESER_VOICES_DIR`, App-Paket, dann von
    /// Arbeitsordner und Programmpfad aufwärts nach `Resources/Voices`.
    public static func locateDefault(bundle: Bundle = .main) -> VoiceStore? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["VORLESER_VOICES_DIR"] {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        if let res = bundle.resourceURL { candidates.append(res.appending(path: "Voices", directoryHint: .isDirectory)) }
        var starts = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let exe = Bundle.main.executableURL { starts.append(exe.deletingLastPathComponent()) }
        for start in starts {
            var dir = start
            for _ in 0..<10 {
                candidates.append(dir.appending(path: "Resources/Voices", directoryHint: .isDirectory))
                dir = dir.deletingLastPathComponent()
            }
        }
        for c in candidates where FileManager.default.fileExists(atPath: c.appending(path: "presets.json").path) {
            return VoiceStore(directory: c, customDirectory: RecordedVoiceStore.defaultDirectory)
        }
        return nil
    }

    // MARK: Abfragen

    public var allPresets: [VoicePreset] {
        Language.allCases.flatMap { byLanguage[$0] ?? [] }
    }

    public func presets(for language: Language) -> [VoicePreset] { byLanguage[language] ?? [] }

    public func preset(id: String) -> VoicePreset? { allPresets.first { $0.id == id } }

    /// Pfad der Referenz, nur wenn die Datei wirklich da ist.
    public func referenceURL(voiceID: String, style: String) -> URL? {
        guard let name = preset(id: voiceID)?.references[style] else { return nil }
        let url = directory.appending(path: name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Wortlaut der Referenz aus der gleichnamigen `.txt`.
    public func referenceText(voiceID: String, style: String) -> String? {
        guard let name = preset(id: voiceID)?.references[style] else { return nil }
        let url = directory.appending(path: name).deletingPathExtension().appendingPathExtension("txt")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Stile, für die Audio und Text wirklich vorhanden sind.
    public func availableStyles(voiceID: String) -> [String] {
        styles.filter { referenceURL(voiceID: voiceID, style: $0) != nil && referenceText(voiceID: voiceID, style: $0) != nil }
    }

    /// Baut die `Voice` für die Engine. Fehlt der Stil, nimmt `fallback` einen vorhandenen
    /// (bevorzugt `calm`); sonst `nil`. Ohne Stilangabe gilt dasselbe.
    public func voice(id: String, style: String?, fallback: Bool = false) -> Voice? {
        // Eigene Stimmen haben nur eine Referenz; der Stil spielt keine Rolle (Base ignoriert ihn ohnehin).
        if id.hasPrefix(RecordedVoiceStore.idPrefix) { return custom?.voice(id: id) }
        guard let preset = preset(id: id) else { return nil }
        let available = availableStyles(voiceID: id)
        var chosen = style.flatMap { available.contains($0) ? $0 : nil }
        if chosen == nil, fallback || style == nil {
            chosen = available.contains("calm") ? "calm" : available.first
        }
        guard let s = chosen, let url = referenceURL(voiceID: id, style: s),
              let text = referenceText(voiceID: id, style: s) else { return nil }
        return Voice(
            id: id, name: preset.name, language: preset.language, kind: .preset,
            referenceAudio: url, referenceText: text, description: preset.design)
    }

    /// Eigene Stimmen einer Sprache (leer ohne `custom`).
    public func recordedVoices(for language: Language) -> [RecordedVoiceInfo] {
        custom?.list(language: language) ?? []
    }

    // MARK: Datei lesen

    private struct File: Decodable {
        struct VoiceEntry: Decodable {
            var id: String
            var name: String
            var gender: String
            var description: [String: String]
            var design: String?
            var reference: [String: String]
        }
        struct Lang: Decodable { var voices: [VoiceEntry] }
        var styles: [String]?
        var styleDesign: [String: String]?
        var languages: [String: Lang]
    }

    private static func parse(_ url: URL) -> (styles: [String], styleDesign: [String: String], voices: [Language: [VoicePreset]]) {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(File.self, from: data)
        else { return ([], [:], [:]) }
        var out: [Language: [VoicePreset]] = [:]
        for (code, lang) in file.languages {
            guard let language = Language(rawValue: code) else { continue }
            out[language] = lang.voices.map {
                VoicePreset(
                    id: $0.id, name: $0.name, language: language, isFemale: $0.gender == "f",
                    descriptions: $0.description, design: $0.design, references: $0.reference)
            }
        }
        return (file.styles ?? [], file.styleDesign ?? [:], out)
    }
}
