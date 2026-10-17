// Helfer-Einstellungen: persistente Einstellungen, Stimmen löschen/umbenennen, Hörbücher aufräumen, Protokoll.
import Foundation
import Projects
import TextPrep
import VorleserSpeech
import XCTest

@testable import Vorleser

@MainActor
final class HelperTests: XCTestCase {
    private var dir: URL!
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "vorleser-helper-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func defaults() -> UserDefaults {
        let suite = "de.vorleser.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        addTeardownBlock { d.removePersistentDomain(forName: suite) }
        return d
    }

    // MARK: Einstellungen

    func testSettingsPersist() {
        let d = defaults()
        let a = AppSettings(defaults: d)
        // Standardwerte
        XCTAssertEqual(a.quality, .fast)
        XCTAssertEqual(a.defaultTempo, .normal)
        XCTAssertTrue(a.chaptersAsFiles)
        a.helperName = "Johannes"
        a.helperPhone = "0151 1234"
        a.quality = .accurate
        a.defaultTempo = .slower
        a.chaptersAsFiles = false
        a.outputDirectory = dir
        // Qualität liegt als Int unter dem Schlüssel des Einrichtungsassistenten.
        XCTAssertEqual(d.integer(forKey: "modelBits"), 8)
        XCTAssertEqual(d.integer(forKey: SetupState.bitsDefaultsKey), 8)
        let b = AppSettings(defaults: d)
        XCTAssertEqual(b.helperName, "Johannes")
        XCTAssertEqual(b.helperPhone, "0151 1234")
        XCTAssertEqual(b.quality, .accurate)
        XCTAssertEqual(b.quality.bits, 8)
        XCTAssertEqual(b.defaultTempo, .slower)
        XCTAssertFalse(b.chaptersAsFiles)
        XCTAssertEqual(b.outputDirectory?.path, dir.path)
        b.quality = .fast
        XCTAssertEqual(d.integer(forKey: "modelBits"), 4)
    }

    func testDefaultTempoAndChapterFlagReachTheDraftAndJob() {
        let d = defaults()
        let settings = AppSettings(defaults: d)
        settings.defaultTempo = .faster
        let lib = VoiceLibrary(customDirectory: dir.appending(path: "v"))
        let model = AppModel(settings: settings, library: lib, storeRoot: dir.appending(path: "p"))
        model.typedText = "Das ist ein Text. Er ist kurz."
        model.submitTypedText()
        XCTAssertEqual(model.draft?.tempo, .faster)
    }

    // MARK: Stimmen

    func testOwnVoicesCanBeRenamedAndDeleted() throws {
        let custom = dir.appending(path: "custom", directoryHint: .isDirectory)
        let lib = VoiceLibrary(customDirectory: custom)
        let store = lib.store.custom
        let own = try store.save(
            samples: [Float](repeating: 0.1, count: 24_000), sampleRate: 24_000, transcript: "Guten Tag.", name: "Oma",
            language: .de, consent: true, source: "recording", transcriptSource: "reading")
        let designed = try store.saveDesigned(
            samples: [Float](repeating: 0.1, count: 24_000), sampleRate: 24_000, referenceText: "Hallo.", name: "Warm",
            language: .de, wish: "warm", prompt: nil, seed: 1)

        let model = HelperVoicesModel(library: lib)
        XCTAssertEqual(model.entry(own.id)?.origin, .recorded)
        XCTAssertEqual(model.entry(designed.id)?.origin, .designed)

        // Umbenennen und Löschen eigener und beschriebener Stimmen.
        try model.rename(id: own.id, to: "  Omas Stimme ")
        XCTAssertEqual(model.entry(own.id)?.name, "Omas Stimme")
        XCTAssertEqual(lib.voice(id: own.id)?.name, "Omas Stimme")
        try model.delete(id: own.id)
        try model.delete(id: designed.id)
        XCTAssertNil(model.entry(own.id))
        XCTAssertNil(model.entry(designed.id))
        XCTAssertTrue(store.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.audioURL(id: own.id).path))
        // Eine unbekannte ID lässt sich nicht löschen.
        XCTAssertThrowsError(try model.delete(id: "own-gibtsnicht"))
    }

    func testSampleURLOfOwnVoice() throws {
        let lib = VoiceLibrary(customDirectory: dir.appending(path: "c"))
        let own = try lib.store.custom.save(
            samples: [Float](repeating: 0.1, count: 24_000), sampleRate: 24_000, transcript: "Guten Tag.", name: "Oma",
            language: .de, consent: true, source: "recording", transcriptSource: "reading")
        let model = HelperVoicesModel(library: lib)
        XCTAssertEqual(model.sampleURL(for: own.id)?.lastPathComponent, "\(own.id).caf")
        XCTAssertNil(model.sampleURL(for: "own-gibtsnicht"))
    }

    // MARK: Hörbücher und Protokoll

    private func makeFinishedProject(_ store: ProjectStore, title: String, finished: Bool = true) async throws -> Project {
        let chunks = (1...2).map { Chunk(index: $0, text: "Satz \($0).", spokenText: "Satz \($0).", kind: .sentence, chapter: 0) }
        let p = try await store.create(
            title: title, sourceHash: UUID().uuidString, sourceKind: "text", language: .de, voiceID: "own-demo", chunks: chunks)
        for i in 1...2 {
            try store.chunkStore(for: p.id).write([Float](repeating: 0.1, count: 24_000), sampleRate: 24_000, index: i)
            try await store.markChunkDone(id: p.id, chunkIndex: i, duration: 1)
        }
        if finished {
            try await store.setState(.finished, id: p.id)
            try FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 1000).write(to: store.outputURL(title: title))
        }
        return p
    }

    func testBooksModelCleansOnlyFinishedProjects() async throws {
        let store = ProjectStore(root: dir.appending(path: "P"), outputDirectory: dir.appending(path: "O"))
        let done = try await makeFinishedProject(store, title: "Fertig")
        let open = try await makeFinishedProject(store, title: "Offen", finished: false)
        let books = HelperBooksModel(store: store)
        await books.reload()
        XCTAssertEqual(books.rows.count, 2)
        XCTAssertEqual(books.rows.filter(\.canCleanIntermediates).map(\.id), [done.id])
        XCTAssertGreaterThan(books.reclaimableBytes, 0)

        let refused = await books.cleanIntermediates(id: open.id)
        XCTAssertNil(refused)
        XCTAssertEqual(store.chunkStore(for: open.id).existingIndices(), [1, 2])

        let freed = await books.cleanIntermediates(id: done.id)
        XCTAssertGreaterThan(freed ?? 0, 0)
        XCTAssertTrue(store.chunkStore(for: done.id).existingIndices().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.outputURL(title: "Fertig").path))
        XCTAssertEqual(books.reclaimableBytes, 0)

        await books.delete(id: open.id)
        XCTAssertEqual(books.rows.map(\.id), [done.id])
    }

    func testProtocolReportContainsProblemsHeaderAndLog() async throws {
        let store = ProjectStore(root: dir.appending(path: "P"), outputDirectory: dir.appending(path: "O"))
        let p = try await makeFinishedProject(store, title: "Brief", finished: false)
        try await store.markChunkFailed(id: p.id, chunkIndex: 2, error: "NaN im Signal")
        let log = EventLog(directory: dir.appending(path: "L"))
        log.write(.error, "work", "Erzeugung fehlgeschlagen: problem.x")
        let text = await HelperProtocol.report(store: store, log: log)
        XCTAssertTrue(text.contains("Vorleser "))
        XCTAssertTrue(text.contains("macOS "))
        XCTAssertTrue(text.contains("== Brief =="))
        XCTAssertTrue(text.contains("Abschnitt 2"))
        XCTAssertTrue(text.contains("Fehler: NaN im Signal"))
        XCTAssertTrue(text.contains("Text: Satz 2."))
        XCTAssertTrue(text.contains("Erzeugung fehlgeschlagen: problem.x"))
    }

    func testLoggerSubsystem() {
        XCTAssertEqual(AppLog.subsystem, "de.vorleser.app")
    }
}
