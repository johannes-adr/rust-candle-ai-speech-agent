// Einrichtungsassistent: Ablauf, Fehler, Pause/Fortsetzen und die Startweiche – mit einem Dienst ohne Netz.
import Foundation
import ModelSetup
import VorleserSpeech
import XCTest

@testable import Vorleser

final class FakeSetupService: SetupServicing, @unchecked Sendable {
    private let lock = NSLock()
    private var _ready = false
    private var _installs: [AsyncThrowingStream<InstallEvent, Error>] = []
    var verifyResult = true
    var freeBytes: Int64 = 50_000_000_000

    static let base = ModelManifest(repo: "t/base", revision: String(repeating: "a", count: 40),
                                    files: [.init(path: "m", size: 3_000_000_000, sha256: String(repeating: "0", count: 64))])
    static let design = ModelManifest(repo: "t/design", revision: String(repeating: "b", count: 40),
                                      files: [.init(path: "m", size: 2_000_000_000, sha256: String(repeating: "0", count: 64))])

    var ready: Bool {
        get { lock.withLock { _ready } }
        set { lock.withLock { _ready = newValue } }
    }

    /// Reihenfolge der nächsten `install`-Aufrufe.
    func queue(_ streams: AsyncThrowingStream<InstallEvent, Error>...) { lock.withLock { _installs = streams } }

    func manifests(bits: ModelBits, includeVoiceDesign: Bool) -> [ModelManifest]? {
        includeVoiceDesign ? [Self.base, Self.design] : [Self.base]
    }
    func status(of manifest: ModelManifest) -> ModelStatus { ready ? .ready : .missing }
    func plan(_ manifests: [ModelManifest]) -> InstallPlan {
        let total = manifests.reduce(0) { $0 + $1.totalBytes }
        return InstallPlan(totalBytes: total, presentBytes: 0, importBytes: 0, downloadBytes: total,
                           space: SpaceCheck(needed: total, available: freeBytes))
    }
    func install(_ manifests: [ModelManifest]) -> AsyncThrowingStream<InstallEvent, Error> {
        lock.withLock { _installs.isEmpty ? Self.finished() : _installs.removeFirst() }
    }
    func verify(_ manifests: [ModelManifest]) async throws -> Bool {
        if verifyResult { ready = true }
        return verifyResult
    }

    static func progress(_ fraction: Double, total: Int64 = 5_000_000_000) -> InstallEvent {
        .progress(InstallProgress(phase: .downloading, bytesDone: Int64(Double(total) * fraction), bytesTotal: total,
                                  bytesPerSecond: 5_000_000, remainingSeconds: 600, currentFile: "m", currentModel: nil))
    }
    static func finished() -> AsyncThrowingStream<InstallEvent, Error> {
        AsyncThrowingStream { c in c.yield(progress(1)); c.finish() }
    }
    static func failing(_ error: Error, after fraction: Double = 0.4) -> AsyncThrowingStream<InstallEvent, Error> {
        AsyncThrowingStream { c in c.yield(progress(fraction)); c.finish(throwing: error) }
    }
    /// Läuft, bis abgebrochen wird.
    static func endless() -> AsyncThrowingStream<InstallEvent, Error> {
        AsyncThrowingStream { c in c.yield(progress(0.3)) }
    }
}

@MainActor
final class SetupTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "de.vorleser.tests.setup.\(UUID())")
    }

    private func makeState(_ service: FakeSetupService) -> SetupState {
        SetupState(service: service, defaults: defaults, observeActivation: false)
    }

    private func wait(_ model: SetupModel, for step: SetupStep, timeout: Double = 3, line: UInt = #line) async {
        let end = Date().addingTimeInterval(timeout)
        while model.step != step, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.step, step, line: line)
    }

    // MARK: Startweiche

    func testNeedsSetupUntilBaseIsReady() {
        let service = FakeSetupService()
        let state = makeState(service)
        XCTAssertTrue(state.needsSetup)
        XCTAssertEqual(state.baseStatus, .missing)
        service.ready = true
        state.refresh()
        XCTAssertFalse(state.needsSetup)
    }

    func testBitsDefaultToFourAndFollowSetting() {
        let state = makeState(FakeSetupService())
        XCTAssertEqual(state.bits, .four)
        defaults.set(8, forKey: SetupState.bitsDefaultsKey)
        XCTAssertEqual(state.bits, .eight)
        defaults.set(5, forKey: SetupState.bitsDefaultsKey) // ungültig → Standard
        XCTAssertEqual(state.bits, .four)
    }

    func testReopenShowsAssistantEvenWhenReady() {
        let service = FakeSetupService()
        service.ready = true
        let state = makeState(service)
        XCTAssertFalse(state.needsSetup)
        state.reopenAssistant()
        XCTAssertTrue(state.showAssistant)
    }

    // MARK: Ablauf

    func testHappyPathToHandover() async {
        let service = FakeSetupService()
        let state = makeState(service)
        state.showAssistant = true
        let model = SetupModel(service: service, state: state)
        XCTAssertEqual(model.step, .welcome)
        model.next()
        XCTAssertEqual(model.step, .plan)
        XCTAssertEqual(model.plan?.totalBytes, 5_000_000_000)
        XCTAssertEqual(model.estimatedDownloadMinutes, 14) // 5 GB bei 50 MBit/s ≈ 13,3 → 14
        model.next()
        XCTAssertEqual(model.step, .loading)
        await wait(model, for: .done)
        XCTAssertFalse(state.needsSetup) // Prüfung bestanden → Startweiche gibt frei
        model.next()
        XCTAssertEqual(model.step, .helper)
        model.finish()
        XCTAssertFalse(state.showAssistant)
    }

    func testVoiceDesignToggleChangesPlan() {
        let service = FakeSetupService()
        let model = SetupModel(service: service)
        XCTAssertEqual(model.plan?.totalBytes, 5_000_000_000)
        model.includeVoiceDesign = false
        XCTAssertEqual(model.plan?.totalBytes, 3_000_000_000)
        XCTAssertEqual(model.manifests.count, 1)
    }

    func testNotEnoughSpaceIsShownInPlan() {
        let service = FakeSetupService()
        service.freeBytes = 2_000_000_000
        let model = SetupModel(service: service)
        XCTAssertEqual(model.plan?.space.isEnough, false)
        XCTAssertGreaterThan(model.plan?.space.shortfall ?? 0, 3_000_000_000)
    }

    func testOfflineGivesFriendlyProblemAndRetryWorks() async {
        let service = FakeSetupService()
        service.queue(FakeSetupService.failing(InstallError.offline), FakeSetupService.finished())
        let model = SetupModel(service: service)
        model.next(); model.next()
        await wait(model, for: .problem(.offline))
        XCTAssertEqual(model.progress?.percent, 40) // Geladenes wird angezeigt
        XCTAssertEqual(SetupProblem.offline.messageKey, "setup.problem.offline.text")
        model.startLoading() // „Nochmal versuchen“
        await wait(model, for: .done)
    }

    func testNoSpaceError() async {
        let service = FakeSetupService()
        service.queue(FakeSetupService.failing(InstallError.notEnoughSpace(needed: 6_000_000_000, available: 1_000_000_000)))
        let model = SetupModel(service: service)
        model.next(); model.next()
        await wait(model, for: .problem(.noSpace(missing: 5_000_000_000)))
    }

    func testServerAndOtherErrors() async {
        let service = FakeSetupService()
        service.queue(FakeSetupService.failing(InstallError.server(status: 503)))
        let model = SetupModel(service: service)
        model.next(); model.next()
        await wait(model, for: .problem(.server(status: 503)))
        XCTAssertEqual(SetupModel.problem(for: .checksumMismatch(path: "x")), .damaged)
        XCTAssertEqual(SetupModel.problem(for: .io("boom")), .other("boom"))
    }

    func testPauseKeepsStateAndResumeContinues() async {
        let service = FakeSetupService()
        service.queue(FakeSetupService.endless(), FakeSetupService.finished())
        let model = SetupModel(service: service)
        model.next(); model.next()
        let end = Date().addingTimeInterval(3)
        while model.progress == nil, Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        model.pause()
        XCTAssertEqual(model.step, .paused)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(model.step, .paused, "Abbruch darf nicht als Fehler erscheinen")
        XCTAssertNotNil(model.progress)
        model.resume()
        await wait(model, for: .done)
    }

    func testFailedVerificationShowsDamaged() async {
        let service = FakeSetupService()
        service.verifyResult = false
        let model = SetupModel(service: service)
        model.next(); model.next()
        await wait(model, for: .problem(.damaged))
    }

    func testLeaveClosesAssistantWithoutSetup() {
        let service = FakeSetupService()
        let state = makeState(service)
        state.showAssistant = true
        let model = SetupModel(service: service, state: state)
        model.leave()
        XCTAssertFalse(state.showAssistant)
        XCTAssertTrue(state.needsSetup) // weiter „noch nicht eingerichtet“
    }

    func testEveryProblemHasTranslatedKeys() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "App/Localizable.xcstrings")
        let strings = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])["strings"] as? [String: Any]
        for p in [SetupProblem.offline, .noSpace(missing: 1), .server(status: 500), .damaged, .other("x")] {
            XCTAssertNotNil(strings?[p.titleKey], p.titleKey)
            XCTAssertNotNil(strings?[p.messageKey], p.messageKey)
        }
    }
}
