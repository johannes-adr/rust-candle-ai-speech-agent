// Fassade: baut aus einer Folge von Abschnitten die fertige(n) MP3(s).
//
// Ablauf (zwei Durchgänge, damit der Speicher flach bleibt; Abschnitte kommen
// bei Bedarf aus `chunks/*.caf`):
//   Durchgang 1: je Abschnitt aufbereiten (bereinigen, Tempo, 44,1 kHz, Fades),
//                Pausen einfügen und die Lautheit des Ganzen messen.
//   Durchgang 2: erneut aufbereiten, globale Verstärkung anwenden, Spitzen
//                begrenzen, in die MP3(s) schreiben.
import Foundation

/// Ein Abschnitt als Eingabe für den Export.
public struct ExportChunk: Sendable {
    public enum Source: Sendable {
        case samples([Float], sampleRate: Double)
        case caf(URL)
    }

    public var source: Source
    /// Pause, die *nach* diesem Abschnitt folgt (beim letzten Abschnitt ohne Wirkung).
    public var pauseAfter: PauseKind
    /// Kapitelnummer ab 1. Abschnitte eines Kapitels müssen aufeinander folgen.
    public var chapter: Int

    public init(source: Source, pauseAfter: PauseKind = .sentence, chapter: Int = 1) {
        self.source = source
        self.pauseAfter = pauseAfter
        self.chapter = chapter
    }

    public init(samples: [Float], sampleRate: Double, pauseAfter: PauseKind = .sentence, chapter: Int = 1) {
        self.init(source: .samples(samples, sampleRate: sampleRate), pauseAfter: pauseAfter, chapter: chapter)
    }

    public init(cafURL: URL, pauseAfter: PauseKind = .sentence, chapter: Int = 1) {
        self.init(source: .caf(cafURL), pauseAfter: pauseAfter, chapter: chapter)
    }
}

public struct ExportOptions: Sendable {
    /// 0,8 … 1,2; Tonhöhe bleibt.
    public var tempo: Double = 1.0
    public var targetLUFS: Double = -18
    public var peakCeilingDBFS: Double = -1.5
    public var pauses = PauseDurations()
    public var fadeSeconds: Double = 0.010
    public var mp3 = MP3Settings()
    /// Stille-Schwelle für das Abschneiden an den Abschnittsrändern.
    public var trimSilenceDBFS: Double = -55

    // Tags
    public var documentTitle: String = ""
    public var voiceName: String = ""
    public var comment: String = "Mit KI vorgelesen"
    /// Titel je Kapitelnummer; fehlt einer, heißt es `"<chapterWord> <n>"`.
    public var chapterTitles: [Int: String] = [:]
    public var chapterWord: String = "Kapitel"
    /// Wenn gesetzt und es mehr als ein Kapitel gibt: Ordner mit `01 Kapitel 1.mp3` …
    public var chapterDirectory: URL?

    public init() {}
}

public struct ExportResult: Sendable, Equatable {
    public var mainFile: URL
    public var chapterFiles: [URL]
    public var durationSeconds: Double
    /// Gemessene Lautheit vor der Anpassung (`nil` = stumm).
    public var measuredLUFS: Double?
    public var appliedGainDB: Double
    public var peakDBFS: Double
}

public enum AudioExporter {
    /// Baut die MP3(s). `progress` meldet 0…1 über beide Durchgänge.
    public static func export(
        chunks: [ExportChunk],
        to mainFile: URL,
        options: ExportOptions = ExportOptions(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) throws -> ExportResult {
        guard !chunks.isEmpty else { throw AudioOutError.invalidParameter("Keine Abschnitte") }
        guard TempoShifter.allowedRange.contains(options.tempo) else {
            throw AudioOutError.invalidParameter("Tempo \(options.tempo)")
        }
        let rate = Double(options.mp3.sampleRate)

        // Durchgang 1: Lautheit messen.
        var meter = LoudnessMeter(sampleRate: rate)
        let total = Double(chunks.count) * 2
        for (i, chunk) in chunks.enumerated() {
            let audio = try prepare(chunk, options: options)
            meter.process(audio)
            if i < chunks.count - 1 { meter.process(silence(chunk.pauseAfter, options: options)) }
            progress?(Double(i + 1) / total)
        }
        let measured = meter.integratedLUFS
        let gainDB = Loudness.gainDB(measuredLUFS: measured, targetLUFS: options.targetLUFS)
        let gain = DB.toLinear(gainDB)

        // Durchgang 2: schreiben.
        let chapters = Array(Set(chunks.map(\.chapter))).sorted()
        let writeChapters = options.chapterDirectory != nil && chapters.count > 1
        let main = try MP3Writer(
            destination: mainFile,
            tags: MP3Tags(
                title: options.documentTitle, artist: options.voiceName,
                album: options.documentTitle, comment: options.comment),
            settings: options.mp3)
        var chapterWriter: MP3Writer?
        var currentChapter: Int?
        var chapterFiles: [URL] = []
        var peak: Float = 0
        do {
            for (i, chunk) in chunks.enumerated() {
                if writeChapters, currentChapter != chunk.chapter {
                    if let w = chapterWriter { chapterFiles.append(try w.finalize()) }
                    currentChapter = chunk.chapter
                    let title = chapterTitle(chunk.chapter, options: options)
                    let idx = (chapters.firstIndex(of: chunk.chapter) ?? 0) + 1
                    chapterWriter = try MP3Writer(
                        destination: options.chapterDirectory!.appendingPathComponent(
                            String(format: "%02d ", chunk.chapter) + sanitizedFileName(title) + ".mp3"),
                        tags: MP3Tags(
                            title: title, artist: options.voiceName, album: options.documentTitle,
                            track: idx, trackCount: chapters.count, comment: options.comment),
                        settings: options.mp3)
                }
                var audio = try prepare(chunk, options: options)
                if gain != 1 { for k in audio.indices { audio[k] *= gain } }
                PeakLimiter.limit(&audio, sampleRate: rate, ceilingDBFS: options.peakCeilingDBFS)
                peak = max(peak, PeakLimiter.samplePeak(audio))
                try main.append(audio)
                try chapterWriter?.append(audio)

                let isLast = i == chunks.count - 1
                if !isLast {
                    let pause = silence(chunk.pauseAfter, options: options)
                    try main.append(pause)
                    // Kapitelpause gehört nicht ans Ende der Kapiteldatei.
                    if chunks[i + 1].chapter == chunk.chapter { try chapterWriter?.append(pause) }
                }
                progress?(Double(chunks.count + i + 1) / total)
            }
            if let w = chapterWriter { chapterFiles.append(try w.finalize()) }
            try main.finalize()
        } catch {
            main.abort()
            chapterWriter?.abort()
            throw error
        }
        progress?(1)
        return ExportResult(
            mainFile: mainFile, chapterFiles: chapterFiles,
            durationSeconds: Double(main.samplesWritten) / rate,
            measuredLUFS: measured, appliedGainDB: gainDB,
            peakDBFS: DB.fromLinear(Double(peak)))
    }

    // MARK: - Bausteine

    /// Lädt einen Abschnitt und bringt ihn auf Ausgabeformat: bereinigen, Stille kappen,
    /// Tempo, 44,1 kHz, Fades. Ohne Pegelanpassung.
    static func prepare(_ chunk: ExportChunk, options: ExportOptions) throws -> [Float] {
        let (raw, inRate): ([Float], Double)
        switch chunk.source {
        case .samples(let s, let r): (raw, inRate) = (s, r)
        case .caf(let url): (raw, inRate) = try CAFFile.read(from: url)
        }
        // NaN/Inf → 0 und Ränder trimmen.
        var cfg = ChunkQCConfig()
        cfg.silenceThresholdDBFS = options.trimSilenceDBFS
        var audio = ChunkQC.analyze(samples: raw, sampleRate: inRate, config: cfg).samples
        if audio.isEmpty { return [] }
        audio = try TempoShifter.apply(audio, sampleRate: inRate, tempo: options.tempo)
        audio = try Resampler.resample(audio, from: inRate, to: Double(options.mp3.sampleRate))
        Fade.apply(&audio, sampleRate: Double(options.mp3.sampleRate), seconds: options.fadeSeconds)
        return audio
    }

    static func silence(_ kind: PauseKind, options: ExportOptions) -> [Float] {
        let n = Int((options.pauses.seconds(for: kind) * Double(options.mp3.sampleRate)).rounded())
        return [Float](repeating: 0, count: max(n, 0))
    }

    static func chapterTitle(_ n: Int, options: ExportOptions) -> String {
        options.chapterTitles[n] ?? "\(options.chapterWord) \(n)"
    }

    /// Entfernt Zeichen, die in Dateinamen Probleme machen.
    public static func sanitizedFileName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/:\\?*\"<>|").union(.controlCharacters)
        let cleaned = s.unicodeScalars.map { bad.contains($0) ? "_" : String($0) }.joined()
            .trimmingCharacters(in: .whitespaces)
        return String(cleaned.prefix(80)).isEmpty ? "Kapitel" : String(cleaned.prefix(80))
    }
}
