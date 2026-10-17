import AVFoundation
import Foundation
import Testing
import ModelSetup
import TextPrep

@testable import VorleserSpeech

@Test func everyLanguageHasQwenName() {
    let names = Language.allCases.map(\.qwenName)
    #expect(Set(names).count == 10)
    #expect(Language.de.qwenName == "german")
    #expect(Language.pt.qwenName == "portuguese")
}

@Test func pinnedRevisionsAreFullSHAs() {
    for (kind, bits) in [(ModelKind.base, ModelBits.four), (.base, .eight), (.voiceDesign, .four)] {
        let spec = ModelSpec.pinned(kind, bits: bits)
        #expect(spec != nil)
        #expect(spec?.revision.count == 40)
    }
    #expect(ModelSpec.pinned(.voiceDesign, bits: .eight) == nil)
}

@Test func snapshotDirectoryFollowsHuggingFaceLayout() throws {
    let spec = try #require(ModelSpec.pinned(.base, bits: .four))
    let dir = spec.huggingFaceSnapshotDirectory(cacheRoot: URL(fileURLWithPath: "/tmp/hub"))
    #expect(dir.path == "/tmp/hub/models--mlx-community--Qwen3-TTS-12Hz-1.7B-Base-4bit/snapshots/\(spec.revision)")
}

@Test func missingModelThrows() async {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("leer-\(UUID())")
    let engine = MLXQwenEngine(bits: .four, store: ModelStore(root: empty), cacheRoot: URL(fileURLWithPath: "/nonexistent"))
    await #expect(throws: SpeechEngineError.self) { try await engine.load(.base) }
    let rate = await engine.sampleRate
    #expect(rate == 0)
}

@Test func languageIDsAreReadFromConfig() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cfg-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = #"{"talker_config":{"codec_language_id":{"german":2053,"english":2050}}}"#
    try json.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let ids = MLXQwenEngine.readLanguageIDs(modelDir: dir)
    #expect(ids == ["german": 2053, "english": 2050])
}

@Test func referenceIsResampledToModelRate() throws {
    // 1 s Sinus bei 48 kHz, als WAV geschrieben, auf 24 kHz bringen.
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ref-\(UUID()).caf")
    defer { try? FileManager.default.removeItem(at: url) }
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
    do {
    var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: fmt.settings)
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48000)!
    buf.frameLength = 48000
    for i in 0..<48000 { buf.floatChannelData![0][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48000) }
    try file!.write(from: buf)
    file = nil
    } // Datei schließen, bevor sie gelesen wird

    let raw = try AudioResampler.readMono(url: url)
    #expect(raw.samples.count == 48000, "gelesen: \(raw.samples.count) @ \(raw.sampleRate)")
    let out = try AudioResampler.loadReference(url: url, targetRate: 24000)
    #expect(abs(out.count - 24000) <= 2)
    #expect(out.allSatisfy { $0.isFinite })
    // Auf 0,5 s kürzen
    let short = try AudioResampler.loadReference(url: url, targetRate: 24000, maxSeconds: 0.5)
    #expect(abs(short.count - 12000) <= 2)
}

// Modell-Tests laufen nicht per `swift test`: dort findet MLX die default.metallib
// nicht ("Failed to load the default metallib"). Das Modell prüft `spike-s1` (siehe
// docs/spikes/S1-engine.md).
