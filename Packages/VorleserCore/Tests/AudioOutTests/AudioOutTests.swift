import Foundation
import Testing
@testable import AudioOut

// MARK: - ChunkQC

@Suite struct ChunkQCTests {
    let rate = 24_000.0

    @Test func cleanSineIsNotSuspicious() {
        let s = Synth.sine(freq: 440, seconds: 2, sampleRate: rate)
        let (out, report) = ChunkQC.analyze(samples: s, sampleRate: rate, characterCount: 28)
        #expect(report.issues.isEmpty)
        #expect(report.nonFiniteCount == 0)
        #expect(abs(report.peakDBFS - -6) < 0.1)
        #expect(abs(report.rmsDBFS - -9.01) < 0.1)
        #expect(out.count == s.count)
        #expect(abs((report.durationRatio ?? 0) - 1.0) < 0.01)
    }

    @Test func nonFiniteIsDetectedAndCleaned() {
        var s = Synth.sine(freq: 440, seconds: 1, sampleRate: rate)
        s[100] = .nan
        s[2000] = .infinity
        s[3000] = -.infinity
        let (out, report) = ChunkQC.analyze(samples: s, sampleRate: rate)
        #expect(report.issues.contains(.nonFinite))
        #expect(report.nonFiniteCount == 3)
        #expect(report.isSuspicious)
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test func clippingIsDetected() {
        var s = Synth.sine(freq: 440, seconds: 1, sampleRate: rate)
        for i in stride(from: 0, to: s.count, by: 50) { s[i] = 1.0 }
        let (_, report) = ChunkQC.analyze(samples: s, sampleRate: rate)
        #expect(report.issues.contains(.clipping))
        #expect(report.clippingFraction > 0.01)
    }

    @Test func silenceAtEdgesIsTrimmedWithMargin() {
        let tone = Synth.sine(freq: 440, seconds: 1, sampleRate: rate)
        let s = Synth.silence(seconds: 0.5, sampleRate: rate) + tone + Synth.silence(seconds: 0.3, sampleRate: rate)
        var cfg = ChunkQCConfig()
        cfg.keepMarginSeconds = 0.02
        let (out, report) = ChunkQC.analyze(samples: s, sampleRate: rate, config: cfg)
        #expect(abs(report.trimmedDurationSeconds - 1.04) < 0.01)
        #expect(abs(report.leadingSilenceSeconds - 0.48) < 0.01)
        #expect(abs(report.trailingSilenceSeconds - 0.28) < 0.01)
        #expect(abs(Double(out.count) / rate - 1.04) < 0.01)
    }

    @Test func pureSilenceIsFlagged() {
        let (out, report) = ChunkQC.analyze(samples: Synth.silence(seconds: 1, sampleRate: rate), sampleRate: rate)
        #expect(out.isEmpty)
        #expect(report.issues.contains(.silent))
    }

    @Test func emptyInputIsFlagged() {
        let (_, report) = ChunkQC.analyze(samples: [], sampleRate: rate)
        #expect(report.issues.contains(.empty))
    }

    @Test func durationPlausibility() {
        let one = Synth.sine(freq: 300, seconds: 1, sampleRate: rate)
        // 140 Zeichen bei 14 Zeichen/s = 10 s erwartet; 1 s ist 0,1×.
        let short = ChunkQC.analyze(samples: one, sampleRate: rate, characterCount: 140).report
        #expect(short.issues.contains(.tooShort))
        // 7 Zeichen = 0,5 s erwartet; 1 s ist 2,0× → genau an der Grenze, noch ok.
        let edge = ChunkQC.analyze(samples: one, sampleRate: rate, characterCount: 7).report
        #expect(!edge.issues.contains(.tooLong))
        // 5 Zeichen = 0,36 s erwartet; 1 s ist 2,8×.
        let long = ChunkQC.analyze(samples: one, sampleRate: rate, characterCount: 5).report
        #expect(long.issues.contains(.tooLong))
    }

    @Test func reportIsCodable() throws {
        let (_, report) = ChunkQC.analyze(
            samples: Synth.sine(freq: 440, seconds: 1, sampleRate: rate), sampleRate: rate, characterCount: 14)
        let data = try JSONEncoder().encode(report)
        let back = try JSONDecoder().decode(ChunkQCReport.self, from: data)
        #expect(back == report)
    }
}

// MARK: - Resampling

@Suite struct ResamplerTests {
    @Test(arguments: [24_000.0, 16_000.0, 22_050.0, 48_000.0])
    func keepsFrequencyAndDuration(inRate: Double) throws {
        let s = Synth.sine(freq: 1000, seconds: 2, sampleRate: inRate, amplitudeDB: -6)
        let out = try Resampler.resample(s, from: inRate, to: 44_100)
        #expect(out.count == Int((Double(s.count) * 44_100 / inRate).rounded()))
        // Mitte betrachten, um Randeffekte auszuschließen.
        let mid = Array(out[4410..<(out.count - 4410)])
        let f = Synth.zeroCrossingFrequency(mid, sampleRate: 44_100)
        #expect(abs(f - 1000) < 2, "Frequenz \(f)")
        let amp = Synth.amplitude(of: mid, freq: 1000, sampleRate: 44_100)
        #expect(abs(amp - 0.501) < 0.02, "Amplitude \(amp)")
    }

    @Test func isBandLimited() throws {
        // 15 kHz bei 44,1 kHz → 24 kHz: oberhalb der neuen Nyquist-Frequenz (12 kHz),
        // muss stark gedämpft werden (lineare Interpolation würde ein Aliasing-Signal liefern).
        let s = Synth.sine(freq: 15_000, seconds: 1, sampleRate: 44_100, amplitudeDB: -6)
        let out = try Resampler.resample(s, from: 44_100, to: 24_000)
        let mid = Array(out[2400..<(out.count - 2400)])
        let rms = (mid.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(mid.count)).squareRoot()
        #expect(20 * log10(rms) < -60, "Restpegel \(20 * log10(rms)) dBFS")
    }

    @Test func identityAndEmpty() throws {
        let s = Synth.sine(freq: 440, seconds: 0.1, sampleRate: 44_100)
        #expect(try Resampler.resample(s, from: 44_100, to: 44_100) == s)
        #expect(try Resampler.resample([], from: 24_000, to: 44_100).isEmpty)
    }

    @Test func invalidRateThrows() {
        #expect(throws: AudioOutError.self) { try Resampler.resample([0, 0], from: 0, to: 44_100) }
    }
}

// MARK: - Lautheit

@Suite struct LoudnessTests {
    @Test(arguments: [44_100.0, 48_000.0, 24_000.0])
    func sine997FullScaleIsMinus3LUFS(rate: Double) throws {
        let s = Synth.sine(freq: 997, seconds: 6, sampleRate: rate, amplitudeDB: 0)
        let l = try #require(Loudness.integratedLUFS(of: s, sampleRate: rate))
        #expect(abs(l - -3.01) < 0.1, "LUFS \(l)")
    }

    @Test func levelScalesLinearlyInDB() throws {
        let s = Synth.sine(freq: 997, seconds: 6, sampleRate: 44_100, amplitudeDB: -20)
        let l = try #require(Loudness.integratedLUFS(of: s, sampleRate: 44_100))
        #expect(abs(l - -23.01) < 0.1, "LUFS \(l)")
    }

    @Test func gatingIgnoresSilence() throws {
        let tone = Synth.sine(freq: 997, seconds: 4, sampleRate: 44_100, amplitudeDB: -20)
        let padded = tone + Synth.silence(seconds: 20, sampleRate: 44_100) + tone
        let l = try #require(Loudness.integratedLUFS(of: padded, sampleRate: 44_100))
        #expect(abs(l - -23.01) < 0.25, "LUFS \(l)")
    }

    @Test func lowFrequencyIsWeightedDown() throws {
        // 50 Hz liegt im Bereich des RLB-Hochpasses und ist leiser als 997 Hz.
        let low = try #require(Loudness.integratedLUFS(
            of: Synth.sine(freq: 50, seconds: 6, sampleRate: 48_000, amplitudeDB: -20), sampleRate: 48_000))
        #expect(low < -23.5)
    }

    @Test func shortSignalStillMeasured() throws {
        let s = Synth.sine(freq: 997, seconds: 0.2, sampleRate: 44_100, amplitudeDB: -20)
        let l = try #require(Loudness.integratedLUFS(of: s, sampleRate: 44_100))
        #expect(abs(l - -23.01) < 0.5, "LUFS \(l)")
    }

    @Test func silenceHasNoLoudness() {
        #expect(Loudness.integratedLUFS(of: Synth.silence(seconds: 2, sampleRate: 44_100), sampleRate: 44_100) == nil)
        #expect(Loudness.gainDB(measuredLUFS: nil, targetLUFS: -18) == 0)
    }

    @Test func gainIsClamped() {
        #expect(Loudness.gainDB(measuredLUFS: -18, targetLUFS: -18) == 0)
        #expect(Loudness.gainDB(measuredLUFS: -60, targetLUFS: -18, maxAbsDB: 24) == 24)
        #expect(abs(Loudness.gainDB(measuredLUFS: -28, targetLUFS: -18) - 10) < 1e-9)
    }

    @Test func limiterKeepsCeiling() {
        var s = Synth.sine(freq: 200, seconds: 1, sampleRate: 44_100, amplitudeDB: 0).map { $0 * 2.5 }
        let ceiling = Double(DB.toLinear(-1.5))
        PeakLimiter.limit(&s, sampleRate: 44_100, ceilingDBFS: -1.5)
        #expect(Double(PeakLimiter.samplePeak(s)) <= ceiling + 1e-4)
        #expect(Double(PeakLimiter.truePeak(s)) <= ceiling * 1.01)
        // Es muss noch Signal übrig sein.
        #expect(PeakLimiter.samplePeak(s) > 0.5)
    }

    @Test func limiterLeavesQuietSignalAlone() {
        let s = Synth.sine(freq: 200, seconds: 0.5, sampleRate: 44_100, amplitudeDB: -12)
        var t = s
        PeakLimiter.limit(&t, sampleRate: 44_100, ceilingDBFS: -1.5)
        #expect(t == s)
    }
}

// MARK: - Tempo

@Suite struct TempoTests {
    @Test(arguments: [0.8, 1.1, 1.2])
    func changesDurationKeepsPitch(tempo: Double) throws {
        let rate = 24_000.0
        let s = Synth.sine(freq: 440, seconds: 2, sampleRate: rate)
        let out = try TempoShifter.apply(s, sampleRate: rate, tempo: tempo)
        let expected = Double(s.count) / tempo
        #expect(abs(Double(out.count) - expected) < 0.02 * expected)
        let mid = Array(out[out.count / 4..<(out.count * 3 / 4)])
        let f = Synth.zeroCrossingFrequency(mid, sampleRate: rate)
        #expect(abs(f - 440) < 8, "Frequenz \(f)")
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test func unityIsIdentity() throws {
        let s = Synth.sine(freq: 440, seconds: 0.2, sampleRate: 24_000)
        #expect(try TempoShifter.apply(s, sampleRate: 24_000, tempo: 1.0) == s)
    }

    @Test func rejectsOutOfRange() {
        #expect(throws: AudioOutError.self) { try TempoShifter.apply([0.1], sampleRate: 24_000, tempo: 1.5) }
    }
}

// MARK: - CAF

@Suite struct CAFTests {
    @Test func roundTripKeepsSamplesAndRate() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = Synth.noise(seconds: 0.5, sampleRate: 24_000)
        let store = ChunkStore(directory: dir.appendingPathComponent("chunks"))
        try store.write(s, sampleRate: 24_000, index: 1)
        try store.write(s, sampleRate: 24_000, index: 3)
        #expect(store.exists(index: 1))
        #expect(!store.exists(index: 2))
        // Angefangene Datei zählt nicht.
        FileManager.default.createFile(
            atPath: store.directory.appendingPathComponent("0004.part.caf").path, contents: Data([1]))
        #expect(store.existingIndices() == [1, 3])
        let (back, rate) = try store.read(index: 1)
        #expect(rate == 24_000)
        #expect(back == s)
        #expect(store.url(forIndex: 7).lastPathComponent == "0007.caf")
    }

    @Test func emptyChunkRoundTrips() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("e.caf")
        try CAFFile.write([], sampleRate: 24_000, to: url)
        let (s, r) = try CAFFile.read(from: url)
        #expect(s.isEmpty)
        #expect(r == 24_000)
    }
}

// MARK: - Pausen und Export

@Suite struct ExportTests {
    @Test func pauseLengths() {
        let o = ExportOptions()
        #expect(AudioExporter.silence(.none, options: o).count == 0)
        #expect(AudioExporter.silence(.sentence, options: o).count == Int((0.35 * 44_100).rounded()))
        #expect(AudioExporter.silence(.paragraph, options: o).count == Int((0.8 * 44_100).rounded()))
        #expect(AudioExporter.silence(.chapter, options: o).count == Int((1.5 * 44_100).rounded()))
    }

    @Test func preparedChunkIsFadedAndResampled() throws {
        var o = ExportOptions()
        o.fadeSeconds = 0.010
        let s = Synth.sine(freq: 300, seconds: 1, sampleRate: 24_000, amplitudeDB: -6)
        let out = try AudioExporter.prepare(ExportChunk(samples: s, sampleRate: 24_000), options: o)
        #expect(abs(Double(out.count) / 44_100 - 1.04) < 0.05)   // inkl. 20 ms Rand je Seite, falls Sinus-Nullen getrimmt
        #expect(abs(out.first ?? 1) < 0.01)
        #expect(abs(out.last ?? 1) < 0.01)
        // Kein Sprung: größter Sample-zu-Sample-Schritt bleibt klein (300-Hz-Sinus bei -6 dBFS: < 0,05).
        var maxStep: Float = 0
        for i in 1..<out.count { maxStep = max(maxStep, abs(out[i] - out[i - 1])) }
        #expect(maxStep < 0.06)
    }

    @Test func nonFiniteChunkDoesNotPoisonOutput() throws {
        var s = Synth.sine(freq: 300, seconds: 1, sampleRate: 24_000)
        s[500] = .nan
        let out = try AudioExporter.prepare(ExportChunk(samples: s, sampleRate: 24_000), options: ExportOptions())
        #expect(out.allSatisfy { $0.isFinite })
    }

    @Test func sanitizesFileNames() {
        #expect(AudioExporter.sanitizedFileName("Kapitel 1: Der/Anfang?") == "Kapitel 1_ Der_Anfang_")
        #expect(AudioExporter.sanitizedFileName("   ") == "Kapitel")
    }

    @Test func emptyInputThrows() {
        #expect(throws: AudioOutError.self) {
            try AudioExporter.export(chunks: [], to: URL(fileURLWithPath: "/tmp/x.mp3"))
        }
    }
}

// MARK: - MP3 (ffprobe/ffmpeg nur als Prüfwerkzeug)

@Suite struct MP3Tests {
    static func speechLike(seed: UInt64) -> [Float] {
        // Moduliertes Rauschen plus Sinus: grob sprachähnliche Hüllkurve.
        let rate = 24_000.0
        let n = Synth.noise(seconds: 3, sampleRate: rate, amplitude: 0.2, seed: seed)
        let t = Synth.sine(freq: 180, seconds: 3, sampleRate: rate, amplitudeDB: -12)
        return (0..<n.count).map { i in
            let env = Float(0.5 + 0.5 * sin(2 * Double.pi * 3 * Double(i) / rate))
            return (n[i] * 0.5 + t[i]) * env
        }
    }

    @Test(.enabled(if: Tools.ffprobe != nil))
    func writerProducesValidCBRMono() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("test.mp3")
        let w = try MP3Writer(
            destination: url,
            tags: MP3Tags(
                title: "Größe & Maß — 日本語 Привет", artist: "Stimme Anna", album: "Mein Dokument",
                track: 2, trackCount: 5, comment: "Mit KI vorgelesen"))
        let tone = Synth.sine(freq: 440, seconds: 5, sampleRate: 44_100, amplitudeDB: -12)
        // Absichtlich ungleiche Blockgrößen.
        var off = 0
        for size in [1, 1000, 77_777, 100_000, 50_000] {
            let end = min(off + size, tone.count)
            try w.append(Array(tone[off..<end]))
            off = end
        }
        try w.append(Array(tone[off...]))
        // Vor finalize existiert nur .part.
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try w.finalize()
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: url.path + ".part"))

        let info = try Tools.probe(url)
        let stream = try #require((info["streams"] as? [[String: Any]])?.first)
        #expect(stream["codec_name"] as? String == "mp3")
        #expect(stream["sample_rate"] as? String == "44100")
        #expect(stream["channels"] as? Int == 1)
        let format = try #require(info["format"] as? [String: Any])
        #expect(format["format_name"] as? String == "mp3")
        let duration = Double(format["duration"] as? String ?? "") ?? 0
        #expect(abs(duration - 5.0) < 0.06, "Dauer \(duration)")
        let bitrate = Int(stream["bit_rate"] as? String ?? format["bit_rate"] as? String ?? "") ?? 0
        #expect(bitrate == 64_000, "Bitrate \(bitrate)")

        let tags = try #require(format["tags"] as? [String: Any])
        func tag(_ k: String) -> String? {
            (tags.first { $0.key.lowercased() == k }?.value) as? String
        }
        #expect(tag("title") == "Größe & Maß — 日本語 Привет")
        #expect(tag("artist") == "Stimme Anna")
        #expect(tag("album") == "Mein Dokument")
        #expect(tag("track") == "2/5")
        #expect(tag("comment") == "Mit KI vorgelesen")

        // Info/Xing-Header direkt hinter dem ID3v2-Tag.
        let data = try Data(contentsOf: url)
        #expect(Array(data.prefix(3)) == Array("ID3".utf8))
        let head = data.prefix(8192)
        let hasInfo = head.range(of: Data("Info".utf8)) != nil || head.range(of: Data("Xing".utf8)) != nil
        #expect(hasInfo)
        // Kein ID3v1-Tag am Ende.
        #expect(Array(data.suffix(128).prefix(3)) != Array("TAG".utf8))
    }

    @Test func abortLeavesNothingBehind() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.mp3")
        let w = try MP3Writer(destination: url, tags: MP3Tags(title: "x"))
        try w.append(Synth.sine(freq: 440, seconds: 1, sampleRate: 44_100))
        w.abort()
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        #expect(throws: AudioOutError.self) { try w.append([0]) }
    }

    @Test(.enabled(if: Tools.ffprobe != nil && Tools.ffmpeg != nil))
    func exporterBuildsFileAndChapters() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Abschnitte teils im Speicher, teils aus CAF-Zwischenspeicher.
        let store = ChunkStore(directory: dir.appendingPathComponent("chunks"))
        let a = Self.speechLike(seed: 1), b = Self.speechLike(seed: 2), c = Self.speechLike(seed: 3)
        try store.write(b, sampleRate: 24_000, index: 2)
        let chunks = [
            ExportChunk(samples: a, sampleRate: 24_000, pauseAfter: .sentence, chapter: 1),
            ExportChunk(cafURL: store.url(forIndex: 2), pauseAfter: .chapter, chapter: 1),
            ExportChunk(samples: c, sampleRate: 24_000, pauseAfter: .paragraph, chapter: 2),
            ExportChunk(samples: a, sampleRate: 24_000, pauseAfter: .none, chapter: 2),
        ]
        var o = ExportOptions()
        o.documentTitle = "Testbuch"
        o.voiceName = "Sprecherin"
        o.chapterDirectory = dir.appendingPathComponent("Kapitel")
        o.chapterTitles = [1: "Anfang", 2: "Ende"]
        let main = dir.appendingPathComponent("Testbuch.mp3")
        let result = try AudioExporter.export(chunks: chunks, to: main, options: o)

        #expect(result.chapterFiles.map(\.lastPathComponent) == ["01 Anfang.mp3", "02 Ende.mp3"])
        // Erwartete Dauer: 4 × ~3 s + 0,35 + 1,5 + 0,8 Pausen (Ränder können wenige ms kürzer sein).
        let expected = 12.0 + 0.35 + 1.5 + 0.8
        #expect(abs(result.durationSeconds - expected) < 0.3, "Dauer \(result.durationSeconds)")
        let probed = Double((try Tools.probe(main)["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        #expect(abs(probed - result.durationSeconds) < 0.06)

        // Kapiteldatei 1 enthält ihre Pause zwischen den zwei Abschnitten, aber nicht die Kapitelpause am Ende.
        let ch1 = Double((try Tools.probe(result.chapterFiles[0])["format"] as? [String: Any])?["duration"] as? String ?? "") ?? 0
        #expect(abs(ch1 - (6.0 + 0.35)) < 0.2, "Kapitel 1: \(ch1)")
        let ch1Tags = try #require((try Tools.probe(result.chapterFiles[0])["format"] as? [String: Any])?["tags"] as? [String: Any])
        #expect(ch1Tags.first { $0.key.lowercased() == "track" }?.value as? String == "1/2")
        #expect(ch1Tags.first { $0.key.lowercased() == "album" }?.value as? String == "Testbuch")

        // Lautheit der fertigen Datei nahe −18 LUFS, Spitzen ≤ −1,5 dBFS (+ Codec-Überschwinger).
        let decoded = try Tools.decode(main)
        let l = try #require(Loudness.integratedLUFS(of: decoded, sampleRate: 44_100))
        #expect(abs(l - -18) < 1.0, "Lautheit \(l)")
        let peak = DB.fromLinear(Double(PeakLimiter.samplePeak(decoded)))
        #expect(peak < -0.8, "Spitze \(peak) dBFS")
        #expect(decoded.allSatisfy { $0.isFinite })
        #expect(abs(result.appliedGainDB) < 24)
    }

    @Test func tempoShortensExport() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chunk = [ExportChunk(samples: Self.speechLike(seed: 5), sampleRate: 24_000)]
        var o = ExportOptions()
        let normal = try AudioExporter.export(chunks: chunk, to: dir.appendingPathComponent("n.mp3"), options: o)
        o.tempo = 1.2
        let fast = try AudioExporter.export(chunks: chunk, to: dir.appendingPathComponent("f.mp3"), options: o)
        #expect(abs(fast.durationSeconds - normal.durationSeconds / 1.2) < 0.15)
    }
}
