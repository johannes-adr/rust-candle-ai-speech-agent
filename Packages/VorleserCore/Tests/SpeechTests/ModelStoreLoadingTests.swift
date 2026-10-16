import Foundation
import ModelSetup
import Testing

@testable import VorleserSpeech

/// Zählt jeden Netzzugriff und lässt ihn scheitern.
final class NetworkTripwire: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URL] = []
    static var requests: [URL] { lock.withLock { seen } }
    static func reset() { lock.withLock { seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let scheme = request.url?.scheme, ["http", "https"].contains(scheme) else { return false }
        lock.withLock { seen.append(request.url!) }
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private let realBaseReady: Bool = {
    guard let spec = ModelSpec.pinned(.base, bits: .four) else { return false }
    return ModelStore.standard.locate(spec) != nil
}()

@Suite(.serialized) struct ModelStoreLoadingTests {
    @Test func storeHasPriorityAndCacheIsOnlyFallback() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("loc-\(UUID())")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let spec = try #require(ModelSpec.pinned(.base, bits: .four))
        // Leerer Modellordner, aber ein Cache-Snapshot mit config.json (nur der Ordnername zählt hier).
        let cache = tmp.appendingPathComponent("hub")
        let snapshot = spec.huggingFaceSnapshotDirectory(cacheRoot: cache)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: snapshot.appendingPathComponent("config.json"))
        let store = ModelStore(root: tmp.appendingPathComponent("Models"))

        // Ohne Fallback (App): „nicht da“, Fehler nennt den Ordner im ModelStore.
        let strict = MLXQwenEngine(bits: .four, store: store, cacheRoot: cache, fallbackToHuggingFaceCache: false)
        do {
            try await strict.load(.base)
            Issue.record("Hätte fehlschlagen müssen")
        } catch let SpeechEngineError.modelMissing(path) {
            #expect(path == store.directory(for: spec).path)
        }
        // Mit Fallback (Entwickler) wird der Cache-Ordner versucht; `{}` ist keine gültige config, also Fehler anderer Art.
        let lenient = MLXQwenEngine(bits: .four, store: store, cacheRoot: cache, fallbackToHuggingFaceCache: true)
        do {
            try await lenient.load(.base)
            Issue.record("Hätte fehlschlagen müssen")
        } catch SpeechEngineError.modelMissing {
            Issue.record("Cache-Fallback wurde nicht versucht")
        } catch {}
    }

    /// Beleg „nach der Einrichtung keine Netzwerkzugriffe“ für das Laden: gesperrtes Netz, echtes Modell aus dem ModelStore.
    /// (Zusätzlich im Probelauf unter `sandbox-exec (deny network*)`, siehe docs/phase5-setup.md.)
    @Test(.enabled(if: realBaseReady, "Base-4bit ist nicht im ModelStore"))
    func loadingFromStoreDoesNotTouchTheNetwork() async throws {
        URLProtocol.registerClass(NetworkTripwire.self)
        defer { URLProtocol.unregisterClass(NetworkTripwire.self) }
        NetworkTripwire.reset()

        // Kontrolle: die Falle fängt `URLSession.shared` ab. Eigene Sitzungen (`URLSession(configuration:)`)
        // sieht sie nicht; dafür gibt es die Sperre auf Prozessebene in scripts/offline-check.sh.
        _ = try? await URLSession.shared.data(from: URL(string: "https://huggingface.co/control-shared")!)
        #expect(NetworkTripwire.requests.count == 1, "Falle greift nicht: \(NetworkTripwire.requests)")
        NetworkTripwire.reset()

        let engine = MLXQwenEngine(bits: .four, fallbackToHuggingFaceCache: false)
        try await engine.load(.base)
        let rate = await engine.sampleRate
        #expect(rate > 0)
        await engine.unload()
        #expect(NetworkTripwire.requests.isEmpty, "Netzzugriffe beim Laden: \(NetworkTripwire.requests)")
    }
}
