import AVFoundation
import Foundation
import Testing
import TextPrep
@testable import VorleserSpeech

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "rv-\(UUID().uuidString)", directoryHint: .isDirectory)
}

private func tone(_ seconds: Double = 11, rate: Double = 44_100) -> [Float] {
    (0..<Int(seconds * rate)).map { Float(0.3 * sin(2 * Double.pi * 180 * Double($0) / rate)) }
}

@Test func recordedVoiceNeedsConsent() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RecordedVoiceStore(directory: dir)
    #expect(throws: RecordedVoiceError.consentMissing) {
        try store.save(samples: tone(), sampleRate: 44_100, transcript: "Hallo Welt.", name: "Oma", language: .de,
                       consent: false, source: "recording", transcriptSource: "reading")
    }
    // Nichts darf auf der Platte liegen.
    #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
    #expect(store.list().isEmpty)
}

@Test func recordedVoiceRoundTrip() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RecordedVoiceStore(directory: dir)
    let saved = try store.save(
        samples: tone(), sampleRate: 44_100, transcript: "  Guten Tag.  ", name: " Meine Stimme ", language: .de,
        consent: true, source: "recording", transcriptSource: "reading")
    #expect(saved.id.hasPrefix("own-"))
    #expect(saved.kind == .recorded)
    #expect(saved.referenceText == "Guten Tag.")
    #expect(saved.name == "Meine Stimme")

    let loaded = try #require(store.voice(id: saved.id))
    #expect(loaded.referenceText == "Guten Tag.")
    #expect(loaded.language == .de)
    // ALAC lässt sich lesen, Dauer stimmt (verlustfrei).
    let file = try AVAudioFile(forReading: loaded.referenceAudio)
    #expect(file.processingFormat.sampleRate == 44_100)
    #expect(abs(Double(file.length) / 44_100 - 11) < 0.05)

    let info = try #require(store.info(id: saved.id))
    #expect(info.consent)
    #expect(info.kind == .recorded)
    #expect(info.source == "recording")
    #expect(abs(info.consentAt.timeIntervalSince(info.createdAt)) < 1)
    #expect(abs(info.durationSeconds - 11) < 0.05)
    #expect(store.list(language: .pt).isEmpty)
    #expect(store.list(language: .de).count == 1)

    try store.rename(id: saved.id, to: "Omas Stimme")
    #expect(store.info(id: saved.id)?.name == "Omas Stimme")

    try store.delete(id: saved.id)
    #expect(store.list().isEmpty)
    #expect(store.voice(id: saved.id) == nil)
    #expect(!FileManager.default.fileExists(atPath: store.audioURL(id: saved.id).path))
    #expect(throws: RecordedVoiceError.notFound(saved.id)) { try store.delete(id: saved.id) }
}

@Test func recordedVoiceRejectsEmptyInput() {
    let store = RecordedVoiceStore(directory: tempDir())
    #expect(throws: RecordedVoiceError.emptyAudio) {
        try store.save(samples: [], sampleRate: 44_100, transcript: "x", name: "a", language: .de, consent: true,
                       source: "recording", transcriptSource: "reading")
    }
    #expect(throws: RecordedVoiceError.emptyTranscript) {
        try store.save(samples: tone(), sampleRate: 44_100, transcript: "  ", name: "a", language: .de, consent: true,
                       source: "recording", transcriptSource: "reading")
    }
}

@Test func emptyNameBecomesDefault() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let v = try RecordedVoiceStore(directory: dir).save(
        samples: tone(), sampleRate: 44_100, transcript: "x", name: "  ", language: .pt, consent: true,
        source: "import", transcriptSource: "recognized")
    #expect(v.name == "Meine Stimme")
}

@Test func voiceWithoutConsentOnDiskIsIgnored() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = RecordedVoiceStore(directory: dir)
    let v = try store.save(samples: tone(), sampleRate: 44_100, transcript: "x", name: "a", language: .de,
                           consent: true, source: "recording", transcriptSource: "reading")
    // Metadaten nachträglich auf consent=false setzen (z. B. von Hand bearbeitet).
    var json = try String(contentsOf: store.metadataURL(id: v.id), encoding: .utf8)
    json = json.replacingOccurrences(of: "\"consent\" : true", with: "\"consent\" : false")
    try json.write(to: store.metadataURL(id: v.id), atomically: true, encoding: .utf8)
    #expect(store.list().isEmpty)
    #expect(store.voice(id: v.id) == nil)
}

@Test func voiceStoreResolvesPresetsAndRecordedVoices() throws {
    var repo = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { repo = repo.deletingLastPathComponent() }
    let custom = tempDir()
    defer { try? FileManager.default.removeItem(at: custom) }
    let store = VoiceStore(directory: repo.appending(path: "Resources/Voices", directoryHint: .isDirectory), customDirectory: custom)
    let saved = try #require(store.custom).save(
        samples: tone(), sampleRate: 44_100, transcript: "Hallo.", name: "Ich", language: .de, consent: true,
        source: "recording", transcriptSource: "reading")
    // Eingebaute Stimme bleibt wie sie war.
    #expect(store.voice(id: "de-helga", style: "calm")?.kind == .preset)
    // Eigene Stimme, egal welcher Stil angefragt wird.
    let own = try #require(store.voice(id: saved.id, style: "happy", fallback: true))
    #expect(own.kind == .recorded)
    #expect(own.referenceText == "Hallo.")
    #expect(store.recordedVoices(for: .de).map(\.id) == [saved.id])
    #expect(store.recordedVoices(for: .pt).isEmpty)
    #expect(store.allPresets.count == 20)  // eigene Stimmen sind keine Presets
    // Ohne custom-Ordner: eigene Stimme unbekannt.
    let plain = VoiceStore(directory: repo.appending(path: "Resources/Voices", directoryHint: .isDirectory))
    #expect(plain.voice(id: saved.id, style: nil) == nil)
}
