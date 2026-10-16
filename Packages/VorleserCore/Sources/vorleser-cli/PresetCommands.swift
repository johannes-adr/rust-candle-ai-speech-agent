// design-presets und adopt-presets (PLAN §5, Phase 1): Stimmen aus Beschreibungen erzeugen.
import ArgumentParser
import AudioOut
import CryptoKit
import Foundation
import Pipeline
import VorleserSpeech
import TextPrep

/// Fester Lesetext je Sprache (ca. 10–12 s), neben `Voices` unter `Resources/ReadAloud`.
private func readAloudText(_ language: Language, voices: VoiceStore, override: String?) throws -> String {
    let dir = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? voices.directory.deletingLastPathComponent().appending(path: "ReadAloud", directoryHint: .isDirectory)
    let url = dir.appending(path: "\(language.rawValue).txt")
    guard let s = try? String(contentsOf: url, encoding: .utf8) else { throw CLIError("Lesetext fehlt: \(url.path)") }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Stabiler Seed je Stimme, Stil und Kandidat.
private func candidateSeed(voice: String, style: String, candidate: Int) -> UInt64 {
    let digest = SHA256.hash(data: Data("\(voice)|\(style)|\(candidate)".utf8))
    return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
}

struct DesignPresets: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "design-presets",
        abstract: "Erzeugt je Stimme und Stil mehrere Kandidaten mit VoiceDesign (zum Anhören im Finder).")

    @Argument(help: "Ausgabeordner für die Kandidaten (<id>-<stil>-<n>.wav).")
    var folder: String
    @Option(help: "Nur diese Sprachen, kommagetrennt (z. B. de,pt).")
    var lang: String?
    @Option(help: "Nur diese Stimme (ID).")
    var voice: String?
    @Option(help: "Nur diese Stile, kommagetrennt (Standard: alle).")
    var style: String?
    @Option(help: "Kandidaten je Stimme und Stil.")
    var candidates: Int = 3
    @Option(name: .customLong("voices-dir")) var voicesDir: String?
    @Option(name: .customLong("read-aloud-dir")) var readAloudDir: String?

    func run() async throws {
        let store = try locateVoices(voicesDir)
        var langs = Language.allCases
        if let lang {
            langs = try lang.split(separator: ",").map { s -> Language in
                guard let l = Language(rawValue: String(s)) else { throw ValidationError("Unbekannte Sprache \(s)") }
                return l
            }
        }
        let styles = style.map { $0.split(separator: ",").map { normalizedStyle(String($0)) } } ?? store.styles
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let jobs = store.allPresets.filter { langs.contains($0.language) && (voice == nil || $0.id == voice) }
        guard !jobs.isEmpty else { throw CLIError("Keine passende Stimme.") }
        let engine = MLXQwenEngine(bits: .four)
        err("VoiceDesign laden …")
        try await engine.load(.voiceDesign)
        let rate = await engine.sampleRate
        var made = 0
        let started = Date()

        for preset in jobs {
            let text = try readAloudText(preset.language, voices: store, override: readAloudDir)
            guard let base = preset.design else { throw CLIError("\(preset.id): kein \"design\" in presets.json") }
            for st in styles {
                guard let styleText = store.styleDesign[st] else { throw CLIError("Stil \(st) unbekannt") }
                let description = base + " " + styleText
                try text.write(to: out.appending(path: "\(preset.id)-\(st).txt"), atomically: true, encoding: .utf8)
                for k in 1...candidates {
                    let seed = candidateSeed(voice: preset.id, style: st, candidate: k)
                    let t0 = Date()
                    let raw = try await engine.design(description: description, sampleText: text, language: preset.language, seed: seed)
                    let wall = Date().timeIntervalSince(t0)
                    let (samples, qc) = ChunkQC.analyze(
                        samples: raw, sampleRate: rate, characterCount: text.count,
                        config: { var c = ChunkQCConfig(); c.expectedCharsPerSecond = SpeechRate.charsPerSecond(for: preset.language); return c }())
                    let file = out.appending(path: "\(preset.id)-\(st)-\(k).wav")
                    try ReferenceFiles.writeWAV(samples, sampleRate: rate, to: file)
                    made += 1
                    let fp = footprintGB()
                    print("\(file.lastPathComponent)  \(f(qc.trimmedDurationSeconds, 1)) s  RTF \(f(wall / max(qc.trimmedDurationSeconds, 0.1)))  Spitze \(f(fp.peak, 1)) GB"
                          + (qc.isSuspicious ? "  VERDACHT: \(qc.issues.map(\.rawValue).joined(separator: ","))" : ""))
                }
            }
        }
        await engine.unload()
        print("\(made) Kandidaten in \(out.path) (\(f(Date().timeIntervalSince(started), 0)) s). Anhören (Leertaste im Finder), schlechte löschen, dann: vorleser-cli adopt-presets \(folder)")
    }
}

struct AdoptPresets: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "adopt-presets",
        abstract: "Übernimmt je Stimme und Stil den ersten verbliebenen Kandidaten nach Resources/Voices (ALAC + .txt).")

    @Argument(help: "Ordner mit den Kandidaten von design-presets.")
    var folder: String
    @Option(name: .customLong("voices-dir")) var voicesDir: String?
    @Option(name: .customLong("read-aloud-dir")) var readAloudDir: String?
    @Flag(help: "Nur anzeigen, nichts schreiben.")
    var dryRun = false

    func run() throws {
        let store = try locateVoices(voicesDir)
        let dir = URL(fileURLWithPath: folder, isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // <id>-<stil>-<n>.wav → [(id, stil)] → kleinstes n
        var first: [String: (voice: String, style: String, n: Int, file: URL)] = [:]
        for name in names where name.hasSuffix(".wav") {
            let stem = String(name.dropLast(4))
            guard let dash = stem.lastIndex(of: "-"), let n = Int(stem[stem.index(after: dash)...]) else { continue }
            let head = String(stem[..<dash])
            guard let st = store.styles.first(where: { head.hasSuffix("-" + $0) }) else { continue }
            let voiceID = String(head.dropLast(st.count + 1))
            guard store.preset(id: voiceID) != nil else { err("Übersprungen (unbekannte Stimme): \(name)"); continue }
            let key = "\(voiceID)-\(st)"
            if first[key] == nil || n < first[key]!.n { first[key] = (voiceID, st, n, dir.appending(path: name)) }
        }
        guard !first.isEmpty else { throw CLIError("Keine Kandidaten (*.wav) in \(folder).") }

        for key in first.keys.sorted() {
            let c = first[key]!
            let preset = store.preset(id: c.voice)!
            let text: String
            let textFile = dir.appending(path: "\(key).txt")
            if let t = try? String(contentsOf: textFile, encoding: .utf8) { text = t.trimmingCharacters(in: .whitespacesAndNewlines) }
            else { text = try readAloudText(preset.language, voices: store, override: readAloudDir) }
            let caf = store.directory.appending(path: preset.references[c.style] ?? "\(key).caf")
            let txt = caf.deletingPathExtension().appendingPathExtension("txt")
            print("\(c.file.lastPathComponent) → \(caf.lastPathComponent)")
            if dryRun { continue }
            let (samples, rate) = try AudioResampler.readMono(url: c.file)
            try ReferenceFiles.writeALAC(samples, sampleRate: rate, to: caf)
            try text.write(to: txt, atomically: true, encoding: .utf8)
        }
        print(dryRun ? "Trockenlauf." : "\(first.count) Referenzen nach \(store.directory.path) übernommen.")
    }
}
