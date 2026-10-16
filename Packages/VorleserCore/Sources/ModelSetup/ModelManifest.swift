import Foundation

/// Feste Dateiliste eines Modells mit Größe und SHA-256 je Datei.
/// Wird einmalig mit `vorleser-cli models manifest` aus der Hugging-Face-API erzeugt
/// und unter `Manifests/` eingecheckt. Ohne diese Liste wird nichts geladen.
public struct ModelManifest: Sendable, Codable, Equatable {
    public struct File: Sendable, Codable, Equatable, Hashable {
        /// Pfad relativ zum Modellordner, z. B. `speech_tokenizer/model.safetensors`.
        public let path: String
        public let size: Int64
        /// SHA-256 als 64 Hexzeichen, klein geschrieben.
        public let sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public let repo: String
    public let revision: String
    public let files: [File]

    public init(repo: String, revision: String, files: [File]) {
        self.repo = repo
        self.revision = revision
        self.files = files
    }

    public var ref: ModelRef { ModelRef(repo: repo, revision: revision) }
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    public enum ManifestError: Error, Equatable, LocalizedError {
        case unsafePath(String)
        case badChecksum(String)
        case empty

        public var errorDescription: String? {
            switch self {
            case let .unsafePath(p): "Ungültiger Pfad im Manifest: \(p)"
            case let .badChecksum(p): "Ungültige Prüfsumme im Manifest: \(p)"
            case .empty: "Das Manifest enthält keine Dateien."
            }
        }
    }

    /// Liest und prüft ein Manifest (keine Pfade nach außen, gültige Prüfsummen).
    public static func decode(_ data: Data) throws -> ModelManifest {
        let manifest = try JSONDecoder().decode(ModelManifest.self, from: data)
        try manifest.validate()
        return manifest
    }

    public func validate() throws {
        guard !files.isEmpty else { throw ManifestError.empty }
        for f in files {
            let parts = f.path.split(separator: "/", omittingEmptySubsequences: false)
            if f.path.isEmpty || f.path.hasPrefix("/") || parts.contains("..") || parts.contains("") || parts.contains(".") {
                throw ManifestError.unsafePath(f.path)
            }
            let isHex = f.sha256.count == 64 && f.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
            if !isHex || f.size < 0 { throw ManifestError.badChecksum(f.path) }
        }
    }

    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try enc.encode(self)
    }

    /// Das mitgelieferte Manifest zu einem gepinnten Modell, `nil` wenn keins existiert.
    public static func bundled(for ref: ModelRef) -> ModelManifest? {
        guard let url = Bundle.module.url(forResource: ref.manifestName, withExtension: "json", subdirectory: "Manifests"),
              let data = try? Data(contentsOf: url),
              let manifest = try? decode(data),
              manifest.ref == ref
        else { return nil }
        return manifest
    }
}
