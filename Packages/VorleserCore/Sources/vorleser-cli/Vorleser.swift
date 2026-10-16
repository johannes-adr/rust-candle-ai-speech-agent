// vorleser-cli: dieselbe Pipeline wie die App, ohne Oberfläche (PLAN §5, Phase 1).
//
//   vorleser-cli brief.pdf --voice own-1234abcd -o brief.mp3
//   vorleser-cli voices
//   vorleser-cli import-voice <Datei> --lang de --name "Oma" --consent   (Phase 3)
//   vorleser-cli delete-voice <id>
//   vorleser-cli models status|install|manifest   (Phase 5: Modellordner)
import ArgumentParser
import DocumentImport
import Foundation
import Pipeline
import Projects
import VorleserSpeech
import TextPrep

@main
struct Vorleser: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vorleser-cli",
        abstract: "Wandelt PDF oder Text in eine MP3 um (Qwen3-TTS, lokal).",
        subcommands: [Read.self, Voices.self, ImportVoice.self, DeleteVoice.self, CheckReading.self, DesignVoice.self, Models.self],
        defaultSubcommand: Read.self)
}

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "read",
        abstract: "Datei oder Text (\"-\" = Standardeingabe) vorlesen und als MP3 speichern. Ein angefangenes Projekt desselben Dokuments wird fortgesetzt.")

    @Argument(help: "PDF, Text, Word … oder \"-\" für Text von der Standardeingabe.")
    var input: String

    @Option(help: "ID einer eigenen Stimme (siehe vorleser-cli voices; Standard: die älteste Stimme der erkannten Sprache).")
    var voice: String?
    @Option(help: "Tempo 0,8 … 1,2.")
    var tempo: Double = 1.0
    @Option(help: "Sprache erzwingen (de, pt, en, es, fr, it, ru, zh, ja, ko); sonst erkannt.")
    var lang: String?
    @Option(help: "Modell-Quantisierung: 4 oder 8.")
    var bits: Int = 4
    @Option(name: [.short, .customLong("output")], help: "Zieldatei (.mp3).")
    var output: String?
    @Option(help: "Titel (Standard: Dateiname).")
    var title: String?
    @Option(name: .customLong("work-dir"), help: "Projektordner (Standard: Application Support/Vorleser/Projects).")
    var workDir: String?
    @Option(name: .customLong("voices-dir"), help: "Ordner mit eigenen Stimmen (Standard: Application Support/Vorleser/Voices).")
    var voicesDir: String?
    @Flag(help: "Angefangenes Projekt verwerfen und von vorn beginnen.")
    var fresh = false
    @Option(name: .customLong("max-retries"), help: "Wiederholungen bei Verdacht.")
    var maxRetries: Int = 2

    func run() async throws {
        guard let modelBits = ModelBits(rawValue: bits) else { throw ValidationError("--bits muss 4 oder 8 sein") }
        guard (0.8...1.2).contains(tempo) else { throw ValidationError("--tempo muss zwischen 0,8 und 1,2 liegen") }
        let startedAt = Date()

        // Import (hier, damit Sprache und Stimme vor dem Modell feststehen).
        let importer = DocumentImporter()
        let document: TextDocument
        let hash: String, kind: String
        var pageCount: Int?
        var sourceData: Data?
        var sourceExt: String?
        var defaultTitle = "Vorgelesen"
        if input == "-" {
            let text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            document = importer.importText(text)
            hash = SourceHash.hex(of: text); kind = "text"
        } else {
            let url = URL(fileURLWithPath: input)
            let imported = try await importer.importDetailed(at: url, languageHint: lang)
            document = imported.document
            pageCount = imported.pageCount
            let data = try Data(contentsOf: url)
            hash = SourceHash.hex(of: data); kind = url.pathExtension.lowercased()
            sourceData = data; sourceExt = kind
            defaultTitle = url.deletingPathExtension().lastPathComponent
            if let r = imported.report { err("Import: \(imported.pageCount) Seite(n), \(r)") }
        }
        guard !document.blocks.isEmpty else { throw CLIError("Im Dokument wurde kein Text gefunden.") }

        let language: Language
        if let lang {
            guard let l = Language(rawValue: lang) else { throw ValidationError("Unbekannte Sprache \(lang)") }
            language = l
        } else if let d = LanguageDetector().detect(SynthesisJob.plainText(document)) {
            language = d.language
            err("Sprache erkannt: \(d.language.rawValue) (\(f(d.confidence * 100, 0)) %)\(d.isUncertain ? " – unsicher, ggf. --lang setzen" : "")")
        } else {
            throw CLIError("Sprache nicht erkannt, bitte --lang setzen.")
        }

        let voices = locateVoices(voicesDir)
        let chosen: Voice
        if let voice {
            guard let v = voices.voice(id: voice) else {
                throw CLIError("Stimme \(voice) gibt es nicht in \(voices.custom.directory.path). Siehe: vorleser-cli voices")
            }
            if v.language != language { err("Hinweis: Stimme \(v.id) ist \(v.language.rawValue), gelesen wird \(language.rawValue).") }
            chosen = v
        } else if let v = voices.voices(for: language).lazy.compactMap({ voices.voice(id: $0.id) }).first {
            chosen = v
        } else {
            throw CLIError("Für \(language.rawValue) gibt es noch keine eigene Stimme. Siehe: vorleser-cli voices, import-voice, design-voice")
        }

        let store: ProjectStore
        if let workDir {
            let root = URL(fileURLWithPath: workDir, isDirectory: true)
            store = ProjectStore(root: root.appending(path: "Projects"), outputDirectory: root.appending(path: "Out"))
        } else {
            store = ProjectStore()
        }
        let outURL = output.map { URL(fileURLWithPath: $0) }
        let request = SynthesisRequest(
            title: title ?? defaultTitle, source: .document(document, sourceHash: hash, kind: kind),
            language: language, voice: chosen, style: nil, tempo: tempo, outputURL: outURL,
            pageCount: pageCount, sourceData: sourceData, sourceExtension: sourceExt)

        if fresh, let p = await SynthesisJob.existingProject(
            in: store, sourceHash: hash, language: language, voiceID: chosen.id, style: nil) {
            try await store.delete(id: p.id)
            err("Altes Projekt \(p.id.uuidString.prefix(8)) verworfen (--fresh).")
        }

        var config = SynthesisConfig()
        config.maxRetries = maxRetries
        let engine = MLXQwenEngine(bits: modelBits)
        let job = SynthesisJob(engine: engine, store: store, config: config)

        // Strg-C: sauber anhalten, damit „Fortsetzen“ funktioniert.
        signal(SIGINT, SIG_IGN)
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { err("\nAngehalten – beim nächsten Start geht es weiter."); Task { await job.cancel() } }
        sigint.resume()

        let progress = ProgressPrinter()
        var result: SynthesisResult?
        var failure: SynthesisFailure?
        var stopped = false
        for await event in job.start(request) {
            progress.handle(event)
            switch event {
            case let .finished(r): result = r
            case let .failed(f): failure = f
            case .stopped: stopped = true
            default: break
            }
        }
        progress.finishLine()
        if let failure { throw CLIError(failure.message) }
        if stopped { throw ExitCode(130) }
        guard let r = result else { throw CLIError("Kein Ergebnis.") }

        // Zusammenfassung (stdout) mit den Messwerten für docs/phase1.md.
        let total = Date().timeIntervalSince(startedAt)
        let fp = footprintGB()
        let size = (try? FileManager.default.attributesOfItem(atPath: r.fileURL.path)[.size] as? Int) ?? 0
        print("Fertig: \(r.fileURL.path)")
        print("  Dauer \(clock(r.durationSeconds)) (\(f(r.durationSeconds, 1)) s), \(f(Double(size) / 1e6, 1)) MB, Sprache \(r.language.rawValue), Stimme \(chosen.id)")
        print("  Abschnitte \(r.chunkCount) (in diesem Lauf \(r.chunksSynthesized), fortgesetzt: \(r.resumed ? "ja" : "nein"))")
        print("  Gesamtzeit \(clock(total)) (\(f(total, 1)) s), Rechenzeit Sprache \(f(r.computeSeconds, 1)) s für \(f(r.synthesizedAudioSeconds, 1)) s Audio")
        if r.synthesizedAudioSeconds > 0 {
            print("  RTF Sprache \(f(r.computeSeconds / r.synthesizedAudioSeconds)), RTF gesamt \(f(total / r.synthesizedAudioSeconds))")
        }
        print("  Spitze Footprint \(f(fp.peak, 1)) GB, am Ende \(f(fp.now, 1)) GB")
        print("  Wiederholungen \(r.retryCount), Verdachtsmeldungen \(r.suspicious.count), ohne Audio \(r.failedChunks.count)")
        if !r.chapterFiles.isEmpty { print("  Kapitel: \(r.chapterFiles.count) Dateien in \(r.chapterFiles[0].deletingLastPathComponent().path)") }
        if let lufs = r.measuredLUFS { print("  Lautheit vor Angleichung \(f(lufs, 1)) LUFS → −18 LUFS") }

        if !r.suspicious.isEmpty || !r.failedChunks.isEmpty {
            let log = writeProtocol(r)
            print("  Protokoll der Verdachtsfälle: \(log.path)")
        }
    }

    /// Textprotokoll neben der MP3.
    private func writeProtocol(_ r: SynthesisResult) -> URL {
        var lines = ["Verdachtsfälle für \(r.title) (\(r.projectID.uuidString))", ""]
        for s in r.suspicious {
            let ratio = s.durationRatio.map { f($0) } ?? "-"
            lines.append("Abschnitt \(s.chunkIndex), Versuch \(s.attempt + 1): \(s.issues.map(\.rawValue).joined(separator: ", ")), Dauerverhältnis \(ratio)\(s.willRetry ? " → wiederholt" : s.kept ? " → behalten und markiert" : " → verworfen")\(s.message.map { " (\($0))" } ?? "")")
        }
        for i in r.failedChunks { lines.append("Abschnitt \(i): kein Audio, fehlt in der MP3") }
        let url = r.fileURL.deletingPathExtension().appendingPathExtension("protokoll.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

struct Voices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Eigene Stimmen (aufgenommen, importiert, beschrieben).")
    @Option(name: .customLong("voices-dir")) var voicesDir: String?

    func run() throws {
        let custom = locateVoices(voicesDir).custom
        print("Ordner: \(custom.directory.path)")
        for v in custom.list() {
            print("\(v.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(v.name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(v.language.rawValue)  \(v.source), \(String(format: "%.1f", v.durationSeconds)) s")
        }
    }
}
