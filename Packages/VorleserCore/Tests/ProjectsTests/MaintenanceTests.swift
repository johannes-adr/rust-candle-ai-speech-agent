import AudioOut
import Foundation
import Testing
import TextPrep
@testable import Projects

private func makeStore() -> (ProjectStore, URL) {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "vorleser-maint-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    let store = ProjectStore(root: base.appending(path: "Projects"), outputDirectory: base.appending(path: "Out"))
    return (store, base)
}

private func chunks(_ n: Int) -> [Chunk] {
    (1...n).map { Chunk(index: $0, text: "Satz \($0) mit Text.", spokenText: "Satz \($0) mit Text.", kind: .sentence, chapter: 0) }
}

/// Projekt mit `n` fertigen Abschnitten (CAF vorhanden); mit `finished` auch Zustand fertig und MP3 im Ablageordner.
private func makeProject(_ store: ProjectStore, n: Int = 3, finished: Bool, mp3: Bool = true, title: String = "Brief") async throws -> Project {
    let p = try await store.create(
        title: title, sourceHash: UUID().uuidString, sourceKind: "pdf", sourceData: Data("quelle".utf8),
        sourceExtension: "pdf", language: .de, voiceID: "oma", chunks: chunks(n))
    for i in 1...n {
        try store.chunkStore(for: p.id).write([Float](repeating: 0.1, count: 24_000), sampleRate: 24000, index: i)
        try await store.markChunkDone(id: p.id, chunkIndex: i, duration: 1)
    }
    if finished {
        try await store.setState(.finished, id: p.id)
        if mp3 {
            try FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 5000).write(to: store.outputURL(title: title))
        }
    }
    return try await store.load(id: p.id)
}

@Test func cleanupDeletesOnlyChunksOfFinishedProject() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, finished: true)
    let mp3 = store.outputURL(title: p.title)
    let before = await store.diskUsage(id: p.id)
    #expect(before.intermediates > 0)
    #expect(before.mp3 == 5000)

    let freed = try await store.cleanIntermediates(id: p.id)
    #expect(freed == before.intermediates)
    let dir = store.directory(for: p.id)
    #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "chunks").path))
    // Alles andere bleibt: Manifest, Quelle, MP3.
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "manifest.json").path))
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "source.pdf").path))
    #expect(FileManager.default.fileExists(atPath: mp3.path))
    // Bleibt fertig, wird nicht wieder „offen“ (reconcile ignoriert aufgeräumte Projekte), und ist neu ladbar.
    let again = try await store.load(id: p.id)
    #expect(again.state == .finished)
    #expect(again.intermediatesRemoved == true)
    #expect(again.chunks.allSatisfy { $0.status == .done })
    let summary = await store.list().first
    #expect(summary?.state == .finished)
    #expect(summary?.progress == 1)
    // Zweites Aufräumen: nichts mehr zu tun, kein Fehler, und die Liste bietet es nicht mehr an.
    #expect(try await store.cleanIntermediates(id: p.id) == 0)
    #expect(await store.overview().first?.canCleanIntermediates == false)
}

@Test func cleanupRefusesUnfinishedProjectAndKeepsChunks() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, finished: false)
    await #expect(throws: ProjectCleanupError.notFinished) { try await store.cleanIntermediates(id: p.id) }
    #expect(await store.chunkStore(for: p.id).existingIndices() == [1, 2, 3])
    #expect(await store.overview().first?.canCleanIntermediates == false)
}

@Test func cleanupRefusesWhenMP3IsMissing() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, finished: true, mp3: false)
    await #expect(throws: ProjectCleanupError.outputMissing) { try await store.cleanIntermediates(id: p.id) }
    #expect(await store.chunkStore(for: p.id).existingIndices() == [1, 2, 3])
    #expect(await store.overview().first?.canCleanIntermediates == false)
}

@Test func cleanupTouchesOnlyTheChosenProject() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let a = try await makeProject(store, finished: true, title: "A")
    let b = try await makeProject(store, finished: true, title: "B")
    try await store.cleanIntermediates(id: a.id)
    #expect(await store.chunkStore(for: b.id).existingIndices() == [1, 2, 3])
    let overview = await store.overview()
    #expect(overview.first { $0.id == b.id }?.canCleanIntermediates == true)
    #expect(overview.first { $0.id == a.id }?.canCleanIntermediates == false)
}

@Test func deletingProjectKeepsMP3() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, finished: true)
    try await store.delete(id: p.id)
    #expect(!FileManager.default.fileExists(atPath: store.directory(for: p.id).path))
    #expect(FileManager.default.fileExists(atPath: store.outputURL(title: p.title).path))
    #expect(await store.list().isEmpty)
}

@Test func oldManifestWithoutFlagStillLoads() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, finished: true)
    let json = try String(contentsOf: store.manifestURL(for: p.id), encoding: .utf8)
    #expect(!json.contains("intermediatesRemoved"))  // nil wird nicht geschrieben
    let loaded = try await store.load(id: p.id)
    #expect(loaded.intermediatesRemoved == nil)
}

// MARK: Protokoll

private func qc(_ issues: [QCIssue]) -> ChunkQCReport {
    // ChunkQCReport hat keinen öffentlichen Initialisierer; über das Manifest-Format erzeugen.
    let json = """
    {"sampleRate":24000,"originalDurationSeconds":1,"trimmedDurationSeconds":1,"leadingSilenceSeconds":0,
     "trailingSilenceSeconds":0,"nonFiniteCount":0,"clippingFraction":0,"peakDBFS":-3,"rmsDBFS":-20,
     "expectedDurationSeconds":5,"durationRatio":0.2,"issues":[\(issues.map { "\"\($0.rawValue)\"" }.joined(separator: ","))]}
    """
    return try! JSONDecoder().decode(ChunkQCReport.self, from: Data(json.utf8))
}

@Test func protocolListsSuspiciousAndFailedChunks() async throws {
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, n: 4, finished: false)
    try await store.markChunkSuspicious(id: p.id, chunkIndex: 2, duration: 0.8, qc: qc([.tooShort]), attemptsUsed: 3)
    try await store.markChunkFailed(id: p.id, chunkIndex: 4, error: "NaN im Sampling")
    let project = try await store.load(id: p.id)
    let problems = ProblemProtocol.problems(in: project)
    #expect(problems.entries.map(\.chunkIndex) == [2, 4])
    #expect(problems.entries[0].status == .suspicious)
    #expect(problems.entries[0].issues == ["tooShort"])
    #expect(problems.entries[0].text == "Satz 2 mit Text.")
    #expect(problems.entries[1].error == "NaN im Sampling")

    let text = ProblemProtocol.render([problems], header: ["Vorleser 0.1.0", "macOS 26.6"], log: "2026 INFO [x] hallo")
    #expect(text.contains("Vorleser 0.1.0"))
    #expect(text.contains("Abschnitt 2 · suspicious · 4 Versuch(e)"))
    #expect(text.contains("tooShort"))
    #expect(text.contains("Fehler: NaN im Sampling"))
    #expect(text.contains("Text: Satz 4 mit Text."))
    #expect(text.contains("hallo"))
}

@Test func protocolShortensLongTextAndSaysWhenClean() async throws {
    let long = String(repeating: "wort ", count: 200)
    #expect(ProblemProtocol.shorten(long).count == ProblemProtocol.maxTextLength + 1)
    #expect(ProblemProtocol.shorten("a\nb") == "a b")
    let (store, base) = makeStore()
    defer { try? FileManager.default.removeItem(at: base) }
    let p = try await makeProject(store, finished: true)
    let problems = ProblemProtocol.problems(in: try await store.load(id: p.id))
    #expect(problems.entries.isEmpty)
    #expect(ProblemProtocol.render([problems], header: []).contains("Keine Auffälligkeiten"))
    #expect(await store.recentProblems(onlyWithProblems: true).isEmpty)
    #expect(await store.recentProblems().count == 1)
}

// MARK: Protokolldatei

@Test func eventLogAppendsRotatesAndTails() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vorleser-log-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: dir) }
    let log = EventLog(directory: dir, maxBytes: 300)
    for i in 0..<20 { log.write(.info, "test", "Zeile \(i)") }
    log.write(.error, "test", "Ende\nmit Umbruch")
    #expect(FileManager.default.fileExists(atPath: log.fileURL.path))
    #expect(FileManager.default.fileExists(atPath: log.rotatedURL.path), "Rotation nach maxBytes")
    let tail = log.tail(lines: 3)
    #expect(tail.split(separator: "\n").count == 3)
    #expect(tail.contains("FEHLER [test] Ende mit Umbruch"))
}
