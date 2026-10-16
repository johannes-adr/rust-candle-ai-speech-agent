// Echte Umsetzung von AudiobookService: übersetzt zwischen der Oberfläche und der Pipeline
// (Package `Pipeline`: SynthesisJob). Ein Modell, ein Auftrag zugleich, Entladen im Leerlauf.
import AVFoundation
import Foundation
import Pipeline
import Projects
import VorleserSpeech
import TextPrep

enum LiveError: Error { case nothingToRead }

actor LiveAudiobookService: AudiobookService {
    private let store: ProjectStore
    private let library: VoiceLibrary
    private let job: SynthesisJob
    private var currentProjectID: UUID?
    private var player: AVAudioPlayer?

    /// - Parameter bits: Quantisierung des Modells (PLAN: 4-bit als Standard).
    init(store: ProjectStore, library: VoiceLibrary, bits: ModelBits = .four, engine: (any SpeechEngine)? = nil) {
        self.store = store
        self.library = library
        self.job = SynthesisJob(engine: engine ?? MLXQwenEngine(bits: bits), store: store)
    }

    // MARK: Erzeugen

    nonisolated func start(_ request: AudiobookJob) -> AsyncStream<AudiobookEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: AudiobookEvent.self)
        Task { await self.run(request, continuation) }
        return stream
    }

    func pause() async { await job.pause() }
    func resume() async { await job.resume() }
    func cancel() async { await job.cancel() }

    private func run(_ request: AudiobookJob, _ out: AsyncStream<AudiobookEvent>.Continuation) async {
        out.yield(.preparing)
        guard let voice = library.store.voice(id: request.voiceID, style: request.style, fallback: true) else {
            out.yield(.failed(reasonKey: "problem.noVoice"))
            out.finish()
            return
        }
        let source: SynthesisSource = request.resumeProjectID == nil
            ? .document(request.document, sourceHash: request.sourceHash, kind: request.sourceKind)
            : .text("")
        let synthesis = SynthesisRequest(
            title: request.title, source: source, language: request.language, voice: voice,
            style: request.style, tempo: request.tempo, resumeProjectID: request.resumeProjectID,
            sourceData: request.sourceData, sourceExtension: request.sourceExtension)

        var finishing = false
        for await event in job.start(synthesis) {
            switch event {
            case let .projectReady(id, _, _, _, _):
                currentProjectID = id
                out.yield(.preparing)
            case .stage:
                if !finishing { out.yield(.preparing) }
            case let .chunkDone(p):
                out.yield(.chunkReady(fileURL: p.fileURL, pauseAfterSeconds: p.pauseAfterSeconds))
                out.yield(.progress(AudiobookProgress(
                    fraction: p.fraction, currentPage: p.currentPage, totalPages: p.totalPages,
                    remainingSeconds: p.remainingSeconds)))
            case .exporting:
                if !finishing { finishing = true; out.yield(.finishing) }
            case let .finished(r):
                out.yield(.finished(AudiobookResult(
                    projectID: r.projectID, title: r.title, fileURL: r.fileURL, durationSeconds: r.durationSeconds)))
            case .stopped:
                out.yield(.stopped)
            case let .failed(f):
                out.yield(.failed(reasonKey: Self.reasonKey(f)))
            case .suspicious, .coolingDown, .paused, .resumed:
                break
            }
        }
        out.finish()
    }

    nonisolated static func reasonKey(_ f: SynthesisFailure) -> String {
        switch f {
        case .modelMissing: "problem.modelMissing"
        default: f.reasonKey
        }
    }

    // MARK: Proben

    nonisolated func hasSample(voiceID: String, style: String) -> Bool {
        library.referenceURL(voiceID: voiceID, style: style) != nil
    }

    func playSample(voiceID: String, style: String) throws {
        guard let url = library.referenceURL(voiceID: voiceID, style: style) else { throw LiveError.nothingToRead }
        try play(url)
    }

    func stopSample() { player?.stop() }

    func listenAhead() throws {
        guard let id = currentProjectID else { throw LiveError.nothingToRead }
        let chunkStore = store.chunkStore(for: id)
        guard let first = chunkStore.existingIndices().first else { throw LiveError.nothingToRead }
        try play(chunkStore.url(forIndex: first))
    }

    private func play(_ url: URL) throws {
        player?.stop()
        let p = try AVAudioPlayer(contentsOf: url)
        p.play()
        player = p
    }
}
