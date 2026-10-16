// Kamera-Ablauf „Vom iPhone fotografieren“ mit Kamera-Attrappe und den Foto-Fixtures aus Spike S4.
// Nicht prüfbar ohne iPhone: echte Continuity Camera (Erkennung, Live-Bild, Aufnahme), siehe docs/phase5-helper.md.
import DocumentImport
import Foundation
import XCTest

@testable import Vorleser

@MainActor
final class CameraFlowTests: XCTestCase {
    private var dir: URL!
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }
    private var fixture: URL {
        repo.appending(path: "Packages/VorleserCore/Tests/DocumentImportTests/Fixtures/foto.jpg")
    }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "vorleser-cam-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func waitUntil(_ timeout: Double = 5, _ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func result(unreadable: [Int] = []) -> ImportResult {
        var r = ImportResult(
            document: .init(title: nil, blocks: [.paragraph("Ein Satz.")]), report: nil, pageCount: 2, ocrPages: [0, 1], language: "de")
        r.unreadablePages = unreadable
        return r
    }

    private func makeFlow(
        camera: DemoCamera, reader: PhotoReader? = nil
    ) -> CameraFlow {
        let flow = CameraFlow(
            camera: camera, reader: reader ?? { _, _ in ImportResult(document: .init(title: nil, blocks: [.paragraph("x")]), report: nil, pageCount: 1, ocrPages: [0], language: "de") },
            directory: dir.appending(path: "fotos"))
        flow.searchInterval = .milliseconds(20)
        return flow
    }

    func testNoPhoneShowsFriendlyWaitingThenStartsWhenPhoneAppears() async {
        let camera = DemoCamera(phone: false, photos: [fixture])
        let flow = makeFlow(camera: camera)
        flow.start()
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(flow.step, .waiting)
        XCTAssertFalse(camera.started)
        camera.phone = true
        await waitUntil { flow.step == .shoot }
        XCTAssertEqual(flow.step, .shoot)
        XCTAssertTrue(camera.started)
    }

    func testDeniedCamera() async {
        let camera = DemoCamera(phone: true, photos: [fixture])
        camera.allowed = false
        let flow = makeFlow(camera: camera)
        flow.start()
        await waitUntil { flow.step == .denied }
        XCTAssertEqual(flow.step, .denied)
        XCTAssertFalse(camera.started)
    }

    func testTwoPagesThenFinishHandsOverPagesInOrder() async throws {
        let camera = DemoCamera(phone: true, photos: [fixture, fixture])
        let box = URLBox()
        let flow = makeFlow(camera: camera, reader: { urls, progress in
            box.set(urls)
            progress(1, urls.count); progress(2, urls.count)
            return ImportResult(document: .init(title: nil, blocks: [.paragraph("Ein Satz.")]), report: nil, pageCount: urls.count, ocrPages: [0, 1], language: "de")
        })
        var finished: (ImportResult, [URL])?
        flow.onFinished = { r, urls in finished = (r, urls) }
        flow.start()
        await waitUntil { flow.step == .shoot }

        flow.takePhoto()
        await waitUntil { flow.step == .review }
        XCTAssertEqual(flow.pageCount, 1)
        flow.acceptLast()
        XCTAssertEqual(flow.step, .more)
        flow.anotherPage()
        XCTAssertEqual(flow.step, .shoot)
        flow.takePhoto()
        await waitUntil { flow.step == .review }
        flow.acceptLast()
        XCTAssertEqual(flow.pageCount, 2)

        flow.finish()
        XCTAssertEqual(flow.step, .reading)
        await waitUntil { finished != nil }
        let urls = try XCTUnwrap(box.urls)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["Seite-01.jpg", "Seite-02.jpg"])
        XCTAssertEqual(finished?.1.count, 2)
        XCTAssertFalse(camera.started, "Kamera ist nach dem Lesen aus")
    }

    func testRetakeReplacesLastPhoto() async {
        let camera = DemoCamera(phone: true, photos: [fixture])
        let flow = makeFlow(camera: camera)
        flow.start()
        await waitUntil { flow.step == .shoot }
        flow.takePhoto()
        await waitUntil { flow.step == .review }
        let first = flow.lastPage
        flow.retakeLast()
        XCTAssertEqual(flow.pageCount, 0)
        XCTAssertEqual(flow.step, .shoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first?.path ?? ""))
    }

    func testFailedCaptureAsksToTryAgainAndPhoneLossReturnsToWaiting() async {
        let camera = DemoCamera(phone: true, photos: [fixture])
        let flow = makeFlow(camera: camera)
        flow.start()
        await waitUntil { flow.step == .shoot }
        camera.failNextCapture = true
        flow.takePhoto()
        await waitUntil { flow.captureFailed }
        XCTAssertTrue(flow.captureFailed)
        XCTAssertEqual(flow.step, .shoot)
        // iPhone weg: zurück zur Suche, ohne Absturz.
        camera.failNextCapture = true
        camera.phone = false
        flow.takePhoto()
        await waitUntil { flow.step == .waiting }
        XCTAssertEqual(flow.step, .waiting)
        camera.phone = true
        await waitUntil { flow.step == .shoot }
        XCTAssertEqual(flow.step, .shoot)
    }

    func testBackWithoutPhotosLeavesAtOnceBackWithPhotosAsksFirst() async {
        let camera = DemoCamera(phone: true, photos: [fixture])
        let flow = makeFlow(camera: camera)
        var exited = 0
        flow.onExit = { exited += 1 }
        flow.start()
        await waitUntil { flow.step == .shoot }
        flow.takePhoto()
        await waitUntil { flow.step == .review }
        let file = flow.lastPage
        flow.back()
        XCTAssertTrue(flow.confirmDiscard, "Abbrechen fragt nach")
        XCTAssertEqual(exited, 0)
        flow.confirmDiscard = false  // „Nein, weitermachen“
        flow.acceptLast()
        flow.anotherPage()
        flow.back()  // vom Live-Bild zu „Noch eine Seite?“, nichts geht verloren
        XCTAssertEqual(flow.step, .more)
        XCTAssertEqual(flow.pageCount, 1)
        flow.back()
        XCTAssertTrue(flow.confirmDiscard)
        flow.discardAll()
        XCTAssertEqual(exited, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file?.path ?? ""))

        let fresh = makeFlow(camera: DemoCamera(phone: false))
        var exited2 = 0
        fresh.onExit = { exited2 += 1 }
        fresh.back()
        XCTAssertEqual(exited2, 1, "ohne Fotos kein Nachfragen")
    }

    func testEmptyResultReportsFriendlyProblem() async {
        let camera = DemoCamera(phone: true, photos: [fixture])
        let flow = makeFlow(camera: camera, reader: { _, _ in throw DocumentImportError.empty })
        var key: String?
        flow.onFailed = { key = $0 }
        flow.start()
        await waitUntil { flow.step == .shoot }
        flow.takePhoto()
        await waitUntil { flow.step == .review }
        flow.acceptLast()
        flow.finish()
        await waitUntil { key != nil }
        XCTAssertEqual(key, "camera.problem.noText")
        XCTAssertEqual(flow.pageCount, 0, "Fotos sind aufgeräumt")
    }

    func testUnreadablePagesAreReportedBeforeContinuing() async {
        let camera = DemoCamera(phone: true, photos: [fixture])
        let unreadable = result(unreadable: [1])
        let flow = makeFlow(camera: camera, reader: { _, _ in unreadable })
        var finished = false
        flow.onFinished = { _, _ in finished = true }
        flow.start()
        await waitUntil { flow.step == .shoot }
        flow.takePhoto()
        await waitUntil { flow.step == .review }
        flow.acceptLast()
        flow.finish()
        await waitUntil { flow.step == .partial([2]) }
        XCTAssertEqual(flow.step, .partial([2]), "1-basierte Seitennummer für die Anzeige")
        XCTAssertFalse(finished)
        flow.continueAnyway()
        XCTAssertTrue(finished)
    }

    // MARK: Zusammenspiel mit der App und echtes Lesen

    func testRealOCROfFixturePhotosLeadsToVoiceScreen() async throws {
        let lib = VoiceLibrary(directory: repo.appending(path: "Resources/Voices"), customDirectory: dir.appending(path: "v"))
        let settings = AppSettings(defaults: UserDefaults(suiteName: "de.vorleser.tests.cam.\(UUID().uuidString)")!)
        let model = AppModel(settings: settings, library: lib, storeRoot: dir.appending(path: "p"))
        model.makeCamera = { DemoCamera(phone: true, photos: [self.fixture, self.fixture]) }
        model.startCamera()
        XCTAssertEqual(model.screen, .camera)
        let flow = try XCTUnwrap(model.camera)
        await waitUntil { flow.step == .shoot }
        flow.takePhoto(); await waitUntil { flow.step == .review }; flow.acceptLast(); flow.anotherPage()
        flow.takePhoto(); await waitUntil { flow.step == .review }; flow.acceptLast()
        flow.finish()
        await waitUntil(60) { model.screen == .voice }
        XCTAssertEqual(model.screen, .voice)
        let draft = try XCTUnwrap(model.draft)
        XCTAssertEqual(draft.sourceKind, "image")
        XCTAssertEqual(draft.language, .de)
        let text = draft.document.blocks.map { b -> String in
            switch b { case .heading(_, let t): t; case .paragraph(let p): p }
        }.joined(separator: " ")
        XCTAssertTrue(text.contains("Mietvertrag") && text.contains("Kaution"), text)
        XCTAssertNil(model.camera)
    }
}

final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _urls: [URL]?
    func set(_ u: [URL]) { lock.withLock { _urls = u } }
    var urls: [URL]? { lock.withLock { _urls } }
}
