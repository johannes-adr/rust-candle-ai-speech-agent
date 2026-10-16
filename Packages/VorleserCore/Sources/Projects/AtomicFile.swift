import Foundation

public enum AtomicFile {
    /// Schreibt erst in eine temporäre Datei im selben Ordner und ersetzt dann die Zieldatei.
    /// Bricht etwas vor dem Ersetzen ab, bleibt die alte Datei unverändert.
    /// - Parameter beforeCommit: Testhaken zwischen Schreiben und Ersetzen.
    public static func write(
        _ data: Data, to url: URL, beforeCommit: (() throws -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tmp)
            try beforeCommit?()
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
