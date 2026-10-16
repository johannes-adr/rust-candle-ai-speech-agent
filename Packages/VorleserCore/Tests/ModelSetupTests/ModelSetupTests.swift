import Foundation
import Testing

@testable import ModelSetup

// MARK: Manifest

@Test func manifestParsesAndRoundTrips() throws {
    let json = """
    {"repo":"org/m","revision":"\(String(repeating: "b", count: 40))","files":[
      {"path":"config.json","size":10,"sha256":"\(String(repeating: "0", count: 64))"},
      {"path":"speech_tokenizer/model.safetensors","size":99,"sha256":"\(String(repeating: "f", count: 64))"}]}
    """
    let m = try ModelManifest.decode(Data(json.utf8))
    #expect(m.files.count == 2)
    #expect(m.totalBytes == 109)
    #expect(m.ref.folderName == "org--m@\(String(repeating: "b", count: 40))")
    #expect(try ModelManifest.decode(m.encoded()) == m)
}

@Test func manifestRejectsUnsafePathsAndBadChecksums() {
    func manifest(path: String, sha: String = String(repeating: "0", count: 64)) -> Data {
        Data(#"{"repo":"o/m","revision":"r","files":[{"path":"\#(path)","size":1,"sha256":"\#(sha)"}]}"#.utf8)
    }
    #expect(throws: ModelManifest.ManifestError.unsafePath("../evil")) { try ModelManifest.decode(manifest(path: "../evil")) }
    #expect(throws: ModelManifest.ManifestError.unsafePath("/etc/passwd")) { try ModelManifest.decode(manifest(path: "/etc/passwd")) }
    #expect(throws: ModelManifest.ManifestError.unsafePath("a//b")) { try ModelManifest.decode(manifest(path: "a//b")) }
    #expect(throws: ModelManifest.ManifestError.badChecksum("x")) { try ModelManifest.decode(manifest(path: "x", sha: "ABC")) }
    #expect(throws: ModelManifest.ManifestError.empty) { try ModelManifest.decode(Data(#"{"repo":"o/m","revision":"r","files":[]}"#.utf8)) }
}

@Test func bundledManifestsAreCompleteAndPinned() throws {
    let refs = [
        ModelRef(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit", revision: "37e955a1deb861c088ae5f3a67043185f3d1a60c"),
        ModelRef(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit", revision: "e7dd0585652209fa0d7783659aad4e8a324de11c"),
        ModelRef(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit", revision: "5c390979e4b93af5f2932f90742ca99c7dd04687"),
    ]
    for ref in refs {
        let m = try #require(ModelManifest.bundled(for: ref), "Manifest fehlt für \(ref.repo)")
        let paths = Set(m.files.map(\.path))
        for needed in ["config.json", "model.safetensors", "vocab.json", "merges.txt", "tokenizer_config.json",
                       "speech_tokenizer/model.safetensors", "speech_tokenizer/config.json"] {
            #expect(paths.contains(needed), "\(needed) fehlt in \(ref.repo)")
        }
        #expect(m.totalBytes > 2_000_000_000)
    }
    // Eine andere Revision hat kein Manifest.
    #expect(ModelManifest.bundled(for: ModelRef(repo: refs[0].repo, revision: "0000")) == nil)
}

@Test func gitBlobIDMatchesGit() {
    // `printf 'hello' | git hash-object --stdin`
    #expect(ManifestFetcher.gitBlobID(Data("hello".utf8)) == "b6fc4c620b67d95f953a5c1c1230aaab5db5a1b0")
}

// MARK: Prüfsumme

@Test func sha256KnownVectorsForDataAndFile() throws {
    #expect(Checksum.sha256(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("sha-\(UUID())")
    defer { try? FileManager.default.removeItem(at: url) }
    let big = Fixture.bytes(count: 9 << 20, seed: 1) // größer als ein Lesestück
    try big.write(to: url)
    #expect(try Checksum.sha256(ofFileAt: url) == Checksum.sha256(of: big))
}

// MARK: Platzprüfung

@Test func spaceCheckNeedsBuffer() {
    let gib: Int64 = 1 << 30
    #expect(SpaceCheck(needed: 3 * gib, available: 10 * gib).isEnough)
    // 3 GiB + 1 GiB + 0,3 GiB Puffer = 4,3 GiB
    #expect(!SpaceCheck(needed: 3 * gib, available: 4 * gib).isEnough)
    #expect(SpaceCheck(needed: 3 * gib, available: 4 * gib).shortfall > 0)
    let buffer = SpaceCheck(needed: 3 * gib, available: 0).buffer
    #expect(buffer == gib + 3 * gib / 10)
    #expect(SpaceCheck(needed: 3 * gib, available: 3 * gib + buffer).isEnough)
    #expect(!SpaceCheck(needed: 3 * gib, available: 3 * gib + buffer - 1).isEnough)
    // Nichts zu laden: immer genug.
    #expect(SpaceCheck(needed: 0, available: 0).isEnough)
    #expect(SpaceCheck.freeBytes(at: FileManager.default.temporaryDirectory.appendingPathComponent("gibt-es-nicht/x")) > 0)
}

@Test func installRefusesWithoutSpaceAndDoesNotTouchNetwork() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    let installer = fx.installer(freeSpace: { _ in 10_000 }) // viel zu wenig
    await #expect(throws: InstallError.self) { _ = try await collect(installer.install([fx.manifest])) }
    #expect(MockServer.requests(host: fx.host).isEmpty)
    #expect(fx.store.status(of: fx.manifest) == .missing)
    let plan = installer.plan([fx.manifest])
    #expect(!plan.space.isEnough)
    #expect(plan.downloadBytes == fx.manifest.totalBytes)
}

// MARK: Download

@Test func downloadsVerifiesAndMovesAtomically() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    #expect(fx.store.status(of: fx.manifest) == .missing)
    let events = try await collect(fx.installer().install([fx.manifest]))

    #expect(events.contains(.modelReady(fx.ref)))
    #expect(fx.store.status(of: fx.manifest) == .ready)
    for (path, data) in fx.files {
        #expect(try Data(contentsOf: fx.store.directory(for: fx.ref).appendingPathComponent(path)) == data)
    }
    #expect(!FileManager.default.fileExists(atPath: fx.store.stagingDirectory(for: fx.ref).path))
    #expect(try fx.store.verify(fx.manifest) == .ready)

    let last = try #require(lastProgress(events))
    #expect(last.bytesDone == last.bytesTotal)
    #expect(last.percent == 100)
    // Fortschritt springt nie rückwärts.
    let done = events.compactMap { if case let .progress(p) = $0 { p.bytesDone } else { nil } }
    #expect(done == done.sorted())
}

@Test func readyModelIsNotDownloadedAgain() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    _ = try await collect(fx.installer().install([fx.manifest]))
    let before = MockServer.requests(host: fx.host).count
    let events = try await collect(fx.installer().install([fx.manifest]))
    #expect(events.contains(.modelReady(fx.ref)))
    #expect(MockServer.requests(host: fx.host).count == before)
}

@Test func resumesAfterConnectionLoss() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    let big = "sub/weights.safetensors"
    // Erster Lauf: Verbindung reißt nach 10 000 Bytes der großen Datei ab.
    fx.serve { path, reply in if path == big { reply.failAfter = 10_000 } }
    let installer = fx.installer()
    await #expect(throws: InstallError.offline) { _ = try await collect(installer.install([fx.manifest])) }

    let part = fx.store.stagingDirectory(for: fx.ref).appendingPathComponent(big + ".part")
    #expect(ModelStore.fileSize(part) == 10_000)
    if case let .partial(present, total) = fx.store.status(of: fx.manifest) {
        #expect(present > 10_000 && present < total)
    } else {
        Issue.record("Zustand sollte .partial sein: \(fx.store.status(of: fx.manifest))")
    }

    // Zweiter Lauf: Server ist wieder da; es darf nur der Rest kommen.
    fx.serve()
    let events = try await collect(installer.install([fx.manifest]))
    #expect(fx.store.status(of: fx.manifest) == .ready)
    let ranged = MockServer.requests(host: fx.host).filter { $0.url!.path.hasSuffix(big) }
    #expect(ranged.count == 1)
    #expect(ranged.first?.value(forHTTPHeaderField: "Range") == "bytes=10000-")
    #expect(try Data(contentsOf: fx.store.directory(for: fx.ref).appendingPathComponent(big)) == fx.files[big])
    #expect(lastProgress(events)?.percent == 100)
}

@Test func resumesAfterPauseByCancelling() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    let big = "sub/weights.safetensors"
    fx.serve { path, reply in if path == big { reply.stallAfter = 12_000 } } // hängt nach 12 000 Bytes
    let installer = fx.installer()
    let task = Task { () -> Bool in
        do {
            for try await event in installer.install([fx.manifest]) {
                if case let .progress(p) = event, p.currentFile == big, p.bytesDone > 12_000 { return true }
            }
        } catch {}
        return false
    }
    // Warten, bis die Teildatei Bytes hat, dann „Pause“ = Abbrechen.
    let part = fx.store.stagingDirectory(for: fx.ref).appendingPathComponent(big + ".part")
    for _ in 0..<200 {
        if ModelStore.fileSize(part) >= 12_000 { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    task.cancel()
    _ = await task.value
    try await Task.sleep(for: .milliseconds(200))
    #expect(ModelStore.fileSize(part) == 12_000)
    #expect(fx.store.status(of: fx.manifest) != .ready)

    fx.serve()
    _ = try await collect(installer.install([fx.manifest]))
    #expect(fx.store.status(of: fx.manifest) == .ready)
}

@Test func serverIgnoringRangeRestartsFile() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    let big = "sub/weights.safetensors"
    fx.serve { path, reply in if path == big { reply.failAfter = 5_000 } }
    await #expect(throws: InstallError.offline) { _ = try await collect(fx.installer().install([fx.manifest])) }
    fx.serve(honorRange: false) // antwortet auf Range mit 200 und der ganzen Datei
    _ = try await collect(fx.installer().install([fx.manifest]))
    #expect(fx.store.status(of: fx.manifest) == .ready)
    #expect(try fx.store.verify(fx.manifest) == .ready)
}

@Test func checksumMismatchIsDetectedAndPartDeleted() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve { path, reply in
        if path == "vocab.json" { reply.body[0] ^= 0xFF } // gleiche Größe, anderer Inhalt
    }
    await #expect(throws: InstallError.checksumMismatch(path: "vocab.json")) {
        _ = try await collect(fx.installer().install([fx.manifest]))
    }
    let staging = fx.store.stagingDirectory(for: fx.ref)
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("vocab.json.part").path))
    #expect(!FileManager.default.fileExists(atPath: staging.appendingPathComponent("vocab.json").path))
    #expect(!fx.store.status(of: fx.manifest).isReady)
}

@Test func serverErrorIsReported() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve { path, reply in if path == "config.json" { reply = .init(status: 503) } }
    await #expect(throws: InstallError.server(status: 503)) { _ = try await collect(fx.installer().install([fx.manifest])) }
}

@Test func unreachableServerMeansOffline() async throws {
    let fx = try Fixture() // kein `serve`: Mock antwortet mit „Host nicht gefunden“
    defer { fx.cleanUp() }
    await #expect(throws: InstallError.offline) { _ = try await collect(fx.installer().install([fx.manifest])) }
}

// MARK: Zustände

@Test func statusDistinguishesMissingPartialReadyCorrupt() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    #expect(fx.store.status(of: fx.manifest) == .missing)
    _ = try await collect(fx.installer().install([fx.manifest]))
    #expect(fx.store.status(of: fx.manifest) == .ready)

    // Datei verkürzen → corrupt (schnelle Prüfung sieht die Größe).
    let dir = fx.store.directory(for: fx.ref)
    try Data("kurz".utf8).write(to: dir.appendingPathComponent("vocab.json"))
    #expect(fx.store.status(of: fx.manifest) == .corrupt(problems: ["vocab.json"]))

    // Gleiche Größe, anderer Inhalt → nur die volle Prüfung merkt es.
    try fx.files["vocab.json"]!.write(to: dir.appendingPathComponent("vocab.json"))
    var flipped = fx.files["config.json"]!
    flipped[0] ^= 0x01
    try flipped.write(to: dir.appendingPathComponent("config.json"))
    #expect(fx.store.status(of: fx.manifest) == .ready)
    #expect(try fx.store.verify(fx.manifest) == .corrupt(problems: ["config.json"]))

    // Reparatur: beschädigte Datei wird neu geladen, die anderen bleiben.
    fx.serve()
    _ = try await collect(fx.installer().install([fx.manifest], repair: true))
    #expect(try fx.store.verify(fx.manifest) == .ready)
    // Nur die beschädigte Datei kam erneut aus dem Netz (`serve` setzt das Protokoll zurück).
    let paths = MockServer.requests(host: fx.host).map { $0.url!.path }
    #expect(paths.count == 1 && paths[0].hasSuffix("config.json"))
}

@Test func missingMarkerMeansCorrupt() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    _ = try await collect(fx.installer().install([fx.manifest]))
    try FileManager.default.removeItem(at: fx.store.markerURL(for: fx.ref))
    #expect(fx.store.status(of: fx.manifest) == .corrupt(problems: [ModelStore.markerName]))
}

// MARK: HF-Cache-Import

@Test func importsFromHuggingFaceCacheWithoutNetwork() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve { _, _ in Issue.record("Es darf nichts aus dem Netz kommen") }
    let cache = try fx.makeHFCache()
    let installer = fx.installer(cache: cache)

    let plan = installer.plan([fx.manifest])
    #expect(plan.importBytes == fx.manifest.totalBytes)
    #expect(plan.downloadBytes == 0)
    #expect(plan.space.needed == 0) // Klonen kostet keinen Platz

    let events = try await collect(installer.install([fx.manifest]))
    #expect(fx.store.status(of: fx.manifest) == .ready)
    #expect(try fx.store.verify(fx.manifest) == .ready)
    #expect(MockServer.requests(host: fx.host).isEmpty)
    #expect(lastProgress(events)?.percent == 100)
    // Das Ergebnis ist eine eigene Datei, kein Symlink in den Cache.
    let target = fx.store.directory(for: fx.ref).appendingPathComponent("vocab.json")
    let values = try target.resourceValues(forKeys: [.isSymbolicLinkKey])
    #expect(values.isSymbolicLink == false)
}

@Test func corruptCacheFileFallsBackToDownload() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    let cache = try fx.makeHFCache(corrupt: ["vocab.json"]) // gleiche Größe, falscher Inhalt
    _ = try await collect(fx.installer(cache: cache).install([fx.manifest]))
    #expect(try fx.store.verify(fx.manifest) == .ready)
    let paths = MockServer.requests(host: fx.host).map { $0.url!.path }
    #expect(paths.count == 1 && paths[0].hasSuffix("vocab.json"))
}

@Test func cacheWithOtherRevisionIsIgnored() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    let other = try Fixture(files: fx.files, revision: String(repeating: "c", count: 40))
    defer { other.cleanUp() }
    let cache = try other.makeHFCache() // Snapshot einer anderen Revision
    _ = try await collect(fx.installer(cache: cache).install([fx.manifest]))
    #expect(MockServer.requests(host: fx.host).count == fx.files.count)
}

@Test func cloneSharesDiskBlocks() throws {
    // `clonefile` auf APFS: Kopie braucht (fast) keinen Platz.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clone-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let src = dir.appendingPathComponent("a"), dst = dir.appendingPathComponent("b")
    try Fixture.bytes(count: 1 << 20, seed: 9).write(to: src)
    let cloned = try HFCacheImporter.cloneOrCopy(from: src, to: dst)
    #expect(try Data(contentsOf: src) == Data(contentsOf: dst))
    // Der temporäre Ordner liegt auf APFS: es muss geklont (nicht kopiert) worden sein.
    #expect(cloned)
}

@Test func corruptFinalDirectoryIsRepairedInPlace() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    fx.serve()
    _ = try await collect(fx.installer().install([fx.manifest]))
    let dir = fx.store.directory(for: fx.ref)
    try Data("kaputt".utf8).write(to: dir.appendingPathComponent("sub/weights.safetensors"))
    #expect(!fx.store.status(of: fx.manifest).isReady)
    fx.serve()
    _ = try await collect(fx.installer().install([fx.manifest]))
    #expect(try fx.store.verify(fx.manifest) == .ready)
    // Nur die kaputte Datei wurde neu geladen.
    let paths = MockServer.requests(host: fx.host).map { $0.url!.path }
    #expect(paths.count == 1 && paths[0].hasSuffix("sub/weights.safetensors"))
}

@Test func locateWithoutBundledManifestNeedsMarker() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    #expect(fx.store.locate(fx.ref) == nil)
    fx.serve()
    _ = try await collect(fx.installer().install([fx.manifest]))
    #expect(fx.store.locate(fx.ref) == fx.store.directory(for: fx.ref))
}

@Test func prematureEndWithoutErrorKeepsPartAndMeansOffline() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }
    let big = "sub/weights.safetensors"
    fx.serve { path, reply in if path == big { reply.body = reply.body.prefix(10_000) } } // Server schließt zu früh
    await #expect(throws: InstallError.offline) { _ = try await collect(fx.installer().install([fx.manifest])) }
    let part = fx.store.stagingDirectory(for: fx.ref).appendingPathComponent(big + ".part")
    #expect(ModelStore.fileSize(part) == 10_000)
}

// MARK: Echter Server (nur mit VORLESER_NETWORK_TESTS=1; lädt nur winzige Dateien, nie die Gewichte)

private let networkTests = ProcessInfo.processInfo.environment["VORLESER_NETWORK_TESTS"] == "1"

@Test(.enabled(if: networkTests, "VORLESER_NETWORK_TESTS=1 setzen"))
func realHuggingFaceDownloadOfSmallFilesAndRangeSupport() async throws {
    let ref = ModelRef(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit", revision: "37e955a1deb861c088ae5f3a67043185f3d1a60c")
    let full = try #require(ModelManifest.bundled(for: ref))
    let small = ModelManifest(repo: ref.repo, revision: ref.revision,
                              files: full.files.filter { ["config.json", "speech_tokenizer/config.json", "preprocessor_config.json"].contains($0.path) })
    #expect(small.files.count == 3)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let installer = ModelInstaller(store: ModelStore(root: dir), cache: nil)
    _ = try await collect(installer.install([small]))
    #expect(try ModelStore(root: dir).verify(small) == .ready)

    // Range über die Weiterleitung zum CDN: 1000 Bytes ab Offset 5000 der großen Datei, Antwort 206.
    let big = try #require(full.files.first { $0.path == "model.safetensors" })
    var request = URLRequest(url: URL(string: "https://huggingface.co/\(ref.repo)/resolve/\(ref.revision)/\(big.path)")!)
    request.setValue("bytes=5000-5999", forHTTPHeaderField: "Range")
    let (data, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 206)
    #expect(data.count == 1000)
}
