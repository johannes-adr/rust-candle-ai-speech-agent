// design-voice (Phase 4): aus einer Beschreibung zwei Vorschläge erzeugen, einen behalten
// und optional damit vorlesen (Design → Klon). Misst Zeit, RTF und Speicher je Schritt.
import ArgumentParser
import AudioOut
import Darwin
import Foundation
import Pipeline
import VorleserSpeech
import TextPrep

/// Fragt alle 50 ms `phys_footprint` ab und merkt sich die Spitze je Abschnitt.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak = 0.0
    private var running = true

    init() {
        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let stop = !running
                if !stop { peak = max(peak, footprintGB().now) }
                lock.unlock()
                if stop { return }
                usleep(50_000)
            }
        }
    }

    /// Spitze seit dem letzten Aufruf; setzt zurück auf den aktuellen Wert.
    func takePeak() -> Double {
        lock.lock(); defer { lock.unlock() }
        let p = max(peak, footprintGB().now)
        peak = footprintGB().now
        return p
    }

    func stop() { lock.lock(); running = false; lock.unlock() }
}

struct DesignVoice: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "design-voice",
        abstract: "Stimme beschreiben: zwei Vorschläge als WAV, optional einen behalten und damit vorlesen.")

    @Argument(help: "Beschreibung, z. B. \"ruhige, warme Stimme einer älteren Frau\".")
    var wish: String
    @Option(help: "Lesesprache (de, pt, en, es, fr, it, ru, zh, ja, ko).")
    var lang: String = "de"
    @Option(name: .customLong("wish-lang"), help: "Sprache der Beschreibung (Standard: wie --lang).")
    var wishLang: String?
    @Option(help: "f oder m (optional).")
    var gender: String?
    @Option(help: "young, middle, elderly (optional).")
    var age: String?
    @Option(help: "Herkunft auf Englisch, z. B. \"from Lisbon, Portugal\".")
    var region: String?
    @Flag(help: "Beschreibung unverändert als Anweisung nehmen (keine Umformung, keine Übersetzung).")
    var raw = false
    @Flag(help: "Beschreibung mit dem System-Übersetzer ins Englische bringen (nur wenn das Sprachpaket installiert ist).")
    var translate = false
    @Option(help: "Anzahl Vorschläge.")
    var count: Int = 2
    @Option(help: "Seed (Standard: zufällig).")
    var seed: UInt64?
    @Option(name: .customLong("out"), help: "Ausgabeordner für die WAV-Vorschläge.")
    var out: String = "spike-output/phase4"
    @Option(help: "Dateiname-Anfang der Vorschläge (Standard: design).")
    var prefix: String = "design"
    @Option(help: "Name der Stimme beim Speichern (mit --keep).")
    var name: String?
    @Option(help: "Vorschlag 1 oder 2 als Stimme speichern.")
    var keep: Int?
    @Option(name: .customLong("store-dir"), help: "Ordner für gespeicherte Stimmen (Standard: Application Support/Vorleser/Voices).")
    var storeDir: String?
    @Option(name: .customLong("read-text"), help: "Mit --keep: diesen Text mit der neuen Stimme vorlesen (Base).")
    var readText: String?
    @Option(name: .customLong("read-aloud-dir")) var readAloudDir: String?

    func run() async throws {
        guard let reading = Language(rawValue: lang) else { throw ValidationError("Unbekannte Sprache \(lang)") }
        let wishLanguage = try wishLang.map { code -> Language in
            guard let l = Language(rawValue: code) else { throw ValidationError("Unbekannte Sprache \(code)") }
            return l
        } ?? reading
        if let keep, !(1...max(count, 1)).contains(keep) { throw ValidationError("--keep muss zwischen 1 und \(count) liegen") }
        let refText = try readAloudText(reading, override: readAloudDir)
        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let wishValue = VoiceWish(
            description: wish, descriptionLanguage: wishLanguage, readingLanguage: reading,
            gender: gender.flatMap { $0.lowercased().hasPrefix("f") ? .female : $0.lowercased().hasPrefix("m") ? .male : nil },
            age: age.flatMap { a -> VoiceAgeHint? in
                switch a.lowercased() {
                case "young": .young
                case "middle", "middleaged": .middleAged
                case "elderly", "old": .elderly
                default: nil
                }
            },
            regionHint: region)

        let engine = MLXQwenEngine(bits: .four)
        let designer = VoiceDesigner(engine: engine, translator: translate ? SystemDescriptionTranslator() : nil)
        let sampler = FootprintSampler()
        defer { sampler.stop() }
        err("Footprint vor dem Laden: \(f(footprintGB().now, 2)) GB")

        let prompt: VoicePrompt
        if raw {
            prompt = VoicePrompt(text: wish, source: .raw, wishText: wish)
        } else {
            prompt = await VoicePromptBuilder.build(wishValue, translator: translate ? SystemDescriptionTranslator() : nil)
        }
        print("Anweisung (\(prompt.source.rawValue)): \(prompt.text)")

        let started = Date()
        let result = try await designer.propose(
            prompt: prompt, language: reading, referenceText: refText, count: count,
            seedBase: seed ?? .random(in: .min ... .max),
            onProgress: { p in
                switch p {
                case .translating: break
                case .loading: err("VoiceDesign laden …")
                case let .generating(i, n, a): err("Vorschlag \(i)/\(n), Versuch \(a) …")
                case .unloading: err("VoiceDesign entladen …")
                }
            })
        let designPeak = sampler.takePeak()
        let afterUnload = footprintGB().now
        let loaded = await engine.loadedModel
        let mlx = await engine.memoryReport()
        let relief = malloc_zone_pressure_relief(nil, 0)
        try? await Task.sleep(for: .seconds(1))
        err("Nach Entladen und malloc_zone_pressure_relief (\(relief) B): Footprint \(f(footprintGB().now, 2)) GB")
        print("Nach Design: geladenes Modell = \(loaded.map { "\($0)" } ?? "keins"), Footprint \(f(afterUnload, 2)) GB, MLX aktiv \(f(mlx.activeGB, 2)) GB, MLX Zwischenspeicher \(f(mlx.cacheGB, 2)) GB")
        print("Spitze Footprint während Design \(f(designPeak, 2)) GB, MLX-Spitze \(f(mlx.peakGB, 2)) GB, Gesamtzeit Design \(f(Date().timeIntervalSince(started), 1)) s")

        for p in result.proposals {
            let file = outDir.appending(path: "\(prefix)-\(p.index).wav")
            try ReferenceFiles.writeWAV(p.samples, sampleRate: p.sampleRate, to: file)
            let r = p.report
            print("\(file.lastPathComponent)  Dauer \(f(p.durationSeconds, 1)) s  Zeit \(f(p.wallSeconds, 1)) s  RTF \(f(p.wallSeconds / max(p.durationSeconds, 0.1)))  Versuche \(p.attempts)  RMS \(f(r.rmsDBFS, 1)) dBFS  Spitze \(f(r.peakDBFS, 1)) dBFS  Seed \(p.seed)"
                  + (p.isSuspicious ? "  VERDACHT: \(p.report.issues.map(\.rawValue).joined(separator: ","))" : ""))
        }
        guard let keep else {
            print("Zum Behalten: --keep <n> [--name …]")
            return
        }
        guard let chosen = result.proposals.first(where: { $0.index == keep }) else {
            throw CLIError("Vorschlag \(keep) ist nicht entstanden.")
        }
        let store = RecordedVoiceStore(
            directory: storeDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RecordedVoiceStore.defaultDirectory)
        let voice = try store.saveDesigned(
            samples: chosen.samples, sampleRate: chosen.sampleRate, referenceText: refText,
            name: name ?? String(wish.prefix(30)), language: reading, wish: wish, prompt: prompt.text, seed: chosen.seed)
        print("Gespeichert: \(voice.id) „\(voice.name)“ in \(store.directory.path)")

        guard let readText else { return }
        // Design → Klon: Base lesen lassen. VoiceDesign ist schon entladen, Base ist das einzige Modell.
        _ = sampler.takePeak()
        let tLoad = Date()
        err("Base laden …")
        try await engine.load(.base)
        let loadSeconds = Date().timeIntervalSince(tLoad)
        let afterLoad = footprintGB().now
        let handle = try await engine.prepare(voice)
        let rate = await engine.sampleRate
        let tSpeak = Date()
        var audio: [Float] = []
        for try await piece in await engine.speak(readText, voice: handle, language: reading, seed: chosen.seed &+ 1) {
            audio.append(contentsOf: piece)
        }
        let speakSeconds = Date().timeIntervalSince(tSpeak)
        let basePeak = sampler.takePeak()
        let baseMLX = await engine.memoryReport()
        let (clean, qc) = ChunkQC.analyze(
            samples: audio, sampleRate: rate, characterCount: readText.count,
            config: { var c = ChunkQCConfig(); c.expectedCharsPerSecond = SpeechRate.charsPerSecond(for: reading); return c }())
        let file = outDir.appending(path: "\(prefix)-gelesen.wav")
        try ReferenceFiles.writeWAV(clean, sampleRate: rate, to: file)
        print("\(file.lastPathComponent)  Dauer \(f(qc.trimmedDurationSeconds, 1)) s  Laden \(f(loadSeconds, 1)) s  Sprechen \(f(speakSeconds, 1)) s  RTF \(f(speakSeconds / max(qc.trimmedDurationSeconds, 0.1)))"
              + (qc.isSuspicious ? "  VERDACHT: \(qc.issues.map(\.rawValue).joined(separator: ","))" : ""))
        print("Speicher Base: Footprint nach Laden \(f(afterLoad, 2)) GB, Spitze Footprint \(f(basePeak, 2)) GB, MLX aktiv \(f(baseMLX.activeGB, 2)) GB, MLX-Spitze \(f(baseMLX.peakGB, 2)) GB")
        let nowLoaded = await engine.loadedModel
        print("Geladenes Modell am Ende: \(nowLoaded.map { "\($0)" } ?? "keins")")
        await engine.unload()
    }
}
