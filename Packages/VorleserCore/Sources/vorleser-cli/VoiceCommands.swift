// Eigene Stimmen auf der Kommandozeile (Phase 3, für den Helfer und die Messungen):
//   vorleser-cli import-voice aufnahme.m4a --lang de --name "Oma" --consent
//   vorleser-cli delete-voice own-1a2b3c4d
// Die Stimmen landen in `~/Library/Application Support/Vorleser/Voices/` (oder `--custom-dir`,
// `VORLESER_CUSTOM_VOICES_DIR`), nie im Repo.
import ArgumentParser
import Foundation
import TextPrep
import VoiceCapture
import VorleserSpeech

struct ImportVoice: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import-voice",
        abstract: "Eine vorhandene Aufnahme (wav, m4a, mp3, caf) als eigene Stimme übernehmen.",
        discussion: """
        Schneidet 10–15 s aus der Mitte (an Pausen), prüft Pegel und Rauschen und holt das Transkript \
        per SpeechTranscriber (bzw. SFSpeechRecognizer, falls schon erlaubt). Geht das nicht, \
        muss --text angegeben werden (Datei bis 15 s). Einen Modus ohne Text (x-vector only) \
        bietet mlx-audio-swift v0.1.5 nicht an.
        """)

    @Argument(help: "Audiodatei.")
    var file: String
    @Option(help: "Sprache der Aufnahme (de, pt, en, es, fr, it, ru, zh, ja, ko).")
    var lang: String
    @Option(help: "Name der Stimme.")
    var name: String = "Meine Stimme"
    @Option(help: "Wortlaut der Aufnahme, falls die Spracherkennung fehlt (Datei bis 15 s).")
    var text: String?
    @Flag(help: "Ich bestätige: Das ist die Stimme dieser Person, oder sie hat zugestimmt. Pflicht.")
    var consent = false
    @Option(name: .customLong("custom-dir"), help: "Ordner für eigene Stimmen (Standard: Application Support/Vorleser/Voices).")
    var customDir: String?
    @Flag(name: .customLong("install-speech-assets"), help: "Sprachdaten für SpeechTranscriber laden (große Datei, nur auf ausdrücklichen Wunsch).")
    var installAssets = false

    func run() async throws {
        guard let language = Language(rawValue: lang) else { throw ValidationError("Unbekannte Sprache \(lang)") }
        guard consent else {
            throw CLIError("Ohne --consent wird nichts gespeichert (\"Das ist meine Stimme oder ich habe die Erlaubnis\").")
        }
        let url = URL(fileURLWithPath: file)
        guard FileManager.default.fileExists(atPath: url.path) else { throw CLIError("Datei nicht gefunden: \(file)") }
        let store = RecordedVoiceStore(directory: customDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RecordedVoiceStore.defaultDirectory)

        let transcriber = SystemTranscriber()
        if installAssets {
            err("Lade Sprachdaten für \(language.rawValue) …")
            let ok = try await transcriber.installAssets(for: language)
            err(ok ? "Sprachdaten installiert." : "Für \(language.rawValue) gibt es keine installierbaren Sprachdaten.")
        }
        err("Spracherkennung: \(describe(await transcriber.status(for: language)))")

        let ref: ImportedReference
        do {
            ref = try await VoiceImporter.prepare(fileURL: url, language: language, providedText: text, transcriber: transcriber)
        } catch let e as VoiceImportError {
            throw CLIError(e.description)
        }
        let voice = try store.save(
            samples: ref.samples, sampleRate: ref.sampleRate, transcript: ref.transcript, name: name, language: language,
            consent: consent, source: "import", transcriptSource: ref.transcriptSource.rawValue)
        let r = ref.report
        print("Stimme gespeichert: \(voice.id) (\(voice.name), \(language.rawValue))")
        print("  Ordner \(store.directory.path)")
        print("  Quelle \(f(ref.sourceSeconds, 1)) s → Referenz \(f(Double(ref.samples.count) / ref.sampleRate, 1)) s bei \(Int(ref.sampleRate)) Hz\(ref.cutAtPauses ? "" : " (kein Schnitt an Pause möglich)")")
        print("  Transkript (\(ref.transcriptSource.rawValue)\(ref.recognitionEngine.map { ", " + $0 } ?? "")): \(ref.transcript)")
        print("  Pegel: Sprache \(f(r.speechLevelDBFS, 1)) dBFS, Rauschen \(f(r.noiseFloorDBFS, 1)) dBFS, Abstand \(f(r.snrDB, 1)) dB, Spitze \(f(r.peakDBFS, 1)) dBFS, angehoben um \(f(r.appliedGainDB, 1)) dB")
        if !r.issues.isEmpty { print("  Hinweise: \(r.issues.map(\.rawValue).joined(separator: ", "))") }
    }

    private func describe(_ s: TranscriberStatus) -> String {
        switch s {
        case .speechTranscriberInstalled(let l): "SpeechTranscriber (\(l)) installiert"
        case .speechTranscriberNeedsDownload(let l): "SpeechTranscriber (\(l)) unterstützt, Sprachdaten nicht installiert"
        case .legacyOnDevice(let l): "nur SFSpeechRecognizer (\(l)), braucht Erlaubnis der App"
        case .unsupported: "nicht verfügbar"
        }
    }
}

struct DeleteVoice: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete-voice", abstract: "Eine eigene Stimme endgültig löschen.")
    @Argument var id: String
    @Option(name: .customLong("custom-dir")) var customDir: String?

    func run() throws {
        let store = RecordedVoiceStore(directory: customDir.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? RecordedVoiceStore.defaultDirectory)
        try store.delete(id: id)
        print("Gelöscht: \(id)")
    }
}

/// Prüft eine Sprachausgabe objektiv: Pegel/NaN und Spracherkennung zurück in Text (WER/CER).
struct CheckReading: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check-reading",
        abstract: "Audiodatei erkennen lassen und mit dem erwarteten Text vergleichen (WER/CER, Pegel, NaN).")

    @Argument(help: "Audiodatei (mp3, wav, caf, m4a).")
    var file: String
    @Option(help: "Sprache (de, pt, …).")
    var lang: String
    @Option(help: "Erwarteter Text.")
    var text: String

    func run() async throws {
        guard let language = Language(rawValue: lang) else { throw ValidationError("Unbekannte Sprache \(lang)") }
        let url = URL(fileURLWithPath: file)
        let (samples, rate) = try AudioFiles.readMono(url: url)
        let level = LevelMeter.measure(samples)
        let nonFinite = samples.reduce(0) { $0 + ($1.isFinite ? 0 : 1) }
        print("Dauer \(f(Double(samples.count) / rate, 1)) s bei \(Int(rate)) Hz, RMS \(f(level.rmsDBFS, 1)) dBFS, Spitze \(f(level.peakDBFS, 1)) dBFS, NaN/Inf: \(nonFinite)")
        switch await SystemTranscriber().transcribe(fileURL: url, language: language) {
        case .unavailable(let why):
            print("Spracherkennung nicht möglich: \(why.rawValue)")
        case .text(let heard, let engine):
            let rate = TranscriptScoring.errorRate(reference: text, hypothesis: heard, language: language)
            print("Erkannt (\(engine)): \(heard)")
            print("\(language.isCJK ? "CER" : "WER") \(f(rate * 100, 1)) %")
        }
    }
}
