import AudioOut
import Foundation
import Testing
import TextPrep
@testable import Projects

private struct Boom: Error {}

private func makeStore() -> (ProjectStore, URL) {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "vorleser-projects-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ProjectStore(root: base.appending(path: "Projects"), outputDirectory: base.appending(path: "Out"))
    return (store, base)
}

private func sampleChunks(_ n: Int = 4) -> [Chunk] {
    (0..<n).map {
        Chunk(index: $0 + 1, text: "Satz \($0 + 1) mit etwas Text.", spokenText: "Satz \($0 + 1) mit etwas Text.",
              kind: .sentence, chapter: 0)
    }
}

private func makeProject(_ store: ProjectStore, hash: String = "h1", voice: String = "oma", n: Int = 4,
                         pages: [Int?]? = nil) async throws -> Project {
    try await store.create(
        title: "Buch", sourceHash: hash, sourceKind: "pdf", sourceData: Data("x".utf8),
        sourceExtension: "pdf", language: .de, voiceID: voice, chunks: sampleChunks(n), pageIndices: pages)
}

private func writeCAF(_ store: ProjectStore, _ id: UUID, index: Int) throws {
    try store.chunkStore(for: id).write([Float](repeating: 0.1, count: 2400), sampleRate: 24000, index: index)
}

@Test func codableRoundtrip() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store)
    let big = SeedDerivation.seed(projectID: p.id, chunkIndex: 1, attempt: 0)
    try writeCAF(store, p.id, index: 1)
    try await store.markChunkDone(id: p.id, chunkIndex: 1, duration: 1.5, computeSeconds: 0.4, seed: big)
    let loaded = try await store.load(id: p.id)
    #expect(loaded.chunks[0].seed == big)
    #expect(loaded.chunks[0].status == .done)
    #expect(loaded.schemaVersion == 1)
    #expect(loaded.sourceFileName == "source.pdf")
    let data = try JSONEncoder().encode(loaded)
    #expect(try JSONDecoder().decode(Project.self, from: data) == loaded)
}

@Test func seedIsDeterministicAndDistinct() {
    let id = UUID()
    #expect(SeedDerivation.seed(projectID: id, chunkIndex: 3, attempt: 1) == SeedDerivation.seed(projectID: id, chunkIndex: 3, attempt: 1))
    #expect(SeedDerivation.seed(projectID: id, chunkIndex: 3, attempt: 1) != SeedDerivation.seed(projectID: id, chunkIndex: 3, attempt: 2))
    #expect(SeedDerivation.seed(projectID: id, chunkIndex: 3, attempt: 1) != SeedDerivation.seed(projectID: id, chunkIndex: 4, attempt: 1))
    #expect(SeedDerivation.seed(projectID: id, chunkIndex: 3, attempt: 1) != SeedDerivation.seed(projectID: UUID(), chunkIndex: 3, attempt: 1))
}

@Test func sourceHashIsSHA256() {
    #expect(SourceHash.hex(of: "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func abortedWriteKeepsOldManifest() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store)
    let before = try Data(contentsOf: store.manifestURL(for: p.id))
    var changed = p
    changed.title = "Anders"
    await #expect(throws: Boom.self) {
        try await store.save(&changed, touch: true, beforeCommit: { throw Boom() })
    }
    #expect(try Data(contentsOf: store.manifestURL(for: p.id)) == before)
    let files = try FileManager.default.contentsOfDirectory(atPath: store.directory(for: p.id).path)
    #expect(!files.contains { $0.hasSuffix(".tmp") })
    #expect(try await store.load(id: p.id).title == "Buch")
}

@Test func resumeAfterSimulatedCrash() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store)
    for i in 1...3 {
        try writeCAF(store, p.id, index: i)
        try await store.markChunkDone(id: p.id, chunkIndex: i, duration: 0.1, computeSeconds: 0.05)
    }
    // Absturz: CAF 2 fehlt, CAF 3 ist Müll.
    try FileManager.default.removeItem(at: store.chunkStore(for: p.id).url(forIndex: 2))
    try Data("kaputt".utf8).write(to: store.chunkStore(for: p.id).url(forIndex: 3))

    let fresh = ProjectStore(root: store.rootDirectory, outputDirectory: store.outputDirectory)
    let loaded = try await fresh.load(id: p.id)
    #expect(loaded.chunks.map(\.status) == [.done, .pending, .pending, .pending])
    #expect(try await fresh.nextPendingChunk(id: p.id)?.chunk.index == 2)
    // Korrektur wurde gespeichert.
    let again = try await ProjectStore(root: store.rootDirectory, outputDirectory: store.outputDirectory).load(id: p.id)
    #expect(again.chunks[1].status == .pending)
}

@Test func markSuspiciousAndFailed() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store)
    try writeCAF(store, p.id, index: 1)
    try await store.markChunkSuspicious(id: p.id, chunkIndex: 1, duration: 0.1)
    try await store.markChunkFailed(id: p.id, chunkIndex: 2, error: "NaN")
    let l = try await store.load(id: p.id)
    #expect(l.chunks[0].status == .suspicious)
    #expect(l.chunks[1].status == .failed && l.chunks[1].lastError == "NaN" && l.chunks[1].attempts == 1)
    #expect(try await store.nextPendingChunk(id: p.id)?.chunk.index == 3)
    let s0 = try await store.seed(id: p.id, chunkIndex: 2)
    #expect(s0 == SeedDerivation.seed(projectID: p.id, chunkIndex: 2, attempt: 1))
    await #expect(throws: ProjectStoreError.chunkOutOfRange(99)) {
        try await store.markChunkFailed(id: p.id, chunkIndex: 99, error: "x")
    }
}

@Test func findExistingMatchesAllThree() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, hash: "A", voice: "oma")
    _ = try await makeProject(store, hash: "B", voice: "oma")
    #expect(await store.findExisting(sourceHash: "A", language: .de, voiceID: "oma")?.id == p.id)
    #expect(await store.findExisting(sourceHash: "A", language: .de, voiceID: "opa") == nil)
    #expect(await store.findExisting(sourceHash: "A", language: .pt, voiceID: "oma") == nil)
}

@Test func listSortedByUpdatedAndDelete() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let a = try await makeProject(store, hash: "A")
    let b = try await makeProject(store, hash: "B")
    try await Task.sleep(for: .milliseconds(20))
    try await store.setState(.synthesizing, id: a.id)
    #expect(await store.list().map(\.id) == [a.id, b.id])
    try await store.delete(id: a.id)
    #expect(await store.list().map(\.id) == [b.id])
    // Nichts außerhalb der temporären Ordner.
    #expect(store.rootDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
}

@Test func outputURLSanitizesTitle() {
    let (store, _) = makeStore()
    #expect(store.outputURL(title: "A/B: C?").lastPathComponent == "A B  C.mp3")
    #expect(store.outputURL(title: "  ").lastPathComponent == "Vorgelesen.mp3")
}

@Test func etaUsesMovingAverageAndPages() {
    func pc(_ i: Int, _ status: ChunkStatus, compute: Double? = nil, page: Int) -> ProjectChunk {
        ProjectChunk(
            chunk: Chunk(index: i, text: String(repeating: "a", count: 100), spokenText: String(repeating: "a", count: 100),
                         kind: .sentence, chapter: 0),
            status: status, computeSeconds: compute, pageIndex: page)
    }
    let none = ETAEstimator().estimate(for: [pc(1, .pending, page: 0), pc(2, .pending, page: 1)])
    #expect(none.remainingSeconds == nil && none.progress == 0)

    // Fenster 2: nur die letzten beiden (je 10 s / 100 Zeichen = 0,1 s/Zeichen) zählen, nicht die 1 s.
    let chunks = [pc(1, .done, compute: 1, page: 0), pc(2, .done, compute: 10, page: 0),
                  pc(3, .done, compute: 10, page: 1), pc(4, .pending, page: 1), pc(5, .pending, page: 2)]
    let e = ETAEstimator(window: 2).estimate(for: chunks)
    #expect(abs(e.remainingSeconds! - 20) < 1e-9)
    #expect(abs(e.progress - 0.6) < 1e-9)
    #expect(e.currentPage == 2 && e.totalPages == 3)

    let done = ETAEstimator().estimate(for: [pc(1, .done, compute: 1, page: 0)])
    #expect(done.remainingSeconds == 0 && done.progress == 1)
}
