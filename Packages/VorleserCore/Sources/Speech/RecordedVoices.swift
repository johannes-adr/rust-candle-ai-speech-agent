// Eigene (aufgenommene oder importierte) Stimmen. Liegen NICHT im Repo, sondern unter
// `~/Library/Application Support/Vorleser/Voices/`: je Stimme `<id>.caf` (ALAC), `<id>.txt`
// (Wortlaut) und `<id>.json` (Metadaten). Speichern geht nur mit Zustimmung (consent).
import Foundation
import TextPrep

public struct RecordedVoiceInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: String
    public var name: String
    public var language: Language
    public var kind: VoiceKind
    public var createdAt: Date
    /// „Das ist meine Stimme oder ich habe die Erlaubnis“ – ohne `true` wird nichts gespeichert oder geladen.
    public var consent: Bool
    public var consentAt: Date
    /// "recording" (Mikrofon) oder "import" (Datei).
    public var source: String
    public var durationSeconds: Double
    /// "reading" (fester Lesetext), "provided" oder "recognized".
    public var transcriptSource: String
    /// Nur bei beschriebenen Stimmen (`kind == .designed`): der Wunsch, die VoiceDesign-Anweisung und der Seed.
    public var wish: String? = nil
    public var prompt: String? = nil
    public var seed: UInt64? = nil
}

public enum RecordedVoiceError: Error, Sendable, Equatable, CustomStringConvertible {
    case consentMissing
    case emptyAudio
    case emptyTranscript
    case notFound(String)

    public var description: String {
        switch self {
        case .consentMissing: "Ohne Zustimmung wird keine eigene Stimme gespeichert."
        case .emptyAudio: "Die Aufnahme ist leer."
        case .emptyTranscript: "Zur Aufnahme fehlt der Text."
        case .notFound(let id): "Stimme \(id) gibt es nicht."
        }
    }
}

public struct RecordedVoiceStore: Sendable {
    public let directory: URL

    public init(directory: URL = RecordedVoiceStore.defaultDirectory) {
        self.directory = directory
    }

    /// `VORLESER_CUSTOM_VOICES_DIR` (Entwicklung/Tests), sonst Application Support/Vorleser/Voices.
    public static var defaultDirectory: URL {
        if let env = ProcessInfo.processInfo.environment["VORLESER_CUSTOM_VOICES_DIR"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return URL.applicationSupportDirectory.appending(path: "Vorleser/Voices", directoryHint: .isDirectory)
    }

    public static let idPrefix = "own-"

    // MARK: Pfade

    public func audioURL(id: String) -> URL { directory.appending(path: "\(id).caf") }
    public func textURL(id: String) -> URL { directory.appending(path: "\(id).txt") }
    public func metadataURL(id: String) -> URL { directory.appending(path: "\(id).json") }

    // MARK: Speichern

    /// Speichert eine Stimme. `consent` muss `true` sein.
    /// - Parameters:
    ///   - samples/sampleRate: bereinigte Aufnahme (mono), wird als ALAC gespeichert.
    ///   - transcript: Wortlaut (bei Aufnahme der feste Lesetext).
    @discardableResult
    public func save(
        samples: [Float], sampleRate: Double, transcript: String, name: String, language: Language,
        consent: Bool, source: String, transcriptSource: String, now: Date = Date()
    ) throws -> Voice {
        guard consent else { throw RecordedVoiceError.consentMissing }
        guard !samples.isEmpty, sampleRate > 0 else { throw RecordedVoiceError.emptyAudio }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RecordedVoiceError.emptyTranscript }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Self.idPrefix + UUID().uuidString.lowercased().prefix(8)
        let info = RecordedVoiceInfo(
            id: id, name: trimmedName.isEmpty ? "Meine Stimme" : String(trimmedName.prefix(40)),
            language: language, kind: .recorded, createdAt: now, consent: true, consentAt: now,
            source: source, durationSeconds: Double(samples.count) / sampleRate, transcriptSource: transcriptSource)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try ReferenceFiles.writeALAC(samples, sampleRate: sampleRate, to: audioURL(id: id))
            try text.write(to: textURL(id: id), atomically: true, encoding: .utf8)
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            // Die Metadaten zuletzt: erst damit gilt die Stimme als vorhanden.
            try enc.encode(info).write(to: metadataURL(id: id), options: .atomic)
        } catch {
            for url in [audioURL(id: id), textURL(id: id), metadataURL(id: id)] { try? FileManager.default.removeItem(at: url) }
            throw error
        }
        return makeVoice(info, text: text)
    }

    // MARK: Laden

    /// Alle Stimmen mit Zustimmung und vollständigen Dateien, neueste zuletzt.
    public func list() -> [RecordedVoiceInfo] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return names.filter { $0.hasPrefix(Self.idPrefix) && $0.hasSuffix(".json") }
            .compactMap { file -> RecordedVoiceInfo? in
                guard let data = try? Data(contentsOf: directory.appending(path: file)),
                      let info = try? dec.decode(RecordedVoiceInfo.self, from: data), info.consent,
                      FileManager.default.fileExists(atPath: audioURL(id: info.id).path),
                      FileManager.default.fileExists(atPath: textURL(id: info.id).path)
                else { return nil }
                return info
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func list(language: Language) -> [RecordedVoiceInfo] { list().filter { $0.language == language } }

    public func info(id: String) -> RecordedVoiceInfo? { list().first { $0.id == id } }

    /// Die Stimme für die Engine (Audio plus Wortlaut).
    public func voice(id: String) -> Voice? {
        guard let info = info(id: id),
              let text = try? String(contentsOf: textURL(id: id), encoding: .utf8) else { return nil }
        return makeVoice(info, text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func makeVoice(_ info: RecordedVoiceInfo, text: String) -> Voice {
        Voice(id: info.id, name: info.name, language: info.language, kind: info.kind,
              referenceAudio: audioURL(id: info.id), referenceText: text, description: info.wish)
    }

    // MARK: Ändern und Löschen

    public func rename(id: String, to name: String) throws {
        guard var info = info(id: id) else { throw RecordedVoiceError.notFound(id) }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        info.name = String(n.prefix(40))
        try write(info)
    }

    /// Schreibt die Metadaten (atomar).
    func write(_ info: RecordedVoiceInfo) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(info).write(to: metadataURL(id: info.id), options: .atomic)
    }

    /// Löscht die Stimme endgültig. Die App fragt vorher nach und bietet das nur im Helfer-Fenster an.
    public func delete(id: String) throws {
        guard id.hasPrefix(Self.idPrefix), FileManager.default.fileExists(atPath: metadataURL(id: id).path) else {
            throw RecordedVoiceError.notFound(id)
        }
        // Metadaten zuerst: danach gilt die Stimme sofort als weg, auch wenn der Rest hakt.
        for url in [metadataURL(id: id), audioURL(id: id), textURL(id: id)] { try? FileManager.default.removeItem(at: url) }
    }
}
