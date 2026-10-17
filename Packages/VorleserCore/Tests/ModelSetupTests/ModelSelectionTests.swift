import Foundation
import Testing

@testable import ModelSetup

// Modellwahl: eingebauter Standard ohne Wahl, Wahl nur nach vollständigem Laden, Zurücksetzen,
// grobe Prüfung der Modellart.

@Test func withoutChoiceTheBuiltInDefaultApplies() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("selection-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = ModelStore(root: dir)

    let fourBit = try #require(ModelSelection.current(role: "base", bits: 4, store: store))
    #expect(!fourBit.isChosen)
    #expect(fourBit.ref == ModelCatalog.ref(kind: "base", bits: 4))
    #expect(fourBit.manifest != nil, "eingebautes Manifest fehlt")

    let eightBit = try #require(ModelSelection.current(role: "base", bits: 8, store: store))
    #expect(eightBit.ref == ModelCatalog.ref(kind: "base", bits: 8))
}

@Test func chosenModelWinsAfterInstallAndDefaultReturnsOnReset() async throws {
    let fx = try Fixture()
    defer { fx.cleanUp() }

    // Vor dem vollständigen Laden darf nichts gewählt werden.
    #expect(throws: ModelSelectionError.notReady(fx.ref.repo)) {
        try ModelSelection.choose(role: "base", manifest: fx.manifest, store: fx.store)
    }

    fx.serve()
    _ = try await collect(fx.installer().install([fx.manifest]))
    try ModelSelection.choose(role: "base", manifest: fx.manifest, store: fx.store)

    let chosen = try #require(ModelSelection.current(role: "base", bits: 4, store: fx.store))
    #expect(chosen.isChosen)
    #expect(chosen.ref == fx.ref)
    #expect(chosen.manifest == fx.manifest, "Dateiliste der Wahl muss aus dem Modellordner kommen")

    // Die andere Rolle bleibt beim Standard.
    #expect(try #require(ModelSelection.current(role: "voiceDesign", bits: 4, store: fx.store)).isChosen == false)

    try ModelSelection.resetToDefault(role: "base", store: fx.store)
    let back = try #require(ModelSelection.current(role: "base", bits: 4, store: fx.store))
    #expect(!back.isChosen)
    #expect(back.ref == ModelCatalog.ref(kind: "base", bits: 4))
}

@Test func roughCheckRejectsNonQwenAndWrongRole() throws {
    func manifest() -> ModelManifest {
        let files = ["config.json", "tokenizer_config.json", "model.safetensors", "speech_tokenizer/config.json"]
        return ModelManifest(repo: "o/m", revision: String(repeating: "c", count: 40), files: files.map {
            .init(path: $0, size: 1, sha256: String(repeating: "0", count: 64))
        })
    }
    func config(_ json: String) -> Data { Data(json.utf8) }

    // Richtige Art für die Rolle.
    try ModelChooser.check(manifest(), configData: config(#"{"model_type":"qwen3_tts","tts_model_type":"base"}"#), role: "base")

    // Anderes Modell (kein Qwen3-TTS).
    #expect(throws: ModelChooser.CheckError.self) {
        try ModelChooser.check(manifest(), configData: config(#"{"model_type":"llama"}"#), role: "base")
    }
    // Stimmen-Modell statt Base: passt nicht zur Rolle „base“.
    #expect(throws: ModelChooser.CheckError.wrongRole(expected: "base", found: "voice_design")) {
        try ModelChooser.check(manifest(), configData: config(#"{"model_type":"qwen3_tts","tts_model_type":"voice_design"}"#), role: "base")
    }
}
