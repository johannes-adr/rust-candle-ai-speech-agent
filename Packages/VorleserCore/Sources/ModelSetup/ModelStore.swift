import Foundation

/// Zustand eines Modells im Modellordner.
public enum ModelStatus: Sendable, Equatable {
    /// Nichts vorhanden.
    case missing
    /// Ein Download wurde begonnen (Zwischenordner), aber nicht abgeschlossen.
    case partial(bytesPresent: Int64, bytesTotal: Int64)
    /// Alle Dateien da, Größen stimmen, Prüfmarke gesetzt.
    case ready
    /// Ordner vorhanden, aber unvollständig oder beschädigt. `problems` nennt die Dateipfade.
    case corrupt(problems: [String])

    public var isReady: Bool { self == .ready }
}

/// Der Modellordner `~/Library/Application Support/Vorleser/Models`.
///
/// ```
/// Models/
///   mlx-community--Qwen3-…-4bit@<revision>/   fertig; enthält .vorleser-ready.json
///   .staging/<dieselbe Ordnerbezeichnung>/    Download im Gang: fertige Dateien + *.part
/// ```
/// Ein Modell ist erst dann „fertig“, wenn der Zwischenordner mit einem einzigen `rename`
/// an seinen endgültigen Platz verschoben wurde. Ein Abbruch hinterlässt also nie einen
/// halb gefüllten Zielordner. Zusätzliche Dateien im Zielordner (z. B. das von
/// `mlx-audio-swift` erzeugte `tokenizer.json`) stören nicht.
public struct ModelStore: Sendable {
    public static let markerName = ".vorleser-ready.json"

    public let root: URL

    public init(root: URL = ModelStore.defaultRoot) {
        self.root = root
    }

    public static let standard = ModelStore()

    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vorleser", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: Pfade

    public func directory(for ref: ModelRef) -> URL {
        root.appendingPathComponent(ref.folderName, isDirectory: true)
    }

    public func stagingDirectory(for ref: ModelRef) -> URL {
        root.appendingPathComponent(".staging", isDirectory: true).appendingPathComponent(ref.folderName, isDirectory: true)
    }

    public func markerURL(for ref: ModelRef) -> URL {
        directory(for: ref).appendingPathComponent(Self.markerName)
    }

    // MARK: Zustand

    /// Schneller Zustand ohne Prüfsummen: Prüfmarke, alle Dateien da, Größen stimmen.
    public func status(of manifest: ModelManifest) -> ModelStatus {
        let fm = FileManager.default
        let dir = directory(for: manifest.ref)
        if fm.fileExists(atPath: dir.path) {
            var problems: [String] = []
            if !fm.fileExists(atPath: markerURL(for: manifest.ref).path) { problems.append(Self.markerName) }
            for f in manifest.files {
                let size = Self.fileSize(dir.appendingPathComponent(f.path))
                if size != f.size { problems.append(f.path) }
            }
            return problems.isEmpty ? .ready : .corrupt(problems: problems)
        }
        let staging = stagingDirectory(for: manifest.ref)
        if fm.fileExists(atPath: staging.path) {
            return .partial(bytesPresent: stagedBytes(of: manifest), bytesTotal: manifest.totalBytes)
        }
        return .missing
    }

    /// Bytes, die im Zwischenordner schon liegen (fertige Dateien und Teildateien).
    public func stagedBytes(of manifest: ModelManifest) -> Int64 {
        let staging = stagingDirectory(for: manifest.ref)
        var sum: Int64 = 0
        for f in manifest.files {
            let done = Self.fileSize(staging.appendingPathComponent(f.path))
            if done == f.size { sum += done; continue }
            sum += min(max(Self.fileSize(staging.appendingPathComponent(f.path + ".part")), 0), f.size)
        }
        return sum
    }

    /// Vollständige Prüfung mit SHA-256 aller Dateien. Dauert bei 2–3 GB einige Sekunden.
    /// `progress` bekommt die Anzahl geprüfter Bytes dieses Modells.
    public func verify(_ manifest: ModelManifest, progress: (@Sendable (Int64) -> Void)? = nil) throws -> ModelStatus {
        guard case .ready = status(of: manifest) else { return status(of: manifest) }
        let dir = directory(for: manifest.ref)
        var problems: [String] = []
        var done: Int64 = 0
        for f in manifest.files {
            let base = done
            let hash = try Checksum.sha256(ofFileAt: dir.appendingPathComponent(f.path)) { progress?(base + $0) }
            done += f.size
            if hash != f.sha256 { problems.append(f.path) }
        }
        return problems.isEmpty ? .ready : .corrupt(problems: problems)
    }

    /// Ordner des Modells, wenn es schnell geprüft bereit ist. Das nutzt die Sprach-Engine.
    /// Ohne mitgeliefertes Manifest zählt nur die Prüfmarke.
    public func locate(_ ref: ModelRef) -> URL? {
        let dir = directory(for: ref)
        if let manifest = ModelManifest.bundled(for: ref) {
            return status(of: manifest).isReady ? dir : nil
        }
        return FileManager.default.fileExists(atPath: markerURL(for: ref).path) ? dir : nil
    }

    // MARK: Aufräumen

    public func remove(_ ref: ModelRef) throws {
        let fm = FileManager.default
        for url in [directory(for: ref), stagingDirectory(for: ref)] where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    static func fileSize(_ url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return -1 }
        return size.int64Value
    }
}

/// Prüfmarke im fertigen Ordner.
struct ReadyMarker: Codable {
    var repo: String
    var revision: String
    var verifiedAt: Date
}
