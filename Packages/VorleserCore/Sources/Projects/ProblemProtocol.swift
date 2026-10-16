// Protokoll der Verdachtsfälle und Fehler der letzten Läufe, aus den Manifesten. Für das Helfer-Fenster
// („Protokolle“) und zum Kopieren bei der Fehlersuche. Reiner Text, ohne Oberfläche.
import AudioOut
import Foundation

/// Ein auffälliger oder gescheiterter Abschnitt.
public struct ProtocolEntry: Sendable, Equatable, Identifiable {
    public var chunkIndex: Int
    public var status: ChunkStatus
    public var attempts: Int
    public var pageIndex: Int?
    public var text: String
    public var error: String?
    /// Befunde der Prüfung (`ChunkQC`), z. B. `tooShort`.
    public var issues: [String]
    public var durationSeconds: Double?
    public var id: Int { chunkIndex }
}

/// Auffälligkeiten eines Projekts.
public struct ProjectProblems: Sendable, Equatable, Identifiable {
    public var projectID: UUID
    public var title: String
    public var updatedAt: Date
    public var state: ProjectState
    public var language: String
    public var voiceID: String
    public var chunkCount: Int
    public var entries: [ProtocolEntry]
    public var id: UUID { projectID }
}

public enum ProblemProtocol {
    /// Längster Abschnittstext im Protokoll (Zeichen); der Rest wird mit „…“ gekürzt.
    public static let maxTextLength = 240

    /// Verdächtige und gescheiterte Abschnitte eines Projekts, nach Abschnittsnummer.
    public static func problems(in project: Project) -> ProjectProblems {
        let entries = project.chunks
            .filter { $0.status == .suspicious || $0.status == .failed }
            .map { c in
                ProtocolEntry(
                    chunkIndex: c.chunk.index, status: c.status, attempts: c.attempts, pageIndex: c.pageIndex,
                    text: shorten(c.chunk.text), error: c.lastError,
                    issues: c.qc?.issues.map(\.rawValue) ?? [], durationSeconds: c.duration)
            }
            .sorted { $0.chunkIndex < $1.chunkIndex }
        return ProjectProblems(
            projectID: project.id, title: project.title, updatedAt: project.updatedAt, state: project.state,
            language: project.language.rawValue, voiceID: project.voiceID, chunkCount: project.chunks.count,
            entries: entries)
    }

    static func shorten(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > maxTextLength ? String(flat.prefix(maxTextLength)) + "…" : flat
    }

    /// Text zum Kopieren: Kopf (Version, System), je Projekt die Auffälligkeiten, am Ende der Protokollausschnitt.
    /// - Parameters:
    ///   - header: Zeilen wie „Vorleser 0.1.0 (1)“, „macOS 26.6“.
    ///   - log: letzte Zeilen der Protokolldatei (`EventLog.tail`), optional.
    public static func render(_ projects: [ProjectProblems], header: [String], log: String? = nil, now: Date = Date()) -> String {
        var out = ["Vorleser – Protokoll", ISO8601DateFormatter().string(from: now)]
        out += header
        out.append("")
        if projects.allSatisfy({ $0.entries.isEmpty }) {
            out.append("Keine Auffälligkeiten in den letzten Läufen.")
        }
        for p in projects {
            out.append("== \(p.title) ==")
            out.append("Projekt \(p.projectID.uuidString.lowercased()) · Zustand \(p.state.rawValue) · Sprache \(p.language) · Stimme \(p.voiceID) · \(p.chunkCount) Abschnitte")
            if p.entries.isEmpty { out.append("  keine Auffälligkeiten") }
            for e in p.entries {
                var line = "  Abschnitt \(e.chunkIndex)"
                if let page = e.pageIndex { line += " (Seite \(page + 1))" }
                line += " · \(e.status.rawValue) · \(e.attempts) Versuch(e)"
                if let d = e.durationSeconds { line += String(format: " · %.1f s", d) }
                if !e.issues.isEmpty { line += " · " + e.issues.joined(separator: ", ") }
                out.append(line)
                if let err = e.error { out.append("    Fehler: \(err)") }
                out.append("    Text: \(e.text)")
            }
            out.append("")
        }
        if let log, !log.isEmpty {
            out.append("== Protokolldatei (letzte Zeilen) ==")
            out.append(log)
        }
        return out.joined(separator: "\n")
    }
}

extension ProjectStore {
    /// Auffälligkeiten der zuletzt bearbeiteten Projekte (neueste zuerst). Projekte ohne Auffälligkeiten
    /// zählen mit, damit das Protokoll zeigt, dass sie sauber liefen; `onlyWithProblems` blendet sie aus.
    public func recentProblems(limit: Int = 10, onlyWithProblems: Bool = false) -> [ProjectProblems] {
        var out: [ProjectProblems] = []
        for s in list() {
            guard out.count < limit, let p = try? load(id: s.id) else { continue }
            let problems = ProblemProtocol.problems(in: p)
            if onlyWithProblems && problems.entries.isEmpty { continue }
            out.append(problems)
        }
        return out
    }
}
