// Pflege der Projektordner für das Helfer-Fenster: Platzbedarf, Zwischendateien aufräumen.
import Foundation

public enum ProjectCleanupError: Error, Sendable, Equatable {
    /// Nur fertige Projekte werden aufgeräumt; bei einem unfertigen braucht „Fortsetzen“ die Abschnitte.
    case notFinished
    /// Die MP3 ist nicht (mehr) im Ablageordner. Dann wären die Abschnitte die einzige Kopie.
    case outputMissing
}

/// Platzbedarf eines Projekts in Bytes.
public struct ProjectDiskUsage: Sendable, Equatable {
    /// Der ganze Projektordner (Manifest, Quelle, Abschnitte).
    public var projectFolder: Int64
    /// Davon `chunks/`.
    public var intermediates: Int64
    /// Die fertige MP3 im Ablageordner, falls vorhanden.
    public var mp3: Int64?

    public var total: Int64 { projectFolder + (mp3 ?? 0) }
}

/// Eine Zeile der Liste „Hörbücher“ im Helfer-Fenster.
public struct ProjectOverview: Sendable, Equatable, Identifiable {
    public var summary: ProjectSummary
    public var usage: ProjectDiskUsage
    /// Lässt sich aufräumen: fertig, MP3 vorhanden und es liegen noch Abschnitte da.
    public var canCleanIntermediates: Bool
    public var id: UUID { summary.id }
}

extension ProjectStore {
    /// Platzbedarf des Projekts. Fehlende Ordner zählen 0.
    public func diskUsage(id: UUID) -> ProjectDiskUsage {
        var mp3: Int64?
        if let p = try? load(id: id) {
            mp3 = Self.fileSize(outputURL(title: p.title))
        }
        return ProjectDiskUsage(
            projectFolder: Self.directorySize(directory(for: id)),
            intermediates: Self.directorySize(chunkStore(for: id).directory),
            mp3: mp3)
    }

    /// Alle Projekte mit Platzbedarf, neueste zuerst.
    public func overview() -> [ProjectOverview] {
        list().map { s in
            let usage = diskUsage(id: s.id)
            let can = s.state == .finished && usage.mp3 != nil && usage.intermediates > 0
            return ProjectOverview(summary: s, usage: usage, canCleanIntermediates: can)
        }
    }

    /// Löscht `chunks/` (nicht die MP3, nicht Manifest und Quelle) eines **fertigen** Projekts, dessen MP3
    /// noch da ist. Danach lässt sich das Projekt nicht mehr fortsetzen/neu schneiden, braucht es aber auch nicht.
    /// - Returns: freigegebene Bytes.
    @discardableResult
    public func cleanIntermediates(id: UUID) throws -> Int64 {
        var p = try load(id: id)
        guard p.state == .finished else { throw ProjectCleanupError.notFinished }
        guard Self.fileSize(outputURL(title: p.title)) != nil else { throw ProjectCleanupError.outputMissing }
        let dir = chunkStore(for: id).directory
        let freed = Self.directorySize(dir)
        // Erst das Manifest: so gilt der Zustand nie als „kaputt“, auch wenn das Löschen unterbrochen wird.
        p.intermediatesRemoved = true
        try save(&p, touch: false)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        return freed
    }

    static func fileSize(_ url: URL) -> Int64? {
        guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true
        else { return nil }
        return Int64(v.fileSize ?? 0)
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true {
                total += Int64(v.fileSize ?? 0)
            }
        }
        return total
    }
}
