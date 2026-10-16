// Manifest eines Vorlese-Projekts (`manifest.json`), versioniert über `schemaVersion`.
import AudioOut
import CryptoKit
import Foundation
import TextPrep

public enum ProjectState: String, Codable, Sendable, Equatable {
    case preparing, synthesizing, exporting, finished, failed
}

public enum ChunkStatus: String, Codable, Sendable, Equatable {
    case pending, done, suspicious, failed
}

/// Ein TextPrep-Abschnitt samt Zustand der Erzeugung.
public struct ProjectChunk: Codable, Sendable, Equatable {
    public var chunk: Chunk
    public var status: ChunkStatus
    public var attempts: Int
    /// Seed des letzten Versuchs.
    public var seed: UInt64?
    /// Audiodauer in Sekunden (nach QC-Trimmen).
    public var duration: Double?
    /// Rechenzeit des letzten erfolgreichen Versuchs, Grundlage der Restzeit-Schätzung.
    public var computeSeconds: Double?
    public var qc: ChunkQCReport?
    public var lastError: String?
    /// Seite im Quelldokument (0-basiert), falls bekannt.
    public var pageIndex: Int?

    public init(
        chunk: Chunk, status: ChunkStatus = .pending, attempts: Int = 0, seed: UInt64? = nil,
        duration: Double? = nil, computeSeconds: Double? = nil, qc: ChunkQCReport? = nil,
        lastError: String? = nil, pageIndex: Int? = nil
    ) {
        self.chunk = chunk
        self.status = status
        self.attempts = attempts
        self.seed = seed
        self.duration = duration
        self.computeSeconds = computeSeconds
        self.qc = qc
        self.lastError = lastError
        self.pageIndex = pageIndex
    }
}

public struct Project: Codable, Sendable, Equatable, Identifiable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// SHA-256 (hex) der Quelldatei bzw. des Texts.
    public var sourceHash: String
    /// Dateiname der Kopie im Projektordner (`source.pdf`) oder nil bei reinem Text ohne Datei.
    public var sourceFileName: String?
    public var sourceKind: String
    public var language: Language
    public var voiceID: String
    public var style: String?
    public var tempo: Double
    public var state: ProjectState
    public var chunks: [ProjectChunk]
    /// `true`, wenn die Zwischendateien (`chunks/`) bewusst gelöscht wurden („Aufräumen“ im Helfer-Fenster).
    /// Dann gilt ein fertiges Projekt weiter als fertig; die MP3 ist die einzige Kopie. Fehlt das Feld (alte
    /// Manifeste), ist es `nil` = nicht aufgeräumt.
    public var intermediatesRemoved: Bool?

    public init(
        id: UUID = UUID(), title: String, createdAt: Date = Date(), sourceHash: String,
        sourceFileName: String? = nil, sourceKind: String, language: Language, voiceID: String,
        style: String? = nil, tempo: Double = 1.0, state: ProjectState = .preparing,
        chunks: [ProjectChunk]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.sourceHash = sourceHash
        self.sourceFileName = sourceFileName
        self.sourceKind = sourceKind
        self.language = language
        self.voiceID = voiceID
        self.style = style
        self.tempo = tempo
        self.state = state
        self.chunks = chunks
    }

    /// Summe der Dauer aller vorhandenen Abschnitte.
    public var totalDuration: Double {
        chunks.compactMap { $0.status == .failed ? nil : $0.duration }.reduce(0, +)
    }

    public var isComplete: Bool { chunks.allSatisfy { $0.status == .done || $0.status == .suspicious } }
}

public enum SourceHash {
    public static func hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    public static func hex(of text: String) -> String { hex(of: Data(text.utf8)) }
}

/// Deterministischer Seed je (Projekt, Abschnitt, Versuch).
public enum SeedDerivation {
    public static func seed(projectID: UUID, chunkIndex: Int, attempt: Int) -> UInt64 {
        var data = Data(projectID.uuidString.lowercased().utf8)
        data.append(contentsOf: "|\(chunkIndex)|\(attempt)".utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
