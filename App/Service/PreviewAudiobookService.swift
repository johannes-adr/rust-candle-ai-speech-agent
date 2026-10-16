// ATTRAPPE – keine Sprachausgabe!
//
// Diese Umsetzung von AudiobookService simuliert nur die Arbeit, damit der ganze Ablauf
// ① → ④ schon klickbar ist. Sie benutzt aber die echten Bausteine des Packages:
// TextPrep (Abschnitte), Projects (ProjectStore, Fortsetzen, Restzeit) und AudioOut
// (CAF-Abschnitte, Lautheit, LAME-MP3). Statt gesprochener Sprache entsteht ein leiser
// Klang pro Abschnitt. Wird ersetzt, sobald die Sprach-Pipeline im Package steht.
import AVFoundation
import AudioOut
import Foundation
import Projects
import TextPrep

enum PreviewError: Error { case nothingToRead }

actor PreviewAudiobookService: AudiobookService {
    private let store: ProjectStore
    private let library: VoiceLibrary
    /// Gesamtdauer der Simulation in Sekunden (Entwicklung: VORLESER_PREVIEW_SECONDS).
    private let simulatedSeconds: Double

    private var stopRequested = false
    private var paused = false
    private var currentProjectID: UUID?
    private var player: AVAudioPlayer?

    init(store: ProjectStore, library: VoiceLibrary, simulatedSeconds: Double = 5) {
        self.store = store
        self.library = library
        self.simulatedSeconds = simulatedSeconds
    }

    // MARK: Erzeugen

    nonisolated func start(_ job: AudiobookJob) -> AsyncStream<AudiobookEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudiobookEvent.self)
        Task { await self.run(job, continuation) }
        return stream
    }

    func pause() { paused = true }
    func resume() { paused = false }
    func cancel() { stopRequested = true; paused = false }

    private func run(_ job: AudiobookJob, _ out: AsyncStream<AudiobookEvent>.Continuation) async {
        stopRequested = false
        paused = false
        out.yield(.preparing)
        do {
            var project: Project
            if let id = job.resumeProjectID {
                project = try await store.load(id: id)
            } else {
                let chunks = TextPreparer.prepare(document: job.document, language: job.language)
                guard !chunks.isEmpty else {
                    out.yield(.failed(reasonKey: "problem.noText"))
                    out.finish()
                    return
                }
                project = try await store.create(
                    title: job.title, sourceHash: job.sourceHash, sourceKind: job.sourceKind,
                    sourceData: job.sourceData, sourceExtension: job.sourceExtension,
                    language: job.language, voiceID: job.voiceID, style: job.style, tempo: job.tempo,
                    chunks: chunks)
            }
            currentProjectID = project.id
            try await store.setState(.synthesizing, id: project.id)

            let pending = project.chunks.filter { $0.status == .pending }
            let delay = min(0.25, simulatedSeconds / Double(max(pending.count, 1)))
            let chunkStore = store.chunkStore(for: project.id)
            for pc in pending {
                while paused && !stopRequested { try await Task.sleep(for: .milliseconds(100)) }
                if stopRequested || Task.isCancelled {
                    out.yield(.stopped)
                    out.finish()
                    return
                }
                try await Task.sleep(for: .seconds(delay))
                let tone = Self.tone(index: pc.chunk.index)
                try chunkStore.write(tone, sampleRate: Self.rate, index: pc.chunk.index)
                let updated = try await store.markChunkDone(
                    id: project.id, chunkIndex: pc.chunk.index, duration: Double(tone.count) / Self.rate,
                    computeSeconds: delay)
                let est = ETAEstimator().estimate(for: updated.chunks)
                out.yield(.progress(AudiobookProgress(
                    fraction: est.progress, currentPage: est.currentPage, totalPages: est.totalPages,
                    remainingSeconds: est.remainingSeconds)))
            }

            out.yield(.finishing)
            try await store.setState(.exporting, id: project.id)
            let final = try await store.load(id: project.id)
            let result = try export(final, voiceName: job.voiceName)
            try await store.setState(.finished, id: project.id)
            out.yield(.finished(result))
        } catch {
            out.yield(.failed(reasonKey: "problem.generic"))
        }
        out.finish()
    }

    private func export(_ project: Project, voiceName: String) throws -> AudiobookResult {
        let chunkStore = store.chunkStore(for: project.id)
        let exportChunks = project.chunks.map { pc in
            ExportChunk(
                cafURL: chunkStore.url(forIndex: pc.chunk.index),
                pauseAfter: Self.pause(after: pc.chunk.kind), chapter: max(1, pc.chunk.chapter))
        }
        let target = store.outputURL(title: project.title)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var options = ExportOptions()
        options.tempo = project.tempo
        options.documentTitle = project.title
        options.voiceName = voiceName
        let r = try AudioExporter.export(chunks: exportChunks, to: target, options: options)
        return AudiobookResult(
            projectID: project.id, title: project.title, fileURL: r.mainFile, durationSeconds: r.durationSeconds)
    }

    private static func pause(after kind: ChunkKind) -> PauseKind {
        switch kind {
        case .sentence: .sentence
        case .paragraphEnd: .paragraph
        case .heading: .chapter
        }
    }

    // MARK: Klänge (statt Sprache)

    private static let rate = 24_000.0

    /// 0,5 s leiser Sinuston, Tonhöhe wechselt je Abschnitt (Pentatonik).
    static func tone(index: Int) -> [Float] {
        let steps = [0, 2, 4, 7, 9]
        let semitone = steps[index % steps.count] + 12 * ((index / steps.count) % 2)
        let freq = 220.0 * pow(2.0, Double(semitone) / 12)
        let n = Int(rate * 0.5)
        let fade = Int(rate * 0.04)
        return (0..<n).map { i in
            let env = min(1, Double(i) / Double(fade), Double(n - i) / Double(fade))
            return Float(0.2 * env * sin(2 * .pi * freq * Double(i) / rate))
        }
    }

    // MARK: Proben

    nonisolated func hasSample(voiceID: String, style: String) -> Bool {
        library.referenceURL(voiceID: voiceID, style: style) != nil
    }

    func playSample(voiceID: String, style: String) throws {
        guard let url = library.referenceURL(voiceID: voiceID, style: style) else { throw PreviewError.nothingToRead }
        try play(url)
    }

    func stopSample() { player?.stop() }

    func listenAhead() throws {
        guard let id = currentProjectID else { throw PreviewError.nothingToRead }
        let chunkStore = store.chunkStore(for: id)
        guard let first = chunkStore.existingIndices().first else { throw PreviewError.nothingToRead }
        try play(chunkStore.url(forIndex: first))
    }

    private func play(_ url: URL) throws {
        player?.stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.play()
        player = p
    }
}
