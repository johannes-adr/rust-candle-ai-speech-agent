import Foundation
import Testing
import TextPrep
@testable import Speech

/// Eingechecktes `Resources/Voices` (fünf Pfadteile über dieser Datei).
private func repoVoices() -> VoiceStore {
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { dir = dir.deletingLastPathComponent() }
    return VoiceStore(directory: dir.appending(path: "Resources/Voices", directoryHint: .isDirectory))
}

@Test func presetsFileIsParsed() {
    let store = repoVoices()
    #expect(store.styles == ["calm", "happy", "fairytale", "factual"])
    #expect(store.allPresets.count == 20)
    for l in Language.allCases { #expect(store.presets(for: l).count == 2, "zwei Stimmen für \(l)") }
    #expect(store.preset(id: "de-helga")?.name == "Helga")
    #expect(store.preset(id: "pt-teresa")?.language == .pt)
    #expect(store.styleDesign["calm"] != nil)
    #expect(store.allPresets.allSatisfy { $0.design?.isEmpty == false })
}

@Test func checkedInReferencesAreUsable() throws {
    let store = repoVoices()
    for id in ["de-helga", "pt-teresa"] {
        #expect(store.availableStyles(voiceID: id) == ["calm"])
        let url = try #require(store.referenceURL(voiceID: id, style: "calm"))
        let (samples, rate) = try AudioResampler.readMono(url: url)
        // 10–12 s, 24 kHz (S1-Referenz), kein NaN.
        #expect(rate == 24_000)
        #expect(samples.count > Int(8 * rate) && samples.count < Int(13 * rate))
        #expect(samples.allSatisfy { $0.isFinite })
        #expect(store.referenceText(voiceID: id, style: "calm")?.count ?? 0 > 40)
    }
}

@Test func voiceBuildsFromStyleWithFallback() {
    let store = repoVoices()
    let v = store.voice(id: "de-helga", style: "calm")
    #expect(v?.language == .de)
    #expect(v?.kind == .preset)
    #expect(v?.referenceAudio.pathExtension == "caf")
    // Stil ohne Datei: ohne Rückfall nil, mit Rückfall „calm“.
    #expect(store.voice(id: "de-helga", style: "happy") == nil)
    #expect(store.voice(id: "de-helga", style: "happy", fallback: true)?.referenceAudio.lastPathComponent == "de-helga-calm.caf")
    #expect(store.voice(id: "de-karl", style: nil) == nil, "keine Referenz vorhanden")
    #expect(store.voice(id: "gibt-es-nicht", style: nil) == nil)
}

@Test func missingDirectoryGivesEmptyStore() {
    let store = VoiceStore(directory: URL(fileURLWithPath: "/nonexistent-voices"))
    #expect(store.allPresets.isEmpty)
    #expect(store.voice(id: "de-helga", style: nil) == nil)
}
