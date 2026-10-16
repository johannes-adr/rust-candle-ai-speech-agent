import CryptoKit
import Foundation

/// Erzeugt ein Manifest aus der Hugging-Face-API (einmalig beim Entwickeln, nicht in der App).
/// LFS-Dateien bringen `lfs.sha256` mit; kleine Dateien (Git-Blobs) werden geladen, mit SHA-256 versehen
/// und gegen die Git-Blob-ID (SHA-1) der API gegengeprüft.
public enum ManifestFetcher {
    /// Dateien, die zur Laufzeit nicht gebraucht werden.
    public static let ignored: Set<String> = [".gitattributes", "README.md"]

    public enum FetchError: Error, LocalizedError {
        case http(Int)
        case revisionMismatch(asked: String, got: String)
        case blobMismatch(String)
        case badResponse

        public var errorDescription: String? {
            switch self {
            case let .http(s): "Hugging Face antwortete mit \(s)."
            case let .revisionMismatch(a, g): "Revision \(a) gewünscht, API meldet \(g)."
            case let .blobMismatch(p): "Git-Prüfsumme stimmt nicht für \(p)."
            case .badResponse: "Unerwartete Antwort der API."
            }
        }
    }

    public static func fetch(ref: ModelRef, baseURL: URL = URL(string: "https://huggingface.co")!,
                             session: URLSession = .shared) async throws -> ModelManifest {
        var comps = URLComponents(
            url: baseURL.appendingPathComponent("api/models/\(ref.repo)/revision/\(ref.revision)"),
            resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "blobs", value: "true")]
        let (data, response) = try await session.data(from: comps.url!)
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 { throw FetchError.http(status) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String,
              let siblings = json["siblings"] as? [[String: Any]] else { throw FetchError.badResponse }
        guard sha == ref.revision else { throw FetchError.revisionMismatch(asked: ref.revision, got: sha) }

        var files: [ModelManifest.File] = []
        for s in siblings.sorted(by: { ($0["rfilename"] as? String ?? "") < ($1["rfilename"] as? String ?? "") }) {
            guard let path = s["rfilename"] as? String, !ignored.contains(path) else { continue }
            if let lfs = s["lfs"] as? [String: Any], let hash = lfs["sha256"] as? String, let size = lfs["size"] as? Int {
                files.append(.init(path: path, size: Int64(size), sha256: hash))
                continue
            }
            // Kleine Datei: laden, hashen, mit der Git-Blob-ID gegenprüfen.
            let url = path.split(separator: "/").reduce(
                baseURL.appendingPathComponent(ref.repo).appendingPathComponent("resolve").appendingPathComponent(ref.revision)
            ) { $0.appendingPathComponent(String($1)) }
            let (body, resp) = try await session.data(from: url)
            if let status = (resp as? HTTPURLResponse)?.statusCode, status != 200 { throw FetchError.http(status) }
            if let blobId = s["blobId"] as? String, gitBlobID(body) != blobId { throw FetchError.blobMismatch(path) }
            files.append(.init(path: path, size: Int64(body.count), sha256: Checksum.sha256(of: body)))
        }
        let manifest = ModelManifest(repo: ref.repo, revision: ref.revision, files: files)
        try manifest.validate()
        return manifest
    }

    /// `git hash-object`: SHA-1 über „blob <Länge>\0<Inhalt>“.
    static func gitBlobID(_ data: Data) -> String {
        var h = Insecure.SHA1()
        h.update(data: Data("blob \(data.count)\0".utf8))
        h.update(data: data)
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
