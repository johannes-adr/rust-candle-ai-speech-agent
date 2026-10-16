// Tests für den Ablauf „Meine eigene Stimme“: Zustände, Zustimmung (Pflicht), Transkript = Lesetext,
// Hinweis-Schlüssel, Kontrast des roten Knopfs. Das Mikrofon selbst ist nicht testbar (siehe docs/phase3.md);
// hier steht eine Attrappe an seiner Stelle.
import Foundation
import TextPrep
import VoiceCapture
import VorleserSpeech
import XCTest

@testable import Vorleser

/// Aufnahme-Attrappe: liefert eine feste „Aufnahme“ und ein paar Pegelwerte.
final class FakeRecorder: AudioRecording, @unchecked Sendable {
    var permission: MicrophonePermission
    var audio: RecordedAudio
    private var continuation: AsyncStream<LevelReading>.Continuation?
    private(set) var started = false
    private(set) var cancelled = false

    init(permission: MicrophonePermission = .granted, audio: RecordedAudio) {
        self.permission = permission
        self.audio = audio
    }

    func requestPermission() async -> MicrophonePermission { permission }

    func start() throws -> AsyncStream<LevelReading> {
        started = true
        let (stream, cont) = AsyncStream.makeStream(of: LevelReading.self)
        cont.yield(LevelReading(rmsDBFS: -25, peakDBFS: -10, elapsedSeconds: 1))
        continuation = cont
        return stream
    }

    func stop() -> RecordedAudio {
        continuation?.finish()
        return audio
    }

    func cancel() {
        cancelled = true
        continuation?.finish()
    }
}

struct FakeTranscriber: SpeechTranscribing {
    var result: TranscriptionResult
    func transcribe(fileURL: URL, language: Language) async -> TranscriptionResult { result }
}

/// Silbenartiges Signal (wie in den Package-Tests): Grundton mit Obertönen, Hüllkurve, Pausen.
func syntheticSpeech(seconds: Double, rate: Double = 48_000, peakDB: Double = -8) -> [Float] {
    let n = Int(seconds * rate)
    var out = [Float](repeating: 0, count: n)
    for i in 0..<n {
        let t = Double(i) / rate
        if t.truncatingRemainder(dividingBy: 3) > 2.6 { continue }
        let env = 0.5 + 0.5 * sin(2 * Double.pi * 4 * t)
        var s = 0.0
        for h in 1...5 { s += sin(2 * Double.pi * 140 * Double(h) * t) / Double(h) }
        out[i] = Float(env * s)
    }
    let peak = out.map { abs($0) }.max() ?? 1
    let g = Float(pow(10, peakDB / 20)) / peak
    return out.map { $0 * g }
}

@MainActor
final class OwnVoiceTests: XCTestCase {
    private var dir: URL!
    private var repo: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appending(path: "ownvoice-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeFlow(
        permission: MicrophonePermission = .granted, samples: [Float]? = nil,
        transcript: TranscriptionResult = .unavailable(.languageNotSupported),
        saved: @escaping (Voice) -> Void = { _ in }, cancelled: @escaping () -> Void = {}
    ) -> (OwnVoiceFlow, FakeRecorder) {
        let rec = FakeRecorder(
            permission: permission,
            audio: RecordedAudio(samples: samples ?? syntheticSpeech(seconds: 12), sampleRate: 48_000))
        let flow = OwnVoiceFlow(
            language: .de, readingText: "Guten Tag, ich bin Ihre Vorleserin.", defaultName: "Meine Stimme",
            recorder: rec, transcriber: FakeTranscriber(result: transcript),
            store: RecordedVoiceStore(directory: dir), pause: { _ in }, onSaved: saved, onCancel: cancelled)
        return (flow, rec)
    }

    private func wait(_ flow: OwnVoiceFlow, for step: OwnVoiceStep, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if flow.step == step { return }
            try? await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Schritt \(step) nicht erreicht, aktuell \(flow.step)", file: file, line: line)
    }

    // MARK: Ablauf

    func testHappyPathRecordReviewConsentSave() async throws {
        var savedVoice: Voice?
        let (flow, rec) = makeFlow(
            transcript: .text("guten tag ich bin ihre vorleserin", engine: "fake"), saved: { savedVoice = $0 })
        XCTAssertEqual(flow.step, .ready)

        flow.tapRecord()
        await wait(flow, for: .recording)
        XCTAssertTrue(rec.started)
        flow.tapDone()
        await wait(flow, for: .review)
        XCTAssertTrue(flow.canKeep)
        XCTAssertTrue(flow.isClean, "\(flow.hintKeys)")
        if case .ok = flow.readingResult {} else { XCTFail("Erwartet ok: \(String(describing: flow.readingResult))") }

        flow.keep()
        XCTAssertEqual(flow.step, .consent)
        XCTAssertFalse(flow.canSave)
        // Ohne Häkchen passiert nichts.
        flow.save()
        XCTAssertEqual(flow.step, .consent)
        XCTAssertNil(savedVoice)
        XCTAssertTrue(RecordedVoiceStore(directory: dir).list().isEmpty)

        flow.consent = true
        flow.name = "Omas Stimme"
        flow.save()
        for _ in 0..<200 where savedVoice == nil { try await Task.sleep(for: .milliseconds(25)) }
        let voice = try XCTUnwrap(savedVoice)
        XCTAssertEqual(voice.name, "Omas Stimme")
        XCTAssertEqual(voice.kind, .recorded)
        // Das Transkript ist immer der feste Lesetext, nie das Erkennungsergebnis.
        XCTAssertEqual(voice.referenceText, "Guten Tag, ich bin Ihre Vorleserin.")
        let info = try XCTUnwrap(RecordedVoiceStore(directory: dir).info(id: voice.id))
        XCTAssertTrue(info.consent)
        XCTAssertEqual(info.source, "recording")
        XCTAssertEqual(info.transcriptSource, "reading")
    }

    func testMismatchGivesHintButCanStillBeKept() async {
        let (flow, _) = makeFlow(transcript: .text("völlig anderer text hier", engine: "fake"))
        flow.tapRecord()
        await wait(flow, for: .recording)
        flow.tapDone()
        await wait(flow, for: .review)
        XCTAssertEqual(flow.hintKeys, ["ownVoice.hint.mismatch"])
        XCTAssertTrue(flow.canKeep)
        XCTAssertFalse(flow.isClean)
    }

    func testSilentRecordingCannotBeKept() async {
        let (flow, _) = makeFlow(samples: [Float](repeating: 0, count: 48_000 * 12))
        flow.tapRecord()
        await wait(flow, for: .recording)
        flow.tapDone()
        await wait(flow, for: .review)
        XCTAssertFalse(flow.canKeep)
        XCTAssertEqual(flow.hintKeys, ["ownVoice.hint.silent"])
        flow.keep()
        XCTAssertEqual(flow.step, .review)
    }

    func testQuietRecordingShowsCloserToMicrophoneHint() async {
        let (flow, _) = makeFlow(samples: syntheticSpeech(seconds: 12, peakDB: -45))
        flow.tapRecord()
        await wait(flow, for: .recording)
        flow.tapDone()
        await wait(flow, for: .review)
        XCTAssertTrue(flow.hintKeys.contains("ownVoice.hint.tooQuiet"), "\(flow.hintKeys)")
    }

    func testDeniedMicrophoneShowsFriendlyScreenAndBackLeaves() async {
        var left = false
        let (flow, rec) = makeFlow(permission: .denied, cancelled: { left = true })
        XCTAssertEqual(flow.step, .micDenied)
        flow.tapRecord()  // tut nichts: erst Hilfe
        XCTAssertFalse(rec.started)
        flow.back()
        XCTAssertTrue(left)
    }

    func testPermissionRefusedAtFirstUseLeadsToHelp() async {
        let (flow, rec) = makeFlow(permission: .notDetermined)
        rec.permission = .denied   // die Nutzerin klickt im Systemdialog auf „Nicht erlauben“
        flow.tapRecord()
        await wait(flow, for: .micDenied)
        XCTAssertFalse(rec.started)
    }

    func testBackAlwaysWorks() async {
        var left = false
        let (flow, rec) = makeFlow(cancelled: { left = true })
        flow.tapRecord()
        await wait(flow, for: .recording)
        flow.back()                       // mitten in der Aufnahme: verwerfen, wieder bereit
        XCTAssertEqual(flow.step, .ready)
        XCTAssertTrue(rec.cancelled)
        flow.tapRecord()
        await wait(flow, for: .recording)
        flow.tapDone()
        await wait(flow, for: .review)
        flow.keep()
        XCTAssertEqual(flow.step, .consent)
        flow.consent = true
        flow.back()                       // Zustimmung zurückgenommen, zurück zum Anhören
        XCTAssertEqual(flow.step, .review)
        XCTAssertFalse(flow.consent)
        flow.back()
        XCTAssertEqual(flow.step, .ready)
        flow.back()
        XCTAssertTrue(left)
    }

    func testCountdownShowsThreeTwoOne() async {
        // Pause so lange, dass wir jede Zahl sehen.
        let rec = FakeRecorder(audio: RecordedAudio(samples: syntheticSpeech(seconds: 12), sampleRate: 48_000))
        let seen = Seen()
        let flow = OwnVoiceFlow(
            language: .de, readingText: "x", defaultName: "n", recorder: rec,
            transcriber: FakeTranscriber(result: .unavailable(.failed)), store: RecordedVoiceStore(directory: dir),
            pause: { _ in try? await Task.sleep(for: .milliseconds(80)) }, onSaved: { _ in }, onCancel: {})
        flow.tapRecord()
        for _ in 0..<100 {
            if case .countdown(let n) = flow.step { seen.add(n) }
            if flow.step == .recording { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(seen.values, [3, 2, 1])
        flow.back()
    }

    final class Seen {
        private(set) var values: [Int] = []
        func add(_ n: Int) { if values.last != n { values.append(n) } }
    }

    // MARK: Ausgabe

    func testRecordedVoiceAppearsInLibrary() throws {
        let custom = dir.appending(path: "custom", directoryHint: .isDirectory)
        let lib = VoiceLibrary(customDirectory: custom)
        XCTAssertTrue(lib.recordedVoices(for: .de).isEmpty)
        let saved = try lib.store.custom.save(
            samples: syntheticSpeech(seconds: 11), sampleRate: 48_000, transcript: "Guten Tag.", name: "Oma", language: .de,
            consent: true, source: "recording", transcriptSource: "reading")
        XCTAssertEqual(lib.recordedVoices(for: .de).map(\.id), [saved.id])
        XCTAssertTrue(lib.recordedVoices(for: .pt).isEmpty)
        XCTAssertEqual(lib.voice(id: saved.id)?.name, "Oma")
        XCTAssertNotNil(lib.referenceURL(voiceID: saved.id))
        // Die Engine bekommt dieselbe Stimme über den VoiceStore, mit dem gespeicherten Text.
        XCTAssertEqual(lib.store.voice(id: saved.id)?.referenceText, "Guten Tag.")

        let model = AppModel(library: lib, storeRoot: dir.appending(path: "projects"))
        model.typedText = "Das ist ein Text. Er ist kurz."
        model.submitTypedText()
        model.setLanguage(.de)
        // Die erste Stimme der Sprache ist vorgewählt, sobald es sie gibt.
        model.setLanguage(.de)
        XCTAssertEqual(model.draft?.voiceID, saved.id)

        // Nach dem Löschen im Helfer-Fenster ist keine Stimme mehr gewählt (Vorlesen geht dann nicht).
        try lib.store.custom.delete(id: saved.id)
        model.validateSelectedVoice()
        XCTAssertNil(model.draft?.voiceID)
    }

    func testStartOwnVoiceNavigatesAndFinishReturnsToVoiceScreen() throws {
        let custom = dir.appending(path: "custom", directoryHint: .isDirectory)
        let lib = VoiceLibrary(customDirectory: custom)
        let model = AppModel(library: lib, storeRoot: dir.appending(path: "projects"))
        model.typedText = "Das ist ein Text. Er ist kurz."
        model.submitTypedText()
        model.setLanguage(.de)
        XCTAssertEqual(model.screen, .voice)
        model.chooseOwnVoice()
        // Im Test-Bundle fehlen die Lesetexte im Paket; dann bleibt es bei einer freundlichen Meldung.
        if model.screen == .ownVoice {
            XCTAssertNotNil(model.ownVoice)
            let voice = Voice(id: "own-x", name: "X", language: .de, kind: .recorded,
                              referenceAudio: URL(fileURLWithPath: "/x"), referenceText: "t")
            model.finishOwnVoice(selecting: voice)
            XCTAssertEqual(model.screen, .voice)
            XCTAssertEqual(model.draft?.voiceID, "own-x")
            XCTAssertNil(model.ownVoice)
        } else {
            XCTAssertEqual(model.screen, .problem("problem.unreadable"))
        }
    }

    // MARK: Oma-Regeln

    func testRecordButtonContrastAtLeast7To1() {
        XCTAssertGreaterThanOrEqual(
            OwnVoiceStyle.recordLabel.contrast(with: OwnVoiceStyle.recordFill), OmaStyle.minContrast)
        XCTAssertGreaterThanOrEqual(OwnVoiceStyle.readingSize, OmaStyle.minTextSize)
        XCTAssertGreaterThanOrEqual(OwnVoiceStyle.fieldSize, OmaStyle.minTextSize)
    }

    func testEveryHintAndFlowKeyExistsInCatalog() throws {
        let data = try Data(contentsOf: repo.appending(path: "App/Localizable.xcstrings"))
        let strings = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["strings"] as? [String: Any])
        for issue in RecordingIssue.allCases {
            XCTAssertNotNil(strings[issue.hintKey], issue.hintKey)
        }
        XCTAssertNotNil(strings["ownVoice.hint.mismatch"])
        XCTAssertEqual(ReadingCheckResult.mismatch(errorRate: 0.5).hintKey, "ownVoice.hint.mismatch")
        // Die drei Pflichthinweise aus dem Plan stehen wörtlich da.
        func de(_ key: String) -> String? {
            (((strings[key] as? [String: Any])?["localizations"] as? [String: Any])?["de"] as? [String: Any])
                .flatMap { $0["stringUnit"] as? [String: Any] }?["value"] as? String
        }
        XCTAssertEqual(de("ownVoice.hint.tooQuiet"), "Bitte etwas näher ans Mikrofon")
        XCTAssertEqual(de("ownVoice.hint.tooLoud"), "Bitte etwas leiser sprechen")
        XCTAssertEqual(de("ownVoice.hint.noisy"), "Es ist zu laut im Raum")
        XCTAssertEqual(de("ownVoice.hint.mismatch"), "Bitte nochmal, der Text war schwer zu verstehen")
    }
}
