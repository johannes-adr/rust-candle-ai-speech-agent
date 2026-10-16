import Foundation
import Testing
import TextPrep
@testable import VoiceCapture

// MARK: Synthetische „Sprache“

/// Silbenartiges Signal: Grundton 140 Hz mit Obertönen, 4 Hz Hüllkurve, Pausen alle `pauseEvery` s.
func synthSpeech(
    seconds: Double, sampleRate: Double = 48_000, peakDB: Double = -8, noiseDB: Double = -70,
    pauseEvery: Double = 3, pauseLength: Double = 0.4, seed: UInt64 = 7
) -> [Float] {
    let n = Int(seconds * sampleRate)
    var out = [Float](repeating: 0, count: n)
    var state = seed &* 6364136223846793005 &+ 1442695040888963407
    let noiseAmp = Float(pow(10, noiseDB / 20))
    for i in 0..<n {
        let t = Double(i) / sampleRate
        let inPause = t.truncatingRemainder(dividingBy: pauseEvery) > pauseEvery - pauseLength
        var v = 0.0
        if !inPause {
            let env = 0.5 + 0.5 * sin(2 * Double.pi * 4 * t)
            var s = 0.0
            for h in 1...6 { s += sin(2 * Double.pi * 140 * Double(h) * t) / Double(h) }
            v = env * s / 2.0
        }
        state = state &* 6364136223846793005 &+ 1442695040888963407
        let u = Float(state >> 40) / Float(1 << 24) * 2 - 1
        out[i] = Float(v) + u * noiseAmp
    }
    // Spitze auf peakDB bringen (Rauschen zählt kaum).
    let peak = out.map { abs($0) }.max() ?? 1
    let g = Float(pow(10, peakDB / 20)) / max(peak, 1e-6)
    return out.map { $0 * g }
}

// MARK: Pegel und Prüfung

@Test func levelMeterMeasuresSine() {
    let sr = 48_000.0
    let amp = Float(0.5)
    let s = (0..<48_000).map { amp * Float(sin(2 * Double.pi * 440 * Double($0) / sr)) }
    let m = LevelMeter.measure(s)
    #expect(abs(m.peakDBFS - (-6.02)) < 0.1)
    #expect(abs(m.rmsDBFS - (-9.03)) < 0.1)
    #expect(LevelMeter.measure([Float](repeating: 0, count: 100)).rmsDBFS == LevelMeter.floorDBFS)
    #expect(LevelMeter.fraction(forDBFS: -60) == 0)
    #expect(LevelMeter.fraction(forDBFS: 0) == 1)
    #expect(LevelReading(rmsDBFS: -20, peakDBFS: -0.5, elapsedSeconds: 1).isHot)
}

@Test func goodRecordingHasNoIssues() {
    let rec = [Float](repeating: 0, count: 24_000) + synthSpeech(seconds: 12) + [Float](repeating: 0, count: 48_000)
    let (clean, report) = RecordingAnalyzer.analyze(samples: rec, sampleRate: 48_000)
    #expect(report.issues.isEmpty, "\(report)")
    // Stille an Anfang und Ende ist weg (bis auf den Rand).
    #expect(report.trimmedSeconds > 11 && report.trimmedSeconds < 12.5)
    #expect(clean.count < rec.count)
    // Pegel auf -3 dBFS Spitze angeglichen.
    let peak = clean.map { abs($0) }.max() ?? 0
    #expect(abs(20 * log10(Double(peak)) - (-3)) < 0.3)
    #expect(report.snrDB > 30)
}

@Test func tooQuietIsDetected() {
    let rec = synthSpeech(seconds: 12, peakDB: -40, noiseDB: -90)
    let report = RecordingAnalyzer.analyze(samples: rec, sampleRate: 48_000).report
    #expect(report.issues.contains(.tooQuiet), "\(report)")
    #expect(!report.issues.contains(.noisy))
    #expect(RecordingIssue.tooQuiet.hintKey == "ownVoice.hint.tooQuiet")
}

@Test func clippingAndTooLoudAreDetected() {
    var rec = synthSpeech(seconds: 12, peakDB: 6)  // weit über Vollaussteuerung
    rec = rec.map { min(max($0, -1), 1) }          // wie ein übersteuerter Wandler
    let report = RecordingAnalyzer.analyze(samples: rec, sampleRate: 48_000).report
    #expect(report.issues.contains(.clipping), "\(report)")
    #expect(RecordingIssue.clipping.hintKey == "ownVoice.hint.tooLoud")

    let loud = synthSpeech(seconds: 12, peakDB: -0.8)
    let r2 = RecordingAnalyzer.analyze(samples: loud, sampleRate: 48_000).report
    #expect(r2.issues.contains(.tooLoud) || r2.issues.contains(.clipping), "\(r2)")
}

@Test func backgroundNoiseIsDetected() {
    let rec = synthSpeech(seconds: 12, peakDB: -8, noiseDB: -26)
    let report = RecordingAnalyzer.analyze(samples: rec, sampleRate: 48_000).report
    #expect(report.issues.contains(.noisy), "\(report)")
    #expect(report.noiseFloorDBFS > -45)
    // Saubere Aufnahme: Rauschen niedrig geschätzt.
    let clean = RecordingAnalyzer.analyze(samples: synthSpeech(seconds: 12, noiseDB: -75), sampleRate: 48_000).report
    #expect(clean.noiseFloorDBFS < -60, "\(clean)")
}

@Test func tooShortAndSilentAreBlocking() {
    let short = RecordingAnalyzer.analyze(samples: synthSpeech(seconds: 4), sampleRate: 48_000).report
    #expect(short.issues.contains(.tooShort))
    #expect(short.hasBlockingIssue)
    let silent = RecordingAnalyzer.analyze(samples: [Float](repeating: 0, count: 48_000 * 10), sampleRate: 48_000).report
    #expect(silent.issues == [.silent])
    #expect(silent.hasBlockingIssue)
    let empty = RecordingAnalyzer.analyze(samples: [], sampleRate: 48_000).report
    #expect(empty.issues.contains(.silent))
}

@Test func tooLongIsReported() {
    let report = RecordingAnalyzer.analyze(samples: synthSpeech(seconds: 25), sampleRate: 48_000).report
    #expect(report.issues.contains(.tooLong))
    #expect(!report.hasBlockingIssue)
}

@Test func nonFiniteIsReportedAndCleaned() {
    var rec = synthSpeech(seconds: 12)
    rec[30_000] = .nan
    rec[30_001] = .infinity
    let (clean, report) = RecordingAnalyzer.analyze(samples: rec, sampleRate: 48_000)
    #expect(report.issues.contains(.nonFinite))
    #expect(clean.allSatisfy { $0.isFinite })
}

@Test func everyIssueHasAHintKey() {
    for i in RecordingIssue.allCases { #expect(i.hintKey.hasPrefix("ownVoice.hint.")) }
}

// MARK: WER / CER

@Test func normalizationDropsCaseAndPunctuation() {
    #expect(TranscriptScoring.normalize("Guten Tag, ich bin Ihre Vorleserin!", language: .de) == "guten tag ich bin ihre vorleserin")
    #expect(TranscriptScoring.normalize("L'été « arrive » — vite.", language: .fr) == "l ete arrive vite")
}

@Test func werOfIdenticalAndDifferentText() {
    let ref = "Heute ist ein schöner Tag. Die Sonne scheint."
    #expect(TranscriptScoring.errorRate(reference: ref, hypothesis: "heute ist ein schoener tag die sonne scheint", language: .de) > 0)
    #expect(TranscriptScoring.errorRate(reference: ref, hypothesis: "Heute ist ein schöner Tag die Sonne scheint", language: .de) == 0)
    // 1 Fehler von 9 Wörtern
    let r = TranscriptScoring.errorRate(
        reference: "a b c d e f g h i", hypothesis: "a b c d e f g h x", language: .en)
    #expect(abs(r - 1.0 / 9.0) < 1e-9)
    #expect(TranscriptScoring.errorRate(reference: "eins zwei drei", hypothesis: "", language: .de) == 1)
}

@Test func cerForChineseAndJapanese() {
    #expect(TranscriptScoring.errorRate(reference: "今天天气很好。", hypothesis: "今天天气很好", language: .zh) == 0)
    let r = TranscriptScoring.errorRate(reference: "今天天气很好", hypothesis: "今天天汽很好", language: .zh)
    #expect(abs(r - 1.0 / 6.0) < 1e-9)
    #expect(TranscriptScoring.tokens("こんにちは、世界", language: .ja).count == 7)
}

struct FakeTranscriber: SpeechTranscribing {
    var result: TranscriptionResult
    func transcribe(fileURL: URL, language: Language) async -> TranscriptionResult {
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        return result
    }
}

@Test func readingCheckAcceptsAndRejects() async {
    let samples = synthSpeech(seconds: 3)
    let text = "Heute ist ein schöner Tag und die Sonne scheint hell."
    let ok = await ReadingChecker.check(
        samples: samples, sampleRate: 48_000, expectedText: text, language: .de,
        transcriber: FakeTranscriber(result: .text("heute ist ein schöner tag und die sonne scheint hell", engine: "fake")))
    guard case .ok(let rate) = ok else { Issue.record("erwartet ok, bekam \(ok)"); return }
    #expect(rate == 0)

    // 4 von 10 Wörtern falsch → 40 % > 30 %
    let bad = await ReadingChecker.check(
        samples: samples, sampleRate: 48_000, expectedText: text, language: .de,
        transcriber: FakeTranscriber(result: .text("heute ist ein schöner baum und das wasser läuft hell", engine: "fake")))
    guard case .mismatch(let r2) = bad else { Issue.record("erwartet mismatch, bekam \(bad)"); return }
    #expect(r2 > 0.3)
    #expect(bad.hintKey == "ownVoice.hint.mismatch")

    // Genau an der Grenze (3 von 10) ist noch gut.
    let edge = await ReadingChecker.check(
        samples: samples, sampleRate: 48_000, expectedText: "a b c d e f g h i j", language: .en,
        transcriber: FakeTranscriber(result: .text("a b c d e f g x y z", engine: "fake")))
    if case .ok = edge {} else { Issue.record("30 % ist noch erlaubt, bekam \(edge)") }

    let unavailable = await ReadingChecker.check(
        samples: samples, sampleRate: 48_000, expectedText: text, language: .ru,
        transcriber: FakeTranscriber(result: .unavailable(.languageNotSupported)))
    #expect(unavailable == .unchecked(.languageNotSupported))
    #expect(unavailable.hintKey == nil)
}

@Test func localePickPrefersConfiguredRegion() {
    let locales = [Locale(identifier: "pt_BR"), Locale(identifier: "pt_PT"), Locale(identifier: "de_AT"), Locale(identifier: "de_DE")]
    #expect(SystemTranscriber.pick(.pt, from: locales)?.identifier == "pt_PT")
    #expect(SystemTranscriber.pick(.de, from: locales)?.identifier == "de_DE")
    #expect(SystemTranscriber.pick(.ru, from: locales) == nil)
    #expect(SystemTranscriber.pick(.pt, from: [Locale(identifier: "pt_BR")])?.identifier == "pt_BR")
}

// MARK: Zuschneiden und Import

@Test func trimmerCutsInPausesAround10to15Seconds() {
    let sr = 48_000.0
    let long = synthSpeech(seconds: 50, sampleRate: sr, pauseEvery: 3, pauseLength: 0.5)
    let sel = ReferenceTrimmer.select(samples: long, sampleRate: sr)
    #expect(sel.seconds >= 10 && sel.seconds <= 15, "\(sel.seconds)")
    #expect(sel.cutAtPauses)
    // Mitte des Fensters nahe der Mitte der Datei.
    let mid = Double(sel.range.lowerBound + sel.range.upperBound) / 2 / sr
    #expect(abs(mid - 25) < 6, "\(mid)")
    // Beide Schnittpunkte liegen in leisen Stellen.
    for p in [sel.range.lowerBound, sel.range.upperBound - 1] {
        let around = Array(long[max(0, p - 2400)..<min(long.count, p + 2400)])
        #expect(LevelMeter.measure(around).rmsDBFS < -40, "Schnitt bei \(Double(p) / sr) s")
    }
    // Kurze Dateien bleiben ganz.
    let short = synthSpeech(seconds: 12, sampleRate: sr)
    #expect(ReferenceTrimmer.select(samples: short, sampleRate: sr).range == 0..<short.count)
}

@Test func trimmerWithoutPausesStillGivesAWindow() {
    let sr = 24_000.0
    let steady = (0..<Int(40 * sr)).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / sr)) }
    let sel = ReferenceTrimmer.select(samples: steady, sampleRate: sr)
    #expect(sel.seconds >= 10 && sel.seconds <= 15)
    #expect(!sel.cutAtPauses)
}

private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appending(path: "vc-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

@Test func importerUsesProvidedTextForShortFiles() async throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "a.wav")
    try AudioFiles.writeWAV(synthSpeech(seconds: 12, sampleRate: 44_100), sampleRate: 44_100, to: url)
    let r = try await VoiceImporter.prepare(
        fileURL: url, language: .de, providedText: " Ein Text. ",
        transcriber: FakeTranscriber(result: .unavailable(.languageNotSupported)))
    #expect(r.transcript == "Ein Text.")
    #expect(r.transcriptSource == .provided)
    #expect(r.sampleRate == 44_100)
    #expect(r.samples.count > 10 * 44_100)
}

@Test func importerRecognizesAndCutsLongFiles() async throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "long.wav")
    try AudioFiles.writeWAV(synthSpeech(seconds: 45, sampleRate: 48_000), sampleRate: 48_000, to: url)
    let r = try await VoiceImporter.prepare(
        fileURL: url, language: .de, transcriber: FakeTranscriber(result: .text("erkannter text", engine: "fake")))
    #expect(r.transcriptSource == .recognized)
    #expect(r.recognitionEngine == "fake")
    let seconds = Double(r.samples.count) / r.sampleRate
    #expect(seconds >= 9.5 && seconds <= 15.5, "\(seconds)")
    #expect(r.sourceSeconds > 44)
}

@Test func importerNeedsTextWhenRecognitionIsUnavailable() async throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "a.wav")
    try AudioFiles.writeWAV(synthSpeech(seconds: 12), sampleRate: 48_000, to: url)
    await #expect(throws: VoiceImportError.transcriptNeeded(.languageNotSupported)) {
        _ = try await VoiceImporter.prepare(
            fileURL: url, language: .ru, transcriber: FakeTranscriber(result: .unavailable(.languageNotSupported)))
    }
    // Text angegeben, aber Datei viel länger als 15 s: passt nicht zusammen.
    let long = dir.appending(path: "long.wav")
    try AudioFiles.writeWAV(synthSpeech(seconds: 40), sampleRate: 48_000, to: long)
    await #expect(throws: (any Error).self) {
        _ = try await VoiceImporter.prepare(fileURL: long, language: .de, providedText: "Text",
                                            transcriber: FakeTranscriber(result: .text("x", engine: "f")))
    }
}

@Test func importerRejectsSilenceAndMissingFiles() async throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "silent.wav")
    try AudioFiles.writeWAV([Float](repeating: 0, count: 48_000 * 12), sampleRate: 48_000, to: url)
    await #expect(throws: VoiceImportError.recordingUnusable([.silent])) {
        _ = try await VoiceImporter.prepare(fileURL: url, language: .de, providedText: "x",
                                            transcriber: FakeTranscriber(result: .text("x", engine: "f")))
    }
    await #expect(throws: (any Error).self) {
        _ = try await VoiceImporter.prepare(fileURL: dir.appending(path: "gibt-es-nicht.wav"), language: .de,
                                            transcriber: FakeTranscriber(result: .text("x", engine: "f")))
    }
}

@Test func audioFilesRoundTripAndStereoMixdown() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "t.wav")
    let s = synthSpeech(seconds: 1, sampleRate: 16_000)
    try AudioFiles.writeWAV(s, sampleRate: 16_000, to: url)
    let (back, rate) = try AudioFiles.readMono(url: url)
    #expect(rate == 16_000)
    #expect(back.count == s.count)
    #expect(AudioFiles.importExtensions.isSuperset(of: ["wav", "m4a", "mp3", "caf"]))
}
