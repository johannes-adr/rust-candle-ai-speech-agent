import AVFoundation
import Foundation
import Testing
import TextPrep
@testable import VorleserSpeech

@Test func referenceFilesRoundtrip() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "vorleser-ref-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let rate = 24_000.0
    let tone = (0..<Int(rate * 2)).map { Float(0.3 * sin(2 * Double.pi * 330 * Double($0) / rate)) }
    let wav = dir.appending(path: "a.wav"), caf = dir.appending(path: "a.caf")
    try ReferenceFiles.writeWAV(tone, sampleRate: rate, to: wav)
    try ReferenceFiles.writeALAC(tone, sampleRate: rate, to: caf)
    for url in [wav, caf] {
        let (s, r) = try AudioResampler.readMono(url: url)
        #expect(r == rate)
        #expect(s.count == tone.count)
        #expect(abs((s.max() ?? 0) - 0.3) < 0.01)
    }
    let alac = try AVAudioFile(forReading: caf)
    #expect(alac.fileFormat.settings[AVFormatIDKey] as? UInt32 == kAudioFormatAppleLossless)
    #expect(throws: SpeechAudioError.self) { try ReferenceFiles.writeWAV([], sampleRate: rate, to: dir.appending(path: "x.wav")) }
}

@Test func missingDirectoryGivesEmptyStore() {
    let store = VoiceStore(customDirectory: URL(fileURLWithPath: "/nonexistent-voices"))
    #expect(store.voices(for: .de).isEmpty)
    #expect(store.voice(id: "own-gibtsnicht") == nil)
}

@Test func oldPresetKindDecodesAsRecorded() throws {
    let kind = try JSONDecoder().decode([VoiceKind].self, from: Data(#"["preset","designed","recorded"]"#.utf8))
    #expect(kind == [.recorded, .designed, .recorded])
}
