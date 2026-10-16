// Ablauf „Stimme beschreiben“ ohne Modell (Attrappe des Dienstes) und Anbindung an ②.
import Foundation
import Pipeline
import VorleserSpeech
import TextPrep
import XCTest

@testable import Vorleser

/// Dienst-Attrappe: liefert sofort zwei Vorschläge, merkt sich Wunsch und gespeicherten Index.
final class FakeDesignService: VoiceDesignService, @unchecked Sendable {
    private let lock = NSLock()
    private var _wishes: [VoiceWish] = []
    private var _saved: [(Int, String)] = []
    var failure: DesignServiceError?
    var delay: Duration = .zero

    var wishes: [VoiceWish] { lock.withLock { _wishes } }
    var saved: [(Int, String)] { lock.withLock { _saved } }

    func propose(
        wish: VoiceWish, referenceText: String, onStage: @escaping @Sendable (DesignStage) -> Void
    ) async throws -> [DesignedProposal] {
        lock.withLock { _wishes.append(wish) }
        onStage(.preparing)
        if delay != .zero { try await Task.sleep(for: delay) }
        if let failure { throw failure }
        onStage(.proposal(1, of: 2))
        return (1...2).map {
            DesignedProposal(index: $0, previewURL: URL(fileURLWithPath: "/nonexistent-\($0)"), duration: 11, isSuspicious: false)
        }
    }

    func save(proposal index: Int, name: String) async throws -> Voice {
        lock.withLock { _saved.append((index, name)) }
        return Voice(
            id: "designed-test", name: name, language: .de, kind: .designed,
            referenceAudio: URL(fileURLWithPath: "/nonexistent.caf"), referenceText: "x", description: "d")
    }
}

@MainActor
final class DescribeVoiceTests: XCTestCase {
    private func waitUntil(_ timeout: Double = 3, _ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    private func makeModel(_ service: FakeDesignService) -> DescribeVoiceModel {
        let m = DescribeVoiceModel(service: service, readAloud: { _ in "Lesetext" })
        m.begin(readingLanguage: .de, uiLanguage: .de)
        return m
    }

    func testEmptyWishDoesNotStart() {
        let service = FakeDesignService()
        let m = makeModel(service)
        m.wishText = "   \n "
        XCTAssertFalse(m.canTry)
        m.tryVoices()
        XCTAssertEqual(m.step, .wish)
    }

    func testFullFlowSavesChosenProposalAndReturnsVoice() async {
        let service = FakeDesignService()
        let m = makeModel(service)
        var saved: Voice?
        m.onSaved = { saved = $0 }
        m.wishText = "  ruhig und warm  "
        m.tryVoices()
        XCTAssertEqual(m.step, .working)
        await waitUntil { m.step == .choose }
        XCTAssertEqual(m.step, .choose)
        XCTAssertEqual(m.proposals.count, 2)
        XCTAssertEqual(service.wishes.first?.description, "ruhig und warm")
        XCTAssertEqual(service.wishes.first?.readingLanguage, .de)
        XCTAssertEqual(service.wishes.first?.descriptionLanguage, .de)

        m.take(m.proposals[1])
        XCTAssertEqual(m.step, .name)
        XCTAssertFalse(m.name.isEmpty, "Name ist vorbelegt")
        m.name = "Oma"
        m.save()
        await waitUntil { saved != nil }
        XCTAssertEqual(saved?.name, "Oma")
        XCTAssertEqual(service.saved.first?.0, 2)
        XCTAssertEqual(service.saved.first?.1, "Oma")
    }

    func testBackWalksOneStepAtATime() async {
        let service = FakeDesignService()
        let m = makeModel(service)
        var exited = false
        m.onExit = { exited = true }
        m.wishText = "x"
        m.tryVoices()
        await waitUntil { m.step == .choose }
        m.take(m.proposals[0])
        m.back()
        XCTAssertEqual(m.step, .choose)
        m.back()
        XCTAssertEqual(m.step, .wish)
        XCTAssertFalse(exited)
        m.back()
        XCTAssertTrue(exited)
    }

    func testCancelAsksFirstAndKeepsText() async {
        let service = FakeDesignService()
        service.delay = .seconds(5)
        let m = makeModel(service)
        m.wishText = "ruhig"
        m.tryVoices()
        XCTAssertEqual(m.step, .working)
        m.back()
        XCTAssertTrue(m.confirmCancel, "Abbrechen fragt nach")
        XCTAssertEqual(m.step, .working)
        m.confirmCancel = false
        XCTAssertEqual(m.step, .working, "Nein, weiter")
        m.back()
        m.cancelWork()
        XCTAssertEqual(m.step, .wish)
        XCTAssertEqual(m.wishText, "ruhig")
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(m.step, .wish, "ein abgebrochener Lauf ändert den Bildschirm nicht mehr")
    }

    func testFailureShowsFriendlyMessage() async {
        let service = FakeDesignService()
        service.failure = .modelMissing
        let m = makeModel(service)
        m.wishText = "ruhig"
        m.tryVoices()
        await waitUntil { if case .failed = m.step { true } else { false } }
        XCTAssertEqual(m.step, .failed("describeVoice.failed.noModel"))
        m.back()
        XCTAssertEqual(m.step, .wish)

        service.failure = .nothingUsable
        m.tryVoices()
        await waitUntil { if case .failed = m.step { true } else { false } }
        XCTAssertEqual(m.step, .failed("describeVoice.failed.text"))
    }

    func testAgainStartsNewRunWithSameWish() async {
        let service = FakeDesignService()
        let m = makeModel(service)
        m.wishText = "ruhig"
        m.tryVoices()
        await waitUntil { m.step == .choose }
        m.tryVoices()
        await waitUntil { m.step == .choose && service.wishes.count == 2 }
        XCTAssertEqual(service.wishes.count, 2)
        XCTAssertEqual(service.wishes[0], service.wishes[1])
    }

    func testProgressFractionIsMonotonic() {
        let m = makeModel(FakeDesignService())
        var last = -1.0
        for stage in [DesignStage.preparing, .proposal(1, of: 2), .proposal(2, of: 2), .finishing] {
            m.stage = stage
            XCTAssertGreaterThan(m.fraction, last)
            XCTAssertLessThanOrEqual(m.fraction, 1)
            last = m.fraction
        }
    }

    func testDesignedVoiceHasNoStyle() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vorleser-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rate = 24_000.0
        let tone = (0..<Int(rate)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
        let voice = try RecordedVoiceStore(directory: dir).saveDesigned(
            samples: tone, sampleRate: rate, referenceText: "x", name: "Oma", language: .de, wish: "ruhig", prompt: nil, seed: nil)
        let app = AppModel(
            settings: AppSettings(defaults: UserDefaults(suiteName: "de.vorleser.tests.describe")!),
            library: VoiceLibrary(customDirectory: dir), storeRoot: dir.appending(path: "p"))
        XCTAssertNil(app.styleKey(forVoice: voice.id, style: .calm))
        XCTAssertTrue(app.isDesignedVoice(voice.id))
        XCTAssertEqual(app.voiceName(voice.id), "Oma")
        XCTAssertEqual(app.styleKey(forVoice: "de-helga", style: .happy), "happy")
        XCTAssertEqual(app.styleKey(forVoice: nil, style: .calm), "calm")
        XCTAssertFalse(app.isDesignedVoice("own-unbekannt"))
    }

    /// Systemübersetzer: nur wenn das Sprachpaket installiert ist, sonst übersprungen.
    func testSystemTranslatorWorksInAppProcess() async throws {
        guard await SystemDescriptionTranslator.isInstalled(.de) else { throw XCTSkip("Sprachpaket de→en nicht installiert") }
        let en = await SystemDescriptionTranslator().translateToEnglish("ruhig und warm, wie eine Großmutter", from: .de)
        XCTAssertNotNil(en)
        XCTAssertTrue(en?.lowercased().contains("calm") ?? false, "Übersetzung: \(en ?? "nil")")
    }
}
