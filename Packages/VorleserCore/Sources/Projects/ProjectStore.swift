// Ablage der Projekte: ein Ordner je Projekt mit manifest.json, chunks/ und source.<ext>.
import AVFoundation
import AudioOut
import Foundation
import TextPrep

public enum ProjectStoreError: Error, Sendable, Equatable {
    case notFound(UUID)
    case chunkOutOfRange(Int)
    case unsupportedSchema(Int)
}

/// Eintrag für „Meine Hörbücher“.
public struct ProjectSummary: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var title: String
    public var duration: Double
    public var updatedAt: Date
    public var state: ProjectState
    public var progress: Double
}

public actor ProjectStore {
    public nonisolated let rootDirectory: URL
    /// Ablageordner für fertige MP3-Dateien (getrennt von den Projektordnern).
    public nonisolated let outputDirectory: URL

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Vorleser/Projects", directoryHint: .isDirectory)
    }
    public static var defaultOutputDirectory: URL {
        URL.musicDirectory.appending(path: "Vorgelesen", directoryHint: .isDirectory)
    }

    private var cache: [UUID: Project] = [:]

    public init(root: URL = ProjectStore.defaultRoot, outputDirectory: URL = ProjectStore.defaultOutputDirectory) {
        self.rootDirectory = root
        self.outputDirectory = outputDirectory
    }

    // MARK: Pfade

    public nonisolated func directory(for id: UUID) -> URL {
        rootDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    public nonisolated func manifestURL(for id: UUID) -> URL {
        directory(for: id).appending(path: "manifest.json")
    }
    public nonisolated func chunkStore(for id: UUID) -> ChunkStore {
        ChunkStore(directory: directory(for: id).appending(path: "chunks", directoryHint: .isDirectory))
    }
    /// Zieldatei der MP3 (Dateiname aus dem Titel, ohne verbotene Zeichen).
    public nonisolated func outputURL(title: String) -> URL {
        let bad = CharacterSet(charactersIn: "/:\\?*\"<>|").union(.controlCharacters)
        var name = title.components(separatedBy: bad).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { name = "Vorgelesen" }
        return outputDirectory.appending(path: String(name.prefix(120)) + ".mp3")
    }

    // MARK: Anlegen, Laden, Speichern

    /// Legt ein Projekt an. `sourceData` (z. B. die PDF) wird als `source.<ext>` mitgespeichert.
    public func create(
        title: String, sourceHash: String, sourceKind: String, sourceData: Data? = nil,
        sourceExtension: String? = nil, language: Language, voiceID: String, style: String? = nil,
        tempo: Double = 1.0, chunks: [Chunk], pageIndices: [Int?]? = nil
    ) throws -> Project {
        let wrapped = chunks.enumerated().map { i, c in
            ProjectChunk(chunk: c, pageIndex: pageIndices.flatMap { i < $0.count ? $0[i] : nil })
        }
        var project = Project(
            title: title, sourceHash: sourceHash, sourceKind: sourceKind, language: language,
            voiceID: voiceID, style: style, tempo: tempo, chunks: wrapped)
        let dir = directory(for: project.id)
        try FileManager.default.createDirectory(
            at: dir.appending(path: "chunks", directoryHint: .isDirectory), withIntermediateDirectories: true)
        if let sourceData, let ext = sourceExtension {
            let name = "source.\(ext)"
            try sourceData.write(to: dir.appending(path: name))
            project.sourceFileName = name
        }
        try save(&project)
        return project
    }

    /// Lädt ein Projekt und gleicht es mit den Dateien ab: fertige Abschnitte ohne lesbare CAF
    /// gelten wieder als offen.
    public func load(id: UUID) throws -> Project {
        let url = manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ProjectStoreError.notFound(id) }
        var project = try Self.decoder.decode(Project.self, from: Data(contentsOf: url))
        guard project.schemaVersion <= Project.currentSchemaVersion else {
            throw ProjectStoreError.unsupportedSchema(project.schemaVersion)
        }
        if reconcile(&project) { try save(&project, touch: false) }
        cache[id] = project
        return project
    }

    /// Schreibt das Manifest atomar.
    public func save(_ project: inout Project, touch: Bool = true) throws {
        try save(&project, touch: touch, beforeCommit: nil)
    }

    func save(_ project: inout Project, touch: Bool = true, beforeCommit: (() throws -> Void)?) throws {
        if touch { project.updatedAt = Date() }
        try AtomicFile.write(
            try Self.encoder.encode(project), to: manifestURL(for: project.id), beforeCommit: beforeCommit)
        cache[project.id] = project
    }

    /// Alle Projekte, neueste zuerst. Kaputte Ordner werden übersprungen.
    public func list() -> [ProjectSummary] {
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) ?? [])
            .compactMap(UUID.init(uuidString:))
        var out: [ProjectSummary] = []
        for id in ids {
            guard let p = try? load(id: id) else { continue }
            let est = ETAEstimator().estimate(for: p.chunks)
            out.append(ProjectSummary(
                id: id, title: p.title, duration: p.totalDuration, updatedAt: p.updatedAt,
                state: p.state, progress: est.progress))
        }
        return out.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Gleiches Dokument, gleiche Sprache und Stimme schon angefangen? Dann dort weitermachen.
    public func findExisting(sourceHash: String, language: Language, voiceID: String) -> Project? {
        for s in list() {
            if let p = try? load(id: s.id), p.sourceHash == sourceHash, p.language == language,
               p.voiceID == voiceID {
                return p
            }
        }
        return nil
    }

    /// Löschen nur auf ausdrücklichen Aufruf. Die fertige MP3 im Ablageordner bleibt erhalten.
    public func delete(id: UUID) throws {
        cache[id] = nil
        try FileManager.default.removeItem(at: directory(for: id))
    }

    // MARK: Fortschritt

    public func setState(_ state: ProjectState, id: UUID) throws {
        var p = try current(id)
        p.state = state
        try save(&p)
    }

    /// Nächster offener Abschnitt (Status `.pending`).
    public func nextPendingChunk(id: UUID) throws -> ProjectChunk? {
        try current(id).chunks.first { $0.status == .pending }
    }

    /// Seed für den nächsten Versuch dieses Abschnitts.
    public func seed(id: UUID, chunkIndex: Int) throws -> UInt64 {
        let p = try current(id)
        guard let pos = position(of: chunkIndex, in: p) else { throw ProjectStoreError.chunkOutOfRange(chunkIndex) }
        return SeedDerivation.seed(projectID: id, chunkIndex: chunkIndex, attempt: p.chunks[pos].attempts)
    }

    /// Die CAF muss vorher über `chunkStore(for:)` geschrieben sein.
    @discardableResult
    public func markChunkDone(
        id: UUID, chunkIndex: Int, duration: Double, computeSeconds: Double? = nil,
        qc: ChunkQCReport? = nil, seed: UInt64? = nil, attemptsUsed: Int = 1
    ) throws -> Project {
        try mutate(id, chunkIndex) { c in
            c.status = .done
            c.attempts += attemptsUsed
            c.duration = duration
            c.computeSeconds = computeSeconds
            c.qc = qc
            c.seed = seed
            c.lastError = nil
        }
    }

    /// Auffällig, aber die Aufnahme bleibt erhalten (Wiederholung oder Nutzer entscheidet).
    @discardableResult
    public func markChunkSuspicious(
        id: UUID, chunkIndex: Int, duration: Double?, computeSeconds: Double? = nil,
        qc: ChunkQCReport? = nil, seed: UInt64? = nil, attemptsUsed: Int = 1
    ) throws -> Project {
        try mutate(id, chunkIndex) { c in
            c.status = .suspicious
            c.attempts += attemptsUsed
            c.duration = duration
            c.computeSeconds = computeSeconds
            c.qc = qc
            c.seed = seed
        }
    }

    @discardableResult
    public func markChunkFailed(
        id: UUID, chunkIndex: Int, error: String, seed: UInt64? = nil, attemptsUsed: Int = 1
    ) throws -> Project {
        try mutate(id, chunkIndex) { c in
            c.status = .failed
            c.attempts += attemptsUsed
            c.lastError = error
            if let seed { c.seed = seed }
        }
    }

    /// Setzt einen Abschnitt zurück auf offen (z. B. für „nochmal versuchen“).
    @discardableResult
    public func resetChunk(id: UUID, chunkIndex: Int) throws -> Project {
        try mutate(id, chunkIndex) { $0.status = .pending }
    }

    // MARK: Intern

    private func current(_ id: UUID) throws -> Project {
        if let p = cache[id] { return p }
        return try load(id: id)
    }

    private func position(of chunkIndex: Int, in p: Project) -> Int? {
        p.chunks.firstIndex { $0.chunk.index == chunkIndex }
    }

    private func mutate(_ id: UUID, _ chunkIndex: Int, _ change: (inout ProjectChunk) -> Void) throws -> Project {
        var p = try current(id)
        guard let pos = position(of: chunkIndex, in: p) else { throw ProjectStoreError.chunkOutOfRange(chunkIndex) }
        change(&p.chunks[pos])
        try save(&p)
        return p
    }

    /// true, wenn etwas korrigiert wurde.
    private func reconcile(_ p: inout Project) -> Bool {
        let store = chunkStore(for: p.id)
        var changed = false
        for i in p.chunks.indices where p.chunks[i].status == .done || p.chunks[i].status == .suspicious {
            if !Self.isReadable(store.url(forIndex: p.chunks[i].chunk.index)) {
                p.chunks[i].status = .pending
                p.chunks[i].duration = nil
                p.chunks[i].qc = nil
                changed = true
            }
        }
        if changed, p.state == .finished || p.state == .exporting { p.state = .synthesizing }
        return changed
    }

    private static func isReadable(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path),
              let f = try? AVAudioFile(forReading: url) else { return false }
        return f.length > 0
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()
}
