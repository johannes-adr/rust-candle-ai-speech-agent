import Foundation
import ModelSetup

/// Falscher Hugging-Face-Server über `URLProtocol`. Jeder Test benutzt einen eigenen Hostnamen,
/// so können Tests parallel laufen.
final class MockServer: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
        /// Nur so viele Bytes liefern, dann Verbindungsabbruch (Netz weg).
        var failAfter: Int?
        /// Nur so viele Bytes liefern, dann hängen (Download „läuft“ ewig).
        var stallAfter: Int?
    }

    typealias Handler = @Sendable (URLRequest) -> Reply
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var log: [String: [URLRequest]] = [:]

    static func register(host: String, _ handler: @escaping Handler) {
        lock.withLock { handlers[host] = handler; log[host] = [] }
    }

    static func requests(host: String) -> [URLRequest] { lock.withLock { log[host] ?? [] } }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [MockServer.self]
        return c
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let host = request.url?.host ?? ""
        let handler = Self.lock.withLock { () -> Handler? in
            Self.log[host, default: []].append(request)
            return Self.handlers[host]
        }
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let reply = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let limit = reply.failAfter ?? reply.stallAfter ?? reply.body.count
        var sent = 0
        let step = 1000
        while sent < min(limit, reply.body.count) {
            let n = min(step, min(limit, reply.body.count) - sent)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: sent..<sent + n))
            sent += n
        }
        if reply.failAfter != nil {
            Thread.sleep(forTimeInterval: 0.15) // Daten erst ausliefern lassen, dann der Abbruch
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        } else if reply.stallAfter == nil {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

/// Testdaten: kleine Dateien, Manifest, Modellordner in einem temporären Verzeichnis.
struct Fixture {
    let dir: URL
    let host: String
    let ref: ModelRef
    let files: [String: Data]
    let manifest: ModelManifest
    let store: ModelStore

    init(files: [String: Data]? = nil, revision: String = String(repeating: "a", count: 40)) throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("modelsetup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        host = "mock-\(UUID().uuidString.lowercased()).test"
        ref = ModelRef(repo: "org/test-model", revision: revision)
        let data = files ?? [
            "config.json": Data(#"{"a":1}"#.utf8),
            "sub/weights.safetensors": Fixture.bytes(count: 25_000, seed: 7),
            "vocab.json": Fixture.bytes(count: 3_000, seed: 3),
        ]
        self.files = data
        manifest = ModelManifest(
            repo: ref.repo, revision: ref.revision,
            files: data.keys.sorted().map { .init(path: $0, size: Int64(data[$0]!.count), sha256: Checksum.sha256(of: data[$0]!)) })
        store = ModelStore(root: dir.appendingPathComponent("Models"))
    }

    static func bytes(count: Int, seed: UInt8) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ Int(seed) &+ ($0 >> 8)) })
    }

    func cleanUp() { try? FileManager.default.removeItem(at: dir) }

    var baseURL: URL { URL(string: "https://\(host)")! }

    /// Server, der die Dateien ausliefert (mit Range-Unterstützung, wenn `honorRange`).
    func serve(honorRange: Bool = true, tweak: (@Sendable (String, inout MockServer.Reply) -> Void)? = nil) {
        let files = files
        MockServer.register(host: host) { request in
            let comps = request.url!.pathComponents.dropFirst() // "/org/test-model/resolve/<rev>/<pfad>"
            let path = comps.dropFirst(4).joined(separator: "/")
            guard let data = files[path] else { return .init(status: 404) }
            var reply = MockServer.Reply(status: 200, body: data)
            if honorRange, let range = request.value(forHTTPHeaderField: "Range"),
               let start = Int(range.replacingOccurrences(of: "bytes=", with: "").dropLast()) {
                reply.status = 206
                reply.body = data.subdata(in: start..<data.count)
            }
            tweak?(path, &reply)
            return reply
        }
    }

    func installer(freeSpace: @escaping @Sendable (URL) -> Int64 = { _ in 100 << 30 }, cache: HFCacheImporter? = nil) -> ModelInstaller {
        ModelInstaller(store: store, cache: cache, baseURL: baseURL,
                       sessionConfiguration: { MockServer.configuration() }, freeSpace: freeSpace)
    }

    /// Legt einen Hugging-Face-Cache mit denselben Dateien an (Snapshot mit Symlinks auf `blobs/`).
    func makeHFCache(corrupt: Set<String> = []) throws -> HFCacheImporter {
        let cacheRoot = dir.appendingPathComponent("hub")
        let model = cacheRoot.appendingPathComponent("models--org--test-model")
        let snapshot = model.appendingPathComponent("snapshots/\(ref.revision)")
        for (path, data) in files {
            let blob = model.appendingPathComponent("blobs/\(Checksum.sha256(of: data))")
            try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(), withIntermediateDirectories: true)
            var content = data
            if corrupt.contains(path) { content[0] ^= 0xFF }
            try content.write(to: blob)
            let link = snapshot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            let depth = path.split(separator: "/").count
            let up = String(repeating: "../", count: depth + 1)
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "\(up)blobs/\(blob.lastPathComponent)")
        }
        return HFCacheImporter(cacheRoot: cacheRoot)
    }
}

/// Sammelt alle Ereignisse eines Installationslaufs.
func collect(_ stream: AsyncThrowingStream<InstallEvent, Error>) async throws -> [InstallEvent] {
    var events: [InstallEvent] = []
    for try await e in stream { events.append(e) }
    return events
}

func lastProgress(_ events: [InstallEvent]) -> InstallProgress? {
    events.reversed().compactMap { if case let .progress(p) = $0 { p } else { nil } }.first
}
