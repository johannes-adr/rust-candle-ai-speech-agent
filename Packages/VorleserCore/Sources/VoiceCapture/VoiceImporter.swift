// Audio-Import für den Helfer: vorhandene Aufnahme (wav/m4a/mp3/caf) → Referenz von 10–15 s
// aus der Mitte, geschnitten an Pausen, mit Transkript.
//
// x-vector-only-Modus: `mlx-audio-swift` v0.1.5 bietet ihn öffentlich nicht an
// (`prepareReferenceConditioning(refAudio:refText:language:)` verlangt immer den Text). Deshalb
// gibt es keinen Import ohne Transkript: Entweder erkennt SpeechTranscriber/SFSpeechRecognizer
// den Text, oder der Helfer gibt ihn an (`providedText`, dann nur für Dateien bis 15 s, weil
// sonst Text und Ausschnitt nicht zusammenpassen).
import AudioOut
import Foundation
import TextPrep

public enum ReferenceTrimmer {
    public struct Selection: Sendable, Equatable {
        public var range: Range<Int>
        public var seconds: Double
        /// `false`, wenn kein Schnitt an einer Pause möglich war.
        public var cutAtPauses: Bool
    }

    /// Wählt ein Fenster von `minSeconds … maxSeconds` möglichst nahe der Mitte, dessen Ränder
    /// in Pausen liegen. Ist die Aufnahme kürzer als `maxSeconds`, bleibt sie ganz.
    public static func select(
        samples: [Float], sampleRate: Double, minSeconds: Double = 10, maxSeconds: Double = 15
    ) -> Selection {
        let total = samples.count
        let totalSeconds = Double(total) / sampleRate
        if totalSeconds <= maxSeconds { return Selection(range: 0..<total, seconds: totalSeconds, cutAtPauses: true) }

        // Schnittpunkte = Mitten von Pausen (≥ 0,25 s unter Schwelle).
        let frame = max(1, Int(sampleRate * 0.025))
        let levels = LevelMeter.frameLevels(samples, sampleRate: sampleRate, frameSeconds: 0.025)
        let noise = RecordingAnalyzer.noiseFloor(levels)
        let threshold = min(-35, max(-60, noise + 10))
        var cuts: [Int] = []
        var runStart: Int?
        for (i, l) in levels.enumerated() {
            if l < threshold { if runStart == nil { runStart = i } }
            else if let s = runStart {
                if i - s >= 10 { cuts.append(((s + i) / 2) * frame) }
                runStart = nil
            }
        }
        let center = total / 2
        let lo = Int(minSeconds * sampleRate), hi = Int(maxSeconds * sampleRate)
        let ideal = Int(12.5 * sampleRate)
        var best: (Int, Int, Double)?
        for a in cuts {
            for b in cuts where b > a && (b - a) >= lo && (b - a) <= hi {
                // Nahe der Mitte und nahe 12,5 s.
                let mid = (a + b) / 2
                let score = Double(abs(mid - center)) / sampleRate + 0.5 * Double(abs((b - a) - ideal)) / sampleRate
                if best == nil || score < best!.2 { best = (a, b, score) }
            }
        }
        if let (a, b, _) = best {
            return Selection(range: a..<b, seconds: Double(b - a) / sampleRate, cutAtPauses: true)
        }
        // Keine passenden Pausen: 12 s um die Mitte, Ränder auf die leiseste Stelle ±0,5 s ziehen.
        let want = Int(12 * sampleRate)
        var a = max(0, center - want / 2)
        var b = min(total, a + want)
        a = quietest(levels, near: a, frame: frame, radius: Int(0.5 * sampleRate), total: total)
        b = quietest(levels, near: b, frame: frame, radius: Int(0.5 * sampleRate), total: total)
        if b - a < lo { a = max(0, center - want / 2); b = min(total, a + want) }
        return Selection(range: a..<b, seconds: Double(b - a) / sampleRate, cutAtPauses: false)
    }

    private static func quietest(_ levels: [Double], near position: Int, frame: Int, radius: Int, total: Int) -> Int {
        let from = max(0, (position - radius) / frame), to = min(levels.count - 1, (position + radius) / frame)
        guard from <= to else { return min(max(0, position), total) }
        var bestIndex = from
        for i in from...to where levels[i] < levels[bestIndex] { bestIndex = i }
        return min(bestIndex * frame, total)
    }
}

public struct ImportedReference: Sendable, Equatable {
    public enum TranscriptSource: String, Sendable, Codable { case provided, recognized }
    /// Bereinigt (Rand-Stille ab, Pegel angeglichen), Rate der Datei.
    public var samples: [Float]
    public var sampleRate: Double
    public var transcript: String
    public var transcriptSource: TranscriptSource
    public var recognitionEngine: String?
    public var report: RecordingReport
    public var sourceSeconds: Double
    public var cutAtPauses: Bool
}

public enum VoiceImportError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable(String)
    /// Keine Spracherkennung für diese Sprache möglich und kein Text angegeben.
    case transcriptNeeded(TranscriptionUnavailable)
    /// Text angegeben, aber die Datei ist länger als 15 s: Der Ausschnitt passt nicht zum Text.
    case providedTextNeedsShortFile(seconds: Double)
    case recordingUnusable([RecordingIssue])
    case emptyTranscript

    public var description: String {
        switch self {
        case .unreadable(let s): s
        case .transcriptNeeded(let why):
            "Der Text der Aufnahme konnte nicht erkannt werden (\(why.rawValue)). Bitte mit --text angeben (Datei bis 15 s) "
                + "oder die Sprachdaten installieren (--install-speech-assets). Ohne Text lässt sich keine Stimme übernehmen."
        case .providedTextNeedsShortFile(let s):
            "Die Datei ist \(Int(s.rounded())) s lang. Ein angegebener Text passt nur zu einer Datei bis 15 s. Bitte kürzen oder Spracherkennung nutzen."
        case .recordingUnusable(let issues): "Die Aufnahme ist nicht brauchbar: \(issues.map(\.rawValue).joined(separator: ", "))"
        case .emptyTranscript: "Es wurde kein Text erkannt."
        }
    }
}

public enum VoiceImporter {
    public static func prepare(
        fileURL: URL, language: Language, providedText: String? = nil,
        transcriber: any SpeechTranscribing = SystemTranscriber(),
        config: RecordingCheckConfig = RecordingCheckConfig()
    ) async throws -> ImportedReference {
        let raw: (samples: [Float], sampleRate: Double)
        do { raw = try AudioFiles.readMono(url: fileURL) } catch { throw VoiceImportError.unreadable("\(error)") }

        // 1. Ränder trimmen, dann 10–15 s aus der Mitte wählen.
        let rawSeconds = Double(raw.samples.count) / raw.sampleRate
        let trimmedAll = RecordingAnalyzer.analyze(samples: raw.samples, sampleRate: raw.sampleRate, config: config).samples
        guard !trimmedAll.isEmpty else { throw VoiceImportError.recordingUnusable([.silent]) }
        let provided = providedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasProvided = !(provided ?? "").isEmpty
        let maxWindow = 15.0
        if hasProvided, Double(trimmedAll.count) / raw.sampleRate > maxWindow + 0.5 {
            throw VoiceImportError.providedTextNeedsShortFile(seconds: Double(trimmedAll.count) / raw.sampleRate)
        }
        let sel = ReferenceTrimmer.select(samples: trimmedAll, sampleRate: raw.sampleRate, maxSeconds: maxWindow)
        let window = Array(trimmedAll[sel.range])

        // 2. Prüfen (Pegel, Rauschen); zu kurz/Stille bricht ab, der Rest ist Hinweis.
        var checkConfig = config
        checkConfig.maxSeconds = 20
        let (clean, report) = RecordingAnalyzer.analyze(samples: window, sampleRate: raw.sampleRate, config: checkConfig)
        if report.hasBlockingIssue { throw VoiceImportError.recordingUnusable(report.issues.filter(\.isBlocking)) }

        // 3. Transkript: angegeben oder erkannt (nur für den gewählten Ausschnitt).
        if hasProvided, let provided {
            return ImportedReference(
                samples: clean, sampleRate: raw.sampleRate, transcript: provided, transcriptSource: .provided,
                recognitionEngine: nil, report: report, sourceSeconds: rawSeconds, cutAtPauses: sel.cutAtPauses)
        }
        let tmp = FileManager.default.temporaryDirectory.appending(path: "vorleser-import-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try AudioFiles.writeWAV(clean, sampleRate: raw.sampleRate, to: tmp)
        switch await transcriber.transcribe(fileURL: tmp, language: language) {
        case .unavailable(let why):
            throw VoiceImportError.transcriptNeeded(why)
        case .text(let text, let engine):
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { throw VoiceImportError.emptyTranscript }
            return ImportedReference(
                samples: clean, sampleRate: raw.sampleRate, transcript: t, transcriptSource: .recognized,
                recognitionEngine: engine, report: report, sourceSeconds: rawSeconds, cutAtPauses: sel.cutAtPauses)
        }
    }
}
