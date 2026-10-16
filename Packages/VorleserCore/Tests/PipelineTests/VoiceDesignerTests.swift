// Prompt-Bau und Ablauf des VoiceDesigners ohne Modell (Attrappe mit Protokoll der Aufrufe).
import Foundation
import VorleserSpeech
import TextPrep
import Testing

@testable import Pipeline

/// Attrappe: merkt sich, welches Modell wann geladen ist, und liefert gezielt gute oder schlechte Referenzen.
actor DesignFakeEngine: SpeechEngine {
    enum Output: Sendable { case good, nan, silent, tooShort, fail }

    private(set) var events: [String] = []
    private(set) var loaded: ModelKind?
    /// Wie viele Modelle gleichzeitig geladen waren (muss 1 bleiben).
    private(set) var maxLoadedAtOnce = 0
    private(set) var seeds: [UInt64] = []
    private(set) var descriptions: [String] = []
    private let script: @Sendable (Int) -> Output
    private var designCalls = 0
    nonisolated let rate = 24_000.0
    var sampleRate: Double { loaded == nil ? 0 : rate }
    private let seconds: Double

    init(seconds: Double = 11, script: @escaping @Sendable (Int) -> Output = { _ in .good }) {
        self.script = script
        self.seconds = seconds
    }

    func load(_ model: ModelKind) async throws {
        if loaded == model { return }
        if loaded != nil { events.append("unload(implicit)") }
        loaded = model
        maxLoadedAtOnce = max(maxLoadedAtOnce, 1)
        events.append("load:\(model.rawValue)")
    }

    func unload() async {
        if loaded != nil { events.append("unload") }
        loaded = nil
    }

    func prepare(_ voice: Voice) async throws -> VoiceHandle { VoiceHandle(voiceID: voice.id) }

    func speak(_ text: String, voice: VoiceHandle, language: Language, seed: UInt64) -> AsyncThrowingStream<[Float], Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func design(description: String, sampleText: String, language: Language, seed: UInt64) async throws -> [Float] {
        guard loaded == .voiceDesign else { throw SpeechEngineError.wrongModel(expected: .voiceDesign, loaded: loaded ?? .base) }
        designCalls += 1
        events.append("design")
        seeds.append(seed)
        descriptions.append(description)
        let n = Int(seconds * rate)
        switch script(designCalls) {
        case .good: return (0..<n).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / rate)) }
        case .nan:
            var s = (0..<n).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / rate)) }
            s[n / 2] = .nan
            return s
        case .silent: return [Float](repeating: 0, count: n)
        case .tooShort: return (0..<(n / 10)).map { Float(0.3 * sin(2 * Double.pi * 200 * Double($0) / rate)) }
        case .fail: throw FakeError.boom
        }
    }
}

struct StubTranslator: DescriptionTranslating {
    var result: String?
    func translateToEnglish(_ text: String, from language: Language) async -> String? { result }
}

/// ca. 170 Zeichen → 10,8 s bei 15,8 Zeichen/s
private let readText = String(repeating: "Heute ist ein schöner Tag. ", count: 6) + "Ende."

// MARK: Prompt

@Test func promptAssemblesGenderAgeAndAccent() {
    let wish = VoiceWish(description: "calm and warm", readingLanguage: .de, gender: .female, age: .elderly)
    let text = VoicePromptBuilder.assemble(wishText: "calm and warm", wish: wish)
    #expect(text == "The voice of an elderly woman. calm and warm. A clear native German accent, speaking clearly and naturally.")
}

@Test func promptWithoutHintsHasNoVoiceOfSentence() {
    let wish = VoiceWish(description: "wie ein Märchenerzähler", readingLanguage: .pt)
    let text = VoicePromptBuilder.assemble(wishText: wish.description, wish: wish)
    #expect(!text.contains("The voice of"))
    #expect(text.hasPrefix("wie ein Märchenerzähler."))
    #expect(text.contains("native Portuguese"))
}

@Test func promptUsesRegionAndArticleAn() {
    let wish = VoiceWish(
        description: "warm", readingLanguage: .pt, gender: .male, age: .elderly, regionHint: "from Lisbon, Portugal")
    let text = VoicePromptBuilder.assemble(wishText: "warm", wish: wish)
    #expect(text.contains("The voice of an elderly man."))
    #expect(text.contains("accent, from Lisbon, Portugal, speaking"))
    let young = VoicePromptBuilder.assemble(wishText: "x", wish: VoiceWish(description: "x", readingLanguage: .de, gender: .female, age: .young))
    #expect(young.contains("a young woman"))
}

@Test func promptKeepsPunctuationOfWish() {
    let wish = VoiceWish(description: "ruhig!", readingLanguage: .de)
    #expect(VoicePromptBuilder.assemble(wishText: "ruhig!", wish: wish).contains("ruhig! "))
}

@Test func builderUsesTranslationOnlyWhenAvailable() async {
    let wish = VoiceWish(description: "ruhig und warm", descriptionLanguage: .de, readingLanguage: .de)
    let translated = await VoicePromptBuilder.build(wish, translator: StubTranslator(result: "calm and warm"))
    #expect(translated.source == .translated)
    #expect(translated.text.contains("calm and warm"))
    let fallback = await VoicePromptBuilder.build(wish, translator: StubTranslator(result: nil))
    #expect(fallback.source == .original)
    #expect(fallback.text.contains("ruhig und warm"))
    let none = await VoicePromptBuilder.build(wish, translator: nil)
    #expect(none.source == .original)
    let english = await VoicePromptBuilder.build(
        VoiceWish(description: "calm", descriptionLanguage: .en, readingLanguage: .de), translator: StubTranslator(result: "NEIN"))
    #expect(english.source == .english)
    #expect(!english.text.contains("NEIN"))
}

// MARK: Designer

@Test func designerMakesTwoProposalsAndUnloads() async throws {
    let engine = DesignFakeEngine()
    let designer = VoiceDesigner(engine: engine)
    let result = try await designer.propose(
        VoiceWish(description: "ruhig", readingLanguage: .de), referenceText: readText, seedBase: 7)
    #expect(result.proposals.count == 2)
    #expect(result.proposals.map(\.index) == [1, 2])
    #expect(result.proposals[0].seed != result.proposals[1].seed)
    #expect(result.proposals.allSatisfy { !$0.isSuspicious && $0.attempts == 1 })
    #expect(result.proposals.allSatisfy { $0.durationSeconds > 10 && $0.samples.allSatisfy(\.isFinite) })
    #expect(await engine.events == ["load:voiceDesign", "design", "design", "unload"])
    #expect(await engine.loaded == nil)
}

@Test func designerUnloadsBaseBeforeLoadingDesign() async throws {
    let engine = DesignFakeEngine()
    try await engine.load(.base)
    _ = try await VoiceDesigner(engine: engine).propose(
        VoiceWish(description: "ruhig", readingLanguage: .de), referenceText: readText, count: 1)
    let events = await engine.events
    #expect(events.first == "load:base")
    #expect(events[1] == "unload(implicit)")
    #expect(events[2] == "load:voiceDesign")
    #expect(events.last == "unload")
    #expect(await engine.maxLoadedAtOnce == 1)
}

@Test func designerRetriesWithNewSeedOnBadAudio() async throws {
    // Versuch 1 NaN, Versuch 2 stumm, Versuch 3 gut (für Vorschlag 1); Vorschlag 2 sofort gut.
    let engine = DesignFakeEngine { call in
        switch call {
        case 1: .nan
        case 2: .silent
        default: .good
        }
    }
    let result = try await VoiceDesigner(engine: engine).propose(
        VoiceWish(description: "ruhig", readingLanguage: .de), referenceText: readText, seedBase: 1)
    #expect(result.proposals.count == 2)
    #expect(result.proposals[0].attempts == 3)
    #expect(result.proposals[1].attempts == 1)
    let seeds = await engine.seeds
    #expect(Set(seeds).count == seeds.count, "jeder Versuch hat einen eigenen Seed")
    #expect(result.proposals.allSatisfy { !$0.isSuspicious })
}

@Test func designerFailsWhenNothingUsable() async {
    let engine = DesignFakeEngine { _ in .silent }
    await #expect(throws: VoiceDesignError.noUsableProposal) {
        try await VoiceDesigner(engine: engine).propose(
            VoiceWish(description: "ruhig", readingLanguage: .de), referenceText: readText)
    }
    #expect(await engine.loaded == nil, "auch nach Fehlschlag entladen")
}

@Test func designerKeepsBestSuspiciousButUsableAudio() async throws {
    // Immer zu kurz (1,1 s): kein Hard-Fehler, aber nie sauber → bester Versuch bleibt, als verdächtig markiert.
    let engine = DesignFakeEngine { _ in .tooShort }
    let result = try await VoiceDesigner(engine: engine).propose(
        VoiceWish(description: "ruhig", readingLanguage: .de), referenceText: readText, count: 1)
    #expect(result.proposals.count == 1)
    #expect(result.proposals[0].isSuspicious)
    #expect(await engine.seeds.count == 3, "drei Versuche mit je eigenem Seed")
}

@Test func designerUnloadsOnEngineErrorAndRejectsEmptyWish() async {
    let engine = DesignFakeEngine { _ in .fail }
    await #expect(throws: VoiceDesignError.self) {
        try await VoiceDesigner(engine: engine).propose(
            VoiceWish(description: "ruhig", readingLanguage: .de), referenceText: readText)
    }
    #expect(await engine.loaded == nil)
    await #expect(throws: VoiceDesignError.emptyWish) {
        try await VoiceDesigner(engine: DesignFakeEngine()).propose(
            VoiceWish(description: "   ", readingLanguage: .de), referenceText: readText)
    }
}

@Test func designerCancellationUnloads() async {
    let engine = DesignFakeEngine()
    let task = Task {
        try await VoiceDesigner(engine: engine).propose(
            VoiceWish(description: "ruhig", readingLanguage: .de), referenceText: readText)
    }
    task.cancel()
    _ = try? await task.value
    #expect(await engine.loaded == nil)
}

@Test func differentSeedBasesGiveDifferentSeeds() {
    #expect(VoiceDesigner.seed(base: 1, index: 1, attempt: 1) != VoiceDesigner.seed(base: 2, index: 1, attempt: 1))
    #expect(VoiceDesigner.seed(base: 1, index: 1, attempt: 1) == VoiceDesigner.seed(base: 1, index: 1, attempt: 1))
    #expect(VoiceDesigner.seed(base: 1, index: 1, attempt: 1) != VoiceDesigner.seed(base: 1, index: 2, attempt: 1))
}
