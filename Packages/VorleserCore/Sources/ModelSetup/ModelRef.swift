import Foundation

/// Ein Modell auf Hugging Face, fest gepinnt auf eine Revision (Commit).
/// Die Revision ist immer ein voller Commit-Hash, nie ein Branchname wie `main`.
public struct ModelRef: Sendable, Hashable, Codable {
    public let repo: String
    public let revision: String

    public init(repo: String, revision: String) {
        self.repo = repo
        self.revision = revision
    }

    /// Ordnername im Modellordner: `mlx-community--Qwen3-…@<revision>`.
    public var folderName: String {
        repo.replacingOccurrences(of: "/", with: "--") + "@" + revision
    }

    /// Dateiname des mitgelieferten Manifests (ohne Endung): `mlx-community--Qwen3-…`.
    public var manifestName: String {
        repo.replacingOccurrences(of: "/", with: "--")
    }

    /// Ordner des Snapshots im Hugging-Face-Cache (`models--org--name/snapshots/<rev>`).
    public func huggingFaceSnapshotDirectory(cacheRoot: URL = ModelRef.defaultHuggingFaceCacheRoot) -> URL {
        cacheRoot
            .appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
            .appendingPathComponent(revision)
    }

    public static var defaultHuggingFaceCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub")
    }
}
