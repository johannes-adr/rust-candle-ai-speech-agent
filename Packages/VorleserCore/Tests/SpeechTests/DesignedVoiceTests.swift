// Beschriebene Stimmen im Format der eigenen Stimmen (RecordedVoiceStore, kind .designed).
import Foundation
import TextPrep
import Testing

@testable import VorleserSpeech

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "vorleser-designed-\(UUID().uuidString)")
}

private func tone(_ seconds: Double = 2, rate: Double = 24_000) -> [Float] {
    (0..<Int(rate * seconds)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
}

@Test func designedVoiceRoundtrip() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RecordedVoiceStore(directory: dir)
    let saved = try store.saveDesigned(
        samples: tone(), sampleRate: 24_000, referenceText: "Heute ist ein schöner Tag.", name: "  Oma Helga  ",
        language: .de, wish: "ruhig und warm", prompt: "The voice of …", seed: 99)
    #expect(saved.id.hasPrefix(RecordedVoiceStore.idPrefix))
    #expect(saved.kind == .designed)
    #expect(saved.name == "Oma Helga")
    #expect(saved.description == "ruhig und warm")
    for ext in ["caf", "txt", "json"] {
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "\(saved.id).\(ext)").path), "\(ext) fehlt")
    }
    let loaded = try #require(store.voice(id: saved.id))
    #expect(loaded.kind == .designed)
    #expect(loaded.referenceText == "Heute ist ein schöner Tag.")
    #expect(loaded.description == "ruhig und warm")
    let info = try #require(store.info(id: saved.id))
    #expect(info.kind == .designed && info.prompt == "The voice of …" && info.seed == 99 && info.consent)
    #expect(store.isDesigned(id: saved.id))
    let (samples, rate) = try AudioResampler.readMono(url: loaded.referenceAudio)
    #expect(rate == 24_000 && samples.count == 48_000)
}

@Test func designedAndRecordedAreSeparatedButShareFolder() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let custom = RecordedVoiceStore(directory: dir)
    let d = try custom.saveDesigned(
        samples: tone(), sampleRate: 24_000, referenceText: "x", name: "D", language: .de, wish: "w", prompt: nil, seed: nil)
    let r = try custom.save(
        samples: tone(), sampleRate: 24_000, transcript: "x", name: "R", language: .de, consent: true,
        source: "recording", transcriptSource: "reading")
    let store = VoiceStore(customDirectory: dir)
    #expect(store.designedVoices(for: .de).map(\.id) == [d.id])
    #expect(store.recordedVoices(for: .de).map(\.id) == [r.id], "Aufnahmen-Reihe zeigt keine beschriebenen Stimmen")
    #expect(!custom.isDesigned(id: r.id))
    // Die Engine bekommt beide über dieselbe ID-Auflösung.
    #expect(store.voice(id: d.id)?.kind == .designed)
    #expect(store.voice(id: r.id)?.kind == .recorded)
}

@Test func oldRecordedMetadataWithoutDesignFieldsStillLoads() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let custom = RecordedVoiceStore(directory: dir)
    let r = try custom.save(
        samples: tone(), sampleRate: 24_000, transcript: "x", name: "R", language: .pt, consent: true,
        source: "recording", transcriptSource: "reading")
    let info = try #require(custom.info(id: r.id))
    #expect(info.wish == nil && info.prompt == nil && info.seed == nil)
}

@Test func designedVoiceNeedsAudioToBeListed() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let custom = RecordedVoiceStore(directory: dir)
    let d = try custom.saveDesigned(
        samples: tone(), sampleRate: 24_000, referenceText: "x", name: "D", language: .de, wish: "w", prompt: nil, seed: nil)
    try FileManager.default.removeItem(at: custom.audioURL(id: d.id))
    #expect(custom.designedList(language: .de).isEmpty)
}
