// Beschriebene Stimmen (Phase 4, „Design → Klon“): VoiceDesign erzeugt einmal eine Referenz,
// danach klont Base diese Referenz für jeden Abschnitt. Hier wird die Referenz gespeichert.
//
// Ablage in `~/Library/Application Support/Vorleser/Voices/` (gemeinsam mit den eigenen
// Aufnahmen, Phase 3): je Stimme `<id>.caf` (ALAC), `<id>.txt` (Wortlaut) und `<id>.json`
// (Metadaten, Feld `kind`). Diese Klasse liest und schreibt nur Einträge mit `kind == "designed"`.
import Foundation
import TextPrep

/// Metadaten einer beschriebenen Stimme (`<id>.json`).
public struct DesignedVoiceInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var language: Language
    /// Immer `"designed"`; die eigenen Aufnahmen (Phase 3) schreiben dort `"recorded"`.
    public var kind: String
    /// Der Wunsch der Nutzerin, so wie geschrieben.
    public var description: String
    /// Die tatsächlich an VoiceDesign gegebene Anweisung (für Nachvollziehbarkeit).
    public var prompt: String?
    public var seed: UInt64?
    public var created: Date

    public init(
        id: String, name: String, language: Language, description: String, prompt: String? = nil,
        seed: UInt64? = nil, created: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.kind = DesignedVoiceStore.kind
        self.description = description
        self.prompt = prompt
        self.seed = seed
        self.created = created
    }
}

public struct DesignedVoiceStore: Sendable {
    public static let kind = "designed"
    public static let idPrefix = "designed-"

    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Application Support/Vorleser/Voices/` (Umgebung `VORLESER_DATA_DIR` hat Vorrang,
    /// dann liegt es unter `<VORLESER_DATA_DIR>/Voices`).
    public static var defaultDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["VORLESER_DATA_DIR"] {
            return URL(fileURLWithPath: env, isDirectory: true).appending(path: "Voices", directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Vorleser/Voices", directoryHint: .isDirectory)
    }

    public static var standard: DesignedVoiceStore { DesignedVoiceStore(directory: defaultDirectory) }

    public static func isDesignedID(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    // MARK: Speichern

    /// Speichert die Referenz als ALAC-CAF samt Text und Metadaten und gibt die fertige `Voice` zurück.
    /// Die `.json` kommt zuletzt, damit ein Abbruch nie eine halbe Stimme in der Liste hinterlässt.
    @discardableResult
    public func save(
        samples: [Float], sampleRate: Double, name: String, language: Language, description: String,
        referenceText: String, prompt: String? = nil, seed: UInt64? = nil, id: String? = nil,
        now: Date = Date()
    ) throws -> Voice {
        let voiceID = id ?? Self.idPrefix + UUID().uuidString.prefix(8).lowercased()
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let info = DesignedVoiceInfo(
            id: voiceID, name: cleanName.isEmpty ? description : cleanName, language: language,
            description: description, prompt: prompt, seed: seed, created: now)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try ReferenceFiles.writeALAC(samples, sampleRate: sampleRate, to: url(voiceID, "caf"))
        try referenceText.write(to: url(voiceID, "txt"), atomically: true, encoding: .utf8)
        try write(info)
        return voice(from: info)
    }

    // MARK: Lesen

    /// Alle beschriebenen Stimmen, neueste zuerst. Unvollständige Einträge (ohne Audio) fehlen.
    public func list() -> [Voice] {
        infos().compactMap { info in
            FileManager.default.fileExists(atPath: url(info.id, "caf").path) ? voice(from: info) : nil
        }
    }

    public func voices(for language: Language) -> [Voice] { list().filter { $0.language == language } }

    public func voice(id: String) -> Voice? { list().first { $0.id == id } }

    public func info(id: String) -> DesignedVoiceInfo? { infos().first { $0.id == id } }

    // MARK: Ändern

    public func rename(id: String, to name: String) throws {
        guard var info = info(id: id) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        info.name = clean
        try write(info)
    }

    public func delete(id: String) {
        for ext in ["json", "caf", "txt"] { try? FileManager.default.removeItem(at: url(id, ext)) }
    }

    // MARK: Intern

    private func url(_ id: String, _ ext: String) -> URL { directory.appending(path: "\(id).\(ext)") }

    private func write(_ info: DesignedVoiceInfo) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(info).write(to: url(info.id, "json"), options: .atomic)
    }

    private func infos() -> [DesignedVoiceInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = try? Data(contentsOf: directory.appending(path: name)),
                  let info = try? dec.decode(DesignedVoiceInfo.self, from: data),
                  info.kind == Self.kind else { return nil }
            return info
        }.sorted { $0.created > $1.created }
    }

    private func voice(from info: DesignedVoiceInfo) -> Voice {
        let text = (try? String(contentsOf: url(info.id, "txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Voice(
            id: info.id, name: info.name, language: info.language, kind: .designed,
            referenceAudio: url(info.id, "caf"), referenceText: text, description: info.description)
    }
}
