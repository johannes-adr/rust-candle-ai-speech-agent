import Foundation
import Testing
import TextPrep

@testable import Speech

private func tempDir() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "vorleser-designed-\(UUID().uuidString)")
}

private func tone(_ seconds: Double = 2, rate: Double = 24_000) -> [Float] {
    (0..<Int(rate * seconds)).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
}

@Test func designedVoiceRoundtrip() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DesignedVoiceStore(directory: dir)
    #expect(store.list().isEmpty)

    let saved = try store.save(
        samples: tone(), sampleRate: 24_000, name: "  Oma Helga  ", language: .de,
        description: "ruhig und warm", referenceText: "Heute ist ein schöner Tag.",
        prompt: "The voice of …", seed: 99)
    #expect(DesignedVoiceStore.isDesignedID(saved.id))
    #expect(saved.kind == .designed)
    #expect(saved.name == "Oma Helga")

    for ext in ["caf", "txt", "json"] {
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "\(saved.id).\(ext)").path), "\(ext) fehlt")
    }
    let loaded = try #require(store.voice(id: saved.id))
    #expect(loaded == saved)
    #expect(loaded.referenceText == "Heute ist ein schöner Tag.")
    #expect(loaded.description == "ruhig und warm")
    #expect(loaded.referenceAudio.pathExtension == "caf")

    // Referenz ist lesbar und hat die gespeicherte Rate.
    let (samples, rate) = try AudioResampler.readMono(url: loaded.referenceAudio)
    #expect(rate == 24_000)
    #expect(samples.count == 48_000)

    let info = try #require(store.info(id: saved.id))
    #expect(info.kind == "designed")
    #expect(info.prompt == "The voice of …")
    #expect(info.seed == 99)
}

@Test func designedVoicesAreFilteredByLanguageAndSortedNewestFirst() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DesignedVoiceStore(directory: dir)
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let a = try store.save(samples: tone(), sampleRate: 24_000, name: "A", language: .de, description: "a", referenceText: "x", now: t0)
    let b = try store.save(samples: tone(), sampleRate: 24_000, name: "B", language: .pt, description: "b", referenceText: "x", now: t0 + 10)
    let c = try store.save(samples: tone(), sampleRate: 24_000, name: "C", language: .de, description: "c", referenceText: "x", now: t0 + 20)
    #expect(store.list().map(\.id) == [c.id, b.id, a.id])
    #expect(store.voices(for: .de).map(\.id) == [c.id, a.id])
    #expect(store.voices(for: .pt).map(\.id) == [b.id])
    #expect(store.voices(for: .fr).isEmpty)
}

@Test func renameAndDelete() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DesignedVoiceStore(directory: dir)
    let v = try store.save(samples: tone(), sampleRate: 24_000, name: "Alt", language: .de, description: "d", referenceText: "x")
    try store.rename(id: v.id, to: "Neu")
    #expect(store.voice(id: v.id)?.name == "Neu")
    try store.rename(id: v.id, to: "   ")
    #expect(store.voice(id: v.id)?.name == "Neu", "leerer Name ändert nichts")
    store.delete(id: v.id)
    #expect(store.voice(id: v.id) == nil)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? true)
}

@Test func emptyNameFallsBackToDescription() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let v = try DesignedVoiceStore(directory: dir).save(
        samples: tone(), sampleRate: 24_000, name: " ", language: .de, description: "wie ein Märchenerzähler", referenceText: "x")
    #expect(v.name == "wie ein Märchenerzähler")
}

@Test func incompleteAndForeignEntriesAreIgnored() throws {
    let dir = tempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DesignedVoiceStore(directory: dir)
    let good = try store.save(samples: tone(), sampleRate: 24_000, name: "Gut", language: .de, description: "d", referenceText: "x")
    // JSON ohne Audio (halber Abbruch)
    try FileManager.default.copyItem(at: dir.appending(path: "\(good.id).json"), to: dir.appending(path: "designed-halb.json"))
    // Eigene Aufnahme (Phase 3) mit anderem `kind` und anderem Aufbau
    try #"{"id":"recorded-1","name":"Ich","kind":"recorded"}"#.write(
        to: dir.appending(path: "recorded-1.json"), atomically: true, encoding: .utf8)
    // Kaputtes JSON
    try "{".write(to: dir.appending(path: "kaputt.json"), atomically: true, encoding: .utf8)
    #expect(store.list().map(\.id) == [good.id])
}

@Test func defaultDirectoryIsApplicationSupportOrDataDir() {
    let path = DesignedVoiceStore.defaultDirectory.path
    if ProcessInfo.processInfo.environment["VORLESER_DATA_DIR"] == nil {
        #expect(path.hasSuffix("Library/Application Support/Vorleser/Voices"))
    } else {
        #expect(path.hasSuffix("/Voices"))
    }
}
