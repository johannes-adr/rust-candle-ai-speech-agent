import AVFoundation
import AudioOut
import Foundation
import Projects
import VorleserSpeech
import Testing
import TextPrep
@testable import Pipeline

// MARK: Hilfen

private struct Env {
    var base: URL
    var store: ProjectStore
    var out: URL { base.appending(path: "Out/buch.mp3") }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private func makeEnv() -> Env {
    let base = FileManager.default.temporaryDirectory
        .appending(path: "vorleser-pipeline-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    return Env(base: base, store: ProjectStore(root: base.appending(path: "Projects"), outputDirectory: base.appending(path: "Out")))
}

private let voice = Voice(
    id: "own-test", name: "Testa", language: .de, kind: .recorded,
    referenceAudio: URL(fileURLWithPath: "/dev/null"), referenceText: "Hallo.")

/// n Absätze mit je ca. 230 Zeichen → n Abschnitte.
private let names = ["Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf", "Hotel"]

private func document(paragraphs n: Int, headings: Bool = false) -> TextDocument {
    var blocks: [TextBlock] = []
    for i in 1...n {
        if headings, i == 1 || i == n / 2 + 1 { blocks.append(.heading(level: 1, text: "Teil \(i)")) }
        blocks.append(.paragraph(
            "Absatz \(names[i - 1]) erzählt von einem ruhigen Morgen am See. Die Sonne steigt langsam über die Hügel, und im Dorf gehen die ersten Fenster auf. Eine alte Frau trägt ihren Korb zum Markt und grüßt jeden, den sie trifft."))
    }
    return TextDocument(title: "Buch", blocks: blocks)
}

private func request(_ doc: TextDocument, hash: String = "h1", env: Env, tempo: Double = 1.0) -> SynthesisRequest {
    SynthesisRequest(
        title: "Buch", source: .document(doc, sourceHash: hash, kind: "text"), language: .de, voice: voice,
        style: "calm", tempo: tempo, outputURL: env.out)
}

private func config() -> SynthesisConfig {
    var c = SynthesisConfig()
    c.idleUnloadSeconds = 3_600
    c.preventSleep = false
    return c
}

@discardableResult
private func collect(_ job: SynthesisJob, _ req: SynthesisRequest) async -> [SynthesisEvent] {
    var events: [SynthesisEvent] = []
    for await e in job.start(req) { events.append(e) }
    return events
}

private func result(_ events: [SynthesisEvent]) -> SynthesisResult? {
    for e in events { if case let .finished(r) = e { return r } }
    return nil
}

private func mp3Seconds(_ url: URL) throws -> Double {
    let f = try AVAudioFile(forReading: url)
    return Double(f.length) / f.processingFormat.sampleRate
}

// MARK: Tests

@Test func happyPathWritesMP3AndReportsProgress() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let engine = FakeEngine()
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    let events = await collect(job, request(document(paragraphs: 4), env: env))

    let r = try #require(result(events))
    #expect(r.chunkCount == 4)
    #expect(r.resumed == false)
    #expect(r.retryCount == 0)
    #expect(r.suspicious.isEmpty)
    #expect(FileManager.default.fileExists(atPath: r.fileURL.path))
    // Dauer der MP3 ≈ gemeldete Dauer (Tempo 1, Pausen inklusive).
    #expect(abs(try mp3Seconds(r.fileURL) - r.durationSeconds) < 0.2)
    #expect(r.durationSeconds > 4 * 10)

    var done = 0
    var lastFraction = 0.0
    for e in events {
        if case let .chunkDone(p) = e {
            done += 1
            #expect(p.chunksDone == done)
            #expect(p.fraction >= lastFraction)
            lastFraction = p.fraction
            #expect(FileManager.default.fileExists(atPath: p.fileURL.path))
        }
    }
    #expect(done == 4)
    #expect(lastFraction == 1)
    #expect(await engine.loadCount == 1)
    #expect(await engine.prepareCount == 1)
    // Zustand im Manifest.
    let p = try await env.store.load(id: r.projectID)
    #expect(p.state == .finished)
    #expect(p.chunks.allSatisfy { $0.status == .done && $0.attempts == 1 })
}

@Test func retriesWithNewSeedThenSucceeds() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    // Der zweite Abschnitt liefert beim ersten Versuch NaN, beim zweiten Mal zu kurz, dann gut.
    let engine = FakeEngine { text, attempt in
        guard text.contains("Bravo") else { return .good }
        return attempt == 0 ? .nan : attempt == 1 ? .tooShort : .good
    }
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    let events = await collect(job, request(document(paragraphs: 3), env: env))
    let r = try #require(result(events))
    #expect(r.retryCount == 2)
    #expect(r.suspicious.count == 2)
    #expect(r.suspicious[0].issues.contains(.nonFinite))
    #expect(r.suspicious[0].willRetry)
    #expect(r.suspicious[1].issues.contains(.tooShort))
    let calls = await engine.calls.filter { $0.text.contains("Bravo") }
    #expect(calls.count == 3)
    #expect(Set(calls.map(\.seed)).count == 3, "jeder Versuch braucht einen neuen Seed")
    let p = try await env.store.load(id: r.projectID)
    let c = try #require(p.chunks.first { $0.chunk.text.contains("Bravo") })
    #expect(c.status == .done)
    #expect(c.attempts == 3)
    #expect(c.seed == calls.last?.seed)
}

@Test func keepsAndMarksAfterTwoRetries() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let engine = FakeEngine { text, _ in text.contains("Bravo") ? .tooShort : .good }
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    let events = await collect(job, request(document(paragraphs: 3), env: env))
    let r = try #require(result(events))
    #expect(r.retryCount == 2)
    #expect(await engine.calls.filter { $0.text.contains("Bravo") }.count == 3)
    #expect(r.suspicious.last?.kept == true)
    #expect(r.suspicious.last?.willRetry == false)
    let p = try await env.store.load(id: r.projectID)
    let c = try #require(p.chunks.first { $0.chunk.text.contains("Bravo") })
    #expect(c.status == .suspicious)
    #expect(c.qc?.issues.contains(.tooShort) == true)
    // Behalten: die MP3 enthält ihn trotzdem.
    #expect(r.failedChunks.isEmpty)
    #expect(FileManager.default.fileExists(atPath: r.fileURL.path))
}

@Test func nanIsCleanedAndSilentChunkIsFlagged() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let engine = FakeEngine { text, _ in text.contains("Alpha") ? .nan : text.contains("Bravo") ? .silent : .good }
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    let events = await collect(job, request(document(paragraphs: 3), env: env))
    let r = try #require(result(events))
    // Stille hat keine verwertbaren Samples; NaN wird auf 0 gesetzt und bleibt hörbar.
    let p = try await env.store.load(id: r.projectID)
    let nan = try #require(p.chunks.first { $0.chunk.text.contains("Alpha") })
    #expect(nan.status == .suspicious)
    #expect(nan.qc?.nonFiniteCount == 2)
    let (samples, _) = try env.store.chunkStore(for: r.projectID).read(index: nan.chunk.index)
    #expect(samples.allSatisfy { $0.isFinite })
    #expect(r.failedChunks.count == 1)
    #expect(await engine.calls.filter { $0.text.contains("Bravo") }.count == 3)
}

@Test func tooLongIsDetected() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let engine = FakeEngine { text, attempt in text.contains("Alpha") && attempt == 0 ? .tooLong : .good }
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    let r = try #require(result(await collect(job, request(document(paragraphs: 2), env: env))))
    #expect(r.suspicious.first?.issues == [.tooLong])
    #expect(r.retryCount == 1)
}

@Test func abortsAfterRepeatedEngineFailures() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let engine = FakeEngine { _, _ in .fail }
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    let events = await collect(job, request(document(paragraphs: 6), env: env))
    #expect(result(events) == nil)
    guard case let .failed(f)? = events.last else { Issue.record("kein .failed am Ende"); return }
    guard case .engineFailed = f else { Issue.record("falscher Fehler \(f)"); return }
    #expect(f.reasonKey == "problem.generic")
    // 3 Abschnitte × 3 Versuche, dann Schluss.
    #expect(await engine.calls.count == 9)
}

@Test func resumesAfterCancelWithoutRedoingChunks() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let doc = document(paragraphs: 6)
    let engine1 = FakeEngine(delay: .milliseconds(30))
    let job1 = SynthesisJob(engine: engine1, store: env.store, config: config())
    var stopped = false
    var doneCount = 0
    for await e in job1.start(request(doc, env: env)) {
        if case .chunkDone = e {
            doneCount += 1
            if doneCount == 2 { await job1.cancel() }
        }
        if case .stopped = e { stopped = true }
    }
    #expect(stopped)
    let list = await env.store.list()
    #expect(list.count == 1)
    let before = try await env.store.load(id: list[0].id)
    let doneBefore = before.chunks.filter { $0.status == .done }.count
    #expect(doneBefore >= 2 && doneBefore < 6)
    #expect(before.state == .synthesizing)
    #expect(!FileManager.default.fileExists(atPath: env.out.path))

    // Neuer Start (wie nach Neustart der App): gleiches Dokument → weitermachen.
    let engine2 = FakeEngine()
    let job2 = SynthesisJob(engine: engine2, store: env.store, config: config())
    let events = await collect(job2, request(doc, env: env))
    let r = try #require(result(events))
    #expect(r.resumed)
    #expect(r.projectID == before.id)
    #expect(r.chunksSynthesized == 6 - doneBefore)
    #expect(await engine2.calls.count == 6 - doneBefore)
    #expect(FileManager.default.fileExists(atPath: r.fileURL.path))
    #expect(await env.store.list().count == 1)
    let projectReady = events.compactMap { e -> Int? in
        if case let .projectReady(_, _, _, done, _) = e { done } else { nil }
    }
    #expect(projectReady == [doneBefore])
}

@Test func resumesAfterCrashWithBrokenFiles() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let doc = document(paragraphs: 4)
    let first = try #require(result(await collect(
        SynthesisJob(engine: FakeEngine(), store: env.store, config: config()), request(doc, env: env))))
    // „Absturz“: eine fertige CAF fehlt, eine ist halb geschrieben, eine Teildatei liegt herum.
    let files = env.store.chunkStore(for: first.projectID)
    try FileManager.default.removeItem(at: files.url(forIndex: 1))
    try Data([1, 2, 3]).write(to: files.url(forIndex: 2))
    try Data([9]).write(to: files.directory.appending(path: "0003.part.caf"))
    try FileManager.default.removeItem(at: env.out)

    let engine = FakeEngine()
    let r = try #require(result(await collect(
        SynthesisJob(engine: engine, store: env.store, config: config()), request(doc, env: env))))
    #expect(r.resumed)
    #expect(r.chunksSynthesized == 2)
    #expect(Set(await engine.calls.map(\.text)).count == 2)
    #expect(FileManager.default.fileExists(atPath: r.fileURL.path))
    #expect(await env.store.list().count == 1)
}

@Test func differentStyleStartsNewProject() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let doc = document(paragraphs: 2)
    let job = SynthesisJob(engine: FakeEngine(), store: env.store, config: config())
    var a = request(doc, env: env); a.style = "calm"
    var b = request(doc, env: env); b.style = "happy"
    let ra = try #require(result(await collect(job, a)))
    let rb = try #require(result(await collect(job, b)))
    #expect(ra.projectID != rb.projectID)
    #expect(rb.resumed == false)
}

@Test func chaptersProduceFolderWithOneMP3PerChapter() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let engine = FakeEngine()
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    let r = try #require(result(await collect(job, request(document(paragraphs: 4, headings: true), env: env))))
    #expect(r.chapterFiles.count == 2)
    #expect(r.chapterFiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    #expect(r.chapterFiles[0].lastPathComponent.contains("Teil 1"))
    let sum = try r.chapterFiles.map(mp3Seconds).reduce(0, +)
    #expect(abs(sum - r.durationSeconds) < 2.5)
}

@Test func chapterFilesCanBeSwitchedOff() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let job = SynthesisJob(engine: FakeEngine(), store: env.store, config: config())
    var req = request(document(paragraphs: 4, headings: true), env: env)
    req.writeChapterFiles = false
    let r = try #require(result(await collect(job, req)))
    #expect(r.chapterFiles.isEmpty)
    #expect(FileManager.default.fileExists(atPath: r.fileURL.path))
    let folder = r.fileURL.deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    #expect(names.allSatisfy { !$0.contains("Teil") }, "kein Kapitelordner")
}

@Test func tempoShortensOutput() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let doc = document(paragraphs: 3)
    let normal = try #require(result(await collect(
        SynthesisJob(engine: FakeEngine(), store: env.store, config: config()), request(doc, hash: "a", env: env))))
    let fast = try #require(result(await collect(
        SynthesisJob(engine: FakeEngine(), store: env.store, config: config()), request(doc, hash: "b", env: env, tempo: 1.2))))
    #expect(fast.durationSeconds < normal.durationSeconds * 0.95)
}

@Test func id3TagsAreWritten() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let r = try #require(result(await collect(
        SynthesisJob(engine: FakeEngine(), store: env.store, config: config()),
        request(document(paragraphs: 2), env: env))))
    let data = try Data(contentsOf: r.fileURL)
    #expect(data.prefix(3) == Data("ID3".utf8))
    // ID3v2 kann Text als UTF-16 ablegen; Nullbytes zum Vergleichen entfernen.
    let head = String(decoding: data.prefix(600).filter { $0 != 0 }, as: UTF8.self)
    #expect(head.contains("Buch"))
    #expect(head.contains("Testa"))
    #expect(head.contains("Mit KI vorgelesen"))
}

@Test func pauseHoldsBackNextChunk() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let engine = FakeEngine(delay: .milliseconds(20))
    let job = SynthesisJob(engine: engine, store: env.store, config: config())
    var sawPaused = false
    var sawResumed = false
    var chunks = 0
    for await e in job.start(request(document(paragraphs: 4), env: env)) {
        switch e {
        case .chunkDone:
            chunks += 1
            if chunks == 1 {
                await job.pause()
                Task { try? await Task.sleep(for: .milliseconds(400)); await job.resume() }
            }
        case .paused: sawPaused = true; #expect(chunks <= 2)
        case .resumed: sawResumed = true
        default: break
        }
    }
    #expect(sawPaused && sawResumed)
}

@Test func thermalPressureInsertsPause() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    var c = config()
    c.thermalState = { .serious }
    c.thermalPauseSeconds = 0.01
    let events = await collect(SynthesisJob(engine: FakeEngine(), store: env.store, config: c),
                               request(document(paragraphs: 2), env: env))
    let cooling = events.filter { if case .coolingDown = $0 { true } else { false } }
    #expect(cooling.count == 2)
    #expect(result(events) != nil)
}

@Test func unloadsAfterIdle() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    var c = config()
    c.idleUnloadSeconds = 0.2
    let engine = FakeEngine()
    let job = SynthesisJob(engine: engine, store: env.store, config: c)
    _ = await collect(job, request(document(paragraphs: 2), env: env))
    #expect(await engine.unloadCount == 0)
    try await Task.sleep(for: .milliseconds(600))
    #expect(await engine.unloadCount == 1)

    // Ein neuer Auftrag vor Ablauf der Frist verhindert das Entladen.
    let engine2 = FakeEngine()
    let job2 = SynthesisJob(engine: engine2, store: env.store, config: c)
    _ = await collect(job2, request(document(paragraphs: 2), hash: "z", env: env))
    _ = await collect(job2, request(document(paragraphs: 2), hash: "y", env: env))
    #expect(await engine2.unloadCount == 0)
}

@Test func secondJobWhileRunningIsRejected() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let job = SynthesisJob(engine: FakeEngine(delay: .milliseconds(100)), store: env.store, config: config())
    let first = job.start(request(document(paragraphs: 3), env: env))
    try await Task.sleep(for: .milliseconds(50))
    let second = await collect(job, request(document(paragraphs: 3), hash: "other", env: env))
    guard case .failed(.busy)? = second.last else { Issue.record("erwartet .busy, war \(second)"); return }
    for await _ in first {}
}

@Test func emptyDocumentFails() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let job = SynthesisJob(engine: FakeEngine(), store: env.store, config: config())
    let events = await collect(job, request(TextDocument(title: nil, blocks: []), env: env))
    guard case .failed(.noText)? = events.last else { Issue.record("erwartet .noText"); return }
}

@Test func languageIsDetectedWhenMissing() async throws {
    let env = makeEnv(); defer { env.cleanup() }
    let job = SynthesisJob(engine: FakeEngine(), store: env.store, config: config())
    var req = request(document(paragraphs: 2), env: env)
    req.language = nil
    let r = try #require(result(await collect(job, req)))
    #expect(r.language == .de)
}

@Test func speechRateTableMatchesFake() {
    #expect(SpeechRate.charsPerSecond(for: .de) == SpeechRateForTests.de)
    for l in Language.allCases { #expect(SpeechRate.charsPerSecond(for: l) > 3) }
    #expect(SpeechRate.charsPerSecond(for: .zh) < SpeechRate.charsPerSecond(for: .de) / 2)
}

@Test func pageIndicesAreProportional() {
    let chunks = (0..<10).map {
        Chunk(index: $0, text: String(repeating: "a", count: 100), spokenText: "a", kind: .sentence, chapter: 0)
    }
    let pages = SynthesisJob.pageIndices(for: chunks, pageCount: 5)
    #expect(pages?.count == 10)
    #expect(pages?.first == 0)
    #expect(pages?.last == 4)
    #expect(SynthesisJob.pageIndices(for: chunks, pageCount: 1) == nil)
}
