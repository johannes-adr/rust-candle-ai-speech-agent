// Einfache Protokolldatei neben dem Systemprotokoll (os.Logger): `~/Library/Logs/Vorleser/vorleser.log`.
// Dort kann der Helfer sie öffnen und weitergeben, ohne die Konsole zu kennen. Es wird nie Dokumenttext
// protokolliert, nur Ereignisse (Start, Fehlerschlüssel, Zahlen).
import Foundation

public final class EventLog: @unchecked Sendable {
    public enum Level: String, Sendable { case info = "INFO", warning = "WARN", error = "FEHLER" }

    public let directory: URL
    public let maxBytes: Int
    private let lock = NSLock()

    public static var defaultDirectory: URL {
        URL.libraryDirectory.appending(path: "Logs/Vorleser", directoryHint: .isDirectory)
    }

    public var fileURL: URL { directory.appending(path: "vorleser.log") }
    var rotatedURL: URL { directory.appending(path: "vorleser.1.log") }

    public init(directory: URL = EventLog.defaultDirectory, maxBytes: Int = 512 * 1024) {
        self.directory = directory
        self.maxBytes = maxBytes
    }

    public func write(_ level: Level, _ category: String, _ message: String, now: Date = Date()) {
        let line = "\(ISO8601DateFormatter().string(from: now)) \(level.rawValue) [\(category)] \(message.replacingOccurrences(of: "\n", with: " "))\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if size > maxBytes {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: fileURL, to: rotatedURL)
        }
        if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
        guard let h = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: Data(line.utf8))
    }

    /// Die letzten `lines` Zeilen (aus der aktuellen Datei, bei Bedarf aufgefüllt aus der vorherigen).
    public func tail(lines: Int = 80) -> String {
        lock.lock()
        defer { lock.unlock() }
        var all: [String] = []
        for url in [rotatedURL, fileURL] {
            if let s = try? String(contentsOf: url, encoding: .utf8) {
                all += s.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
        }
        return all.suffix(lines).joined(separator: "\n")
    }
}
