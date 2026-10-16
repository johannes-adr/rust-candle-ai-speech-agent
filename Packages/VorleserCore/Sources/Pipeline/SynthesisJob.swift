// Arbeitet ein Vorlese-Projekt seriell ab (PLAN §4.4):
//   Import → Sprache → Abschnitte → Projekt (neu oder fortsetzen) → Modell laden →
//   Stimme vorbereiten → je Abschnitt streamen, prüfen, ggf. wiederholen, als CAF ablegen →
//   MP3 exportieren.
// Die Engine steht hinter `SpeechEngine`; Tests nehmen eine Attrappe.
import AudioOut
import DocumentImport
import Foundation
import Projects
import Speech
import TextPrep

public actor SynthesisJob {
    private let engine: any SpeechEngine
    private let store: ProjectStore
    private var config: SynthesisConfig

    private var running = false
    private var paused = false
    private var cancelRequested = false
    private var unloadTask: Task<Void, Never>?

    public init(engine: any SpeechEngine, store: ProjectStore, config: SynthesisConfig = .init()) {
        self.engine = engine
        self.store = store
        self.config = config
    }

    public var isRunning: Bool { running }

    // MARK: Steuerung

    /// Startet einen Auftrag. Der Strom endet nach `.finished`, `.stopped` oder `.failed`.
    public nonisolated func start(_ request: SynthesisRequest) -> AsyncStream<SynthesisEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: SynthesisEvent.self)
        Task { await self.run(request, continuation) }
        return stream
    }

    /// Hält vor dem nächsten Abschnitt an (ein laufender Abschnitt wird noch fertig).
    public func pause() { paused = true }
    public func resume() { paused = false }
    /// Bricht ab; Fertiges bleibt auf der Platte, `start` mit demselben Dokument macht weiter.
    public func cancel() { cancelRequested = true; paused = false }

    // MARK: Ablauf

    private func run(_ request: SynthesisRequest, _ out: AsyncStream<SynthesisEvent>.Continuation) async {
        guard !running else {
            out.yield(.failed(.busy))
            out.finish()
            return
        }
        running = true
        paused = false
        cancelRequested = false
        unloadTask?.cancel()
        unloadTask = nil
        let activity: (any NSObjectProtocol)? = config.preventSleep
            ? ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Vorleser erzeugt ein Hörbuch")
            : nil

        do {
            let result = try await execute(request, out)
            out.yield(.finished(result))
        } catch is CancellationError {
            out.yield(.stopped)
        } catch let failure as SynthesisFailure {
            out.yield(.failed(failure))
        } catch {
            out.yield(.failed(.engineFailed(error.localizedDescription)))
        }
        out.finish()

        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        running = false
        scheduleUnload()
    }

    /// Nach `idleUnloadSeconds` ohne neuen Auftrag gibt die Engine das Modell frei.
    private func scheduleUnload() {
        let seconds = config.idleUnloadSeconds
        let engine = engine
        unloadTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await engine.unload()
        }
    }

    private func checkCancelled() throws {
        if cancelRequested || Task.isCancelled { throw CancellationError() }
    }

    private func waitWhilePaused(_ out: AsyncStream<SynthesisEvent>.Continuation) async throws {
        guard paused else { return }
        out.yield(.paused)
        while paused {
            try checkCancelled()
            try await Task.sleep(for: .milliseconds(100))
        }
        out.yield(.resumed)
    }

    // MARK: Hauptteil

    private func execute(
        _ request: SynthesisRequest, _ out: AsyncStream<SynthesisEvent>.Continuation
    ) async throws -> SynthesisResult {
        // 1. Projekt bestimmen (neu oder fortsetzen).
        var project: Project
        var resumed = false
        var pageCount = request.pageCount
        var resolvedTitle = request.title

        if let id = request.resumeProjectID {
            do { project = try await store.load(id: id) } catch { throw SynthesisFailure.storeFailed("\(error)") }
            resumed = true
        } else {
            out.yield(.stage(.importing))
            let imported = try await resolveSource(request)
            pageCount = imported.pageCount ?? pageCount
            resolvedTitle = resolvedTitle ?? imported.title
            guard !imported.document.blocks.isEmpty else { throw SynthesisFailure.noText }
            try checkCancelled()

            out.yield(.stage(.detectingLanguage))
            let language: Language
            if let l = request.language {
                language = l
            } else if let d = LanguageDetector().detect(Self.plainText(imported.document)) {
                language = d.language
            } else {
                throw SynthesisFailure.languageUnknown
            }

            if let existing = await store.findExisting(
                sourceHash: imported.hash, language: language, voiceID: request.voiceKey) {
                project = existing
                resumed = true
            } else {
                out.yield(.stage(.planning))
                let chunks = TextPreparer.prepare(document: imported.document, language: language)
                guard !chunks.isEmpty else { throw SynthesisFailure.noText }
                let title = resolvedTitle ?? imported.document.title ?? "Vorgelesen"
                do {
                    project = try await store.create(
                        title: title, sourceHash: imported.hash, sourceKind: imported.kind,
                        sourceData: imported.sourceData, sourceExtension: imported.sourceExtension,
                        language: language, voiceID: request.voiceKey, style: request.style,
                        tempo: request.tempo, chunks: chunks,
                        pageIndices: Self.pageIndices(for: chunks, pageCount: pageCount))
                } catch { throw SynthesisFailure.storeFailed("\(error)") }
            }
        }

        // Fehlgeschlagene Abschnitte eines früheren Laufs bekommen eine neue Chance.
        for pc in project.chunks where pc.status == .failed {
            project = try await storeCall { try await self.store.resetChunk(id: project.id, chunkIndex: pc.chunk.index) }
        }
        try await storeCall { try await self.store.setState(.synthesizing, id: project.id) }
        let doneBefore = project.chunks.filter { $0.status == .done || $0.status == .suspicious }.count
        out.yield(.projectReady(
            projectID: project.id, resumed: resumed, chunksTotal: project.chunks.count,
            chunksAlreadyDone: doneBefore, language: project.language))

        // 2. Sprachausgabe.
        let pending = project.chunks.filter { $0.status == .pending }
        var stats = RunStats()
        if !pending.isEmpty {
            try await synthesize(pending: pending, project: project, voice: request.voice, stats: &stats, out)
        }

        // 3. Exportieren.
        try checkCancelled()
        out.yield(.stage(.exporting))
        out.yield(.exporting(fraction: 0))
        try await storeCall { try await self.store.setState(.exporting, id: project.id) }
        let final = try await storeCall { try await self.store.load(id: project.id) }
        let export = try await export(
            final, request: request, title: resolvedTitle ?? final.title, out: out)
        try await storeCall { try await self.store.setState(.finished, id: project.id) }

        let failed = final.chunks.filter { $0.status == .failed }.map(\.chunk.index)
        return SynthesisResult(
            projectID: project.id, title: final.title, fileURL: export.mainFile,
            chapterFiles: export.chapterFiles, durationSeconds: export.durationSeconds,
            chunkCount: final.chunks.count, resumed: resumed, chunksSynthesized: stats.chunks,
            retryCount: stats.retries, suspicious: stats.suspicious, failedChunks: failed,
            computeSeconds: stats.compute, synthesizedAudioSeconds: stats.audio,
            language: final.language, measuredLUFS: export.measuredLUFS)
    }

    // MARK: Import

    private struct Imported {
        var document: TextDocument
        var hash: String
        var kind: String
        var title: String?
        var pageCount: Int?
        var sourceData: Data?
        var sourceExtension: String?
    }

    private func resolveSource(_ request: SynthesisRequest) async throws -> Imported {
        switch request.source {
        case let .file(url):
            let data: Data
            do { data = try Data(contentsOf: url) } catch { throw SynthesisFailure.importFailed(error.localizedDescription) }
            do {
                let r = try await DocumentImporter().importDetailed(at: url, languageHint: request.language?.rawValue)
                let ext = url.pathExtension.lowercased()
                return Imported(
                    document: r.document, hash: SourceHash.hex(of: data), kind: ext.isEmpty ? "file" : ext,
                    title: r.document.title ?? url.deletingPathExtension().lastPathComponent,
                    pageCount: r.pageCount, sourceData: data, sourceExtension: ext.isEmpty ? nil : ext)
            } catch {
                throw SynthesisFailure.importFailed("\(error)")
            }
        case let .text(string):
            return Imported(
                document: DocumentImporter().importText(string), hash: SourceHash.hex(of: string), kind: "text",
                title: nil, pageCount: nil, sourceData: nil, sourceExtension: nil)
        case let .document(doc, hash, kind):
            return Imported(
                document: doc, hash: hash, kind: kind, title: doc.title, pageCount: request.pageCount,
                sourceData: request.sourceData, sourceExtension: request.sourceExtension)
        }
    }

    static func plainText(_ doc: TextDocument) -> String {
        doc.blocks.map { b -> String in
            switch b {
            case let .heading(_, t): t
            case let .paragraph(t): t
            }
        }.joined(separator: "\n\n")
    }

    /// Näherung: Seite nach dem Zeichenanteil. `DocumentImport` liefert keine Seitenzuordnung
    /// je Block (offener Punkt in docs/phase1.md).
    static func pageIndices(for chunks: [Chunk], pageCount: Int?) -> [Int?]? {
        guard let pages = pageCount, pages > 1, !chunks.isEmpty else { return nil }
        let total = Double(max(1, chunks.reduce(0) { $0 + $1.text.count }))
        var seen = 0
        return chunks.map { c in
            let page = min(pages - 1, Int(Double(seen) / total * Double(pages)))
            seen += c.text.count
            return page
        }
    }

    // MARK: Sprachausgabe

    private struct RunStats {
        var chunks = 0
        var retries = 0
        var compute = 0.0
        var audio = 0.0
        var suspicious: [SuspiciousChunk] = []
    }

    private func synthesize(
        pending: [ProjectChunk], project: Project, voice: Voice, stats: inout RunStats,
        _ out: AsyncStream<SynthesisEvent>.Continuation
    ) async throws {
        out.yield(.stage(.loadingModel))
        do {
            try await engine.load(.base)
        } catch let e as SpeechEngineError {
            if case let .modelMissing(path) = e { throw SynthesisFailure.modelMissing(path) }
            throw SynthesisFailure.engineFailed(e.localizedDescription)
        } catch {
            throw SynthesisFailure.engineFailed(error.localizedDescription)
        }
        try checkCancelled()
        out.yield(.stage(.preparingVoice))
        let handle: VoiceHandle
        do { handle = try await engine.prepare(voice) } catch {
            throw SynthesisFailure.engineFailed(error.localizedDescription)
        }
        let rate = await engine.sampleRate
        guard rate > 0 else { throw SynthesisFailure.engineFailed("Abtastrate unbekannt") }
        try checkCancelled()

        out.yield(.stage(.synthesizing))
        let chunkFiles = store.chunkStore(for: project.id)
        var qc = config.qc
        qc.expectedCharsPerSecond = SpeechRate.charsPerSecond(for: project.language)
        var consecutiveFailures = 0

        for pc in pending {
            try checkCancelled()
            try await waitWhilePaused(out)
            if config.thermalState().rawValue >= ProcessInfo.ThermalState.serious.rawValue {
                out.yield(.coolingDown(seconds: config.thermalPauseSeconds))
                try await Task.sleep(for: .seconds(config.thermalPauseSeconds))
            }

            let outcome = try await generate(
                pc.chunk, projectID: project.id, language: project.language, handle: handle,
                rate: rate, qc: qc, out)
            stats.retries += outcome.attempts - 1
            stats.compute += outcome.compute
            stats.suspicious += outcome.suspicious

            guard let best = outcome.best, !best.samples.isEmpty else {
                consecutiveFailures += 1
                _ = try await storeCall {
                    try await self.store.markChunkFailed(
                        id: project.id, chunkIndex: pc.chunk.index, error: outcome.lastError ?? "kein Audio",
                        seed: outcome.lastSeed, attemptsUsed: outcome.attempts)
                }
                if consecutiveFailures >= config.maxConsecutiveFailures {
                    throw SynthesisFailure.engineFailed(outcome.lastError ?? "kein Audio")
                }
                continue
            }
            consecutiveFailures = 0

            let file: URL
            do { file = try chunkFiles.write(best.samples, sampleRate: rate, index: pc.chunk.index) } catch {
                throw SynthesisFailure.storeFailed("\(error)")
            }
            let audioSeconds = Double(best.samples.count) / rate
            let updated: Project
            if best.report.isSuspicious {
                updated = try await storeCall {
                    try await self.store.markChunkSuspicious(
                        id: project.id, chunkIndex: pc.chunk.index, duration: audioSeconds,
                        computeSeconds: outcome.compute, qc: best.report, seed: best.seed,
                        attemptsUsed: outcome.attempts)
                }
            } else {
                updated = try await storeCall {
                    try await self.store.markChunkDone(
                        id: project.id, chunkIndex: pc.chunk.index, duration: audioSeconds,
                        computeSeconds: outcome.compute, qc: best.report, seed: best.seed,
                        attemptsUsed: outcome.attempts)
                }
            }
            stats.chunks += 1
            stats.audio += audioSeconds

            let est = ETAEstimator().estimate(for: updated.chunks)
            let done = updated.chunks.filter { $0.status == .done || $0.status == .suspicious }.count
            out.yield(.chunkDone(SynthesisProgress(
                chunkIndex: pc.chunk.index, chunksDone: done, chunksTotal: updated.chunks.count,
                fraction: est.progress, currentPage: est.currentPage, totalPages: est.totalPages,
                remainingSeconds: est.remainingSeconds, audioSeconds: audioSeconds,
                realTimeFactor: audioSeconds > 0 ? outcome.compute / audioSeconds : 0,
                attempts: outcome.attempts, isSuspicious: best.report.isSuspicious,
                fileURL: file, sampleRate: rate)))
        }
    }

    private struct Attempt {
        var samples: [Float]
        var report: ChunkQCReport
        var seed: UInt64
        /// Kleiner ist besser.
        var score: Double
    }

    private struct Outcome {
        var best: Attempt?
        var attempts: Int
        var compute: Double
        var suspicious: [SuspiciousChunk]
        var lastError: String?
        var lastSeed: UInt64?
    }

    /// Ein Abschnitt mit bis zu `1 + maxRetries` Versuchen (Seed = Hash(Projekt, Index, Versuch)).
    private func generate(
        _ chunk: Chunk, projectID: UUID, language: Language, handle: VoiceHandle, rate: Double,
        qc: ChunkQCConfig, _ out: AsyncStream<SynthesisEvent>.Continuation
    ) async throws -> Outcome {
        var outcome = Outcome(best: nil, attempts: 0, compute: 0, suspicious: [])
        let checkDuration = chunk.spokenText.count >= config.minCharsForDurationCheck

        for attempt in 0...config.maxRetries {
            try checkCancelled()
            let seed = SeedDerivation.seed(projectID: projectID, chunkIndex: chunk.index, attempt: attempt)
            outcome.attempts += 1
            outcome.lastSeed = seed

            var collected: [Float] = []
            var engineError: String?
            let start = Date()
            do {
                let stream = await engine.speak(chunk.spokenText, voice: handle, language: language, seed: seed)
                for try await piece in stream {
                    try checkCancelled()
                    collected.append(contentsOf: piece)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                engineError = error.localizedDescription
                collected = []
            }
            outcome.compute += Date().timeIntervalSince(start)

            var issues: [QCIssue]
            var ratio: Double?
            let report: ChunkQCReport
            let samples: [Float]
            if let engineError {
                outcome.lastError = engineError
                (samples, report) = ChunkQC.analyze(samples: [], sampleRate: rate, config: qc)
                issues = report.issues
            } else {
                (samples, report) = ChunkQC.analyze(
                    samples: collected, sampleRate: rate,
                    characterCount: checkDuration ? chunk.spokenText.count : nil, config: qc)
                issues = report.issues
                ratio = report.durationRatio
            }

            let candidate = Attempt(samples: samples, report: report, seed: seed, score: Self.score(report, empty: samples.isEmpty))
            if outcome.best == nil || candidate.score < outcome.best!.score { outcome.best = candidate }

            if issues.isEmpty { break }
            let last = attempt == config.maxRetries
            let note = SuspiciousChunk(
                chunkIndex: chunk.index, attempt: attempt, issues: issues, durationRatio: ratio,
                willRetry: !last, kept: last && !(outcome.best?.samples.isEmpty ?? true), message: engineError)
            outcome.suspicious.append(note)
            out.yield(.suspicious(note))
        }
        // Ein sauberer Versuch macht frühere Verdachtsmeldungen zu reinen Wiederholungen.
        return outcome
    }

    /// Je kleiner, desto besser: leer/stumm/NaN am schlechtesten, sonst Abstand der Dauer zu 1×.
    static func score(_ r: ChunkQCReport, empty: Bool) -> Double {
        if empty { return 1_000 }
        var s = 0.0
        if r.issues.contains(.nonFinite) { s += 100 }
        if r.issues.contains(.clipping) { s += 5 }
        if let ratio = r.durationRatio, ratio > 0 { s += abs(log(ratio)) }
        return s
    }

    // MARK: Export

    private func export(
        _ project: Project, request: SynthesisRequest, title: String,
        out: AsyncStream<SynthesisEvent>.Continuation
    ) async throws -> ExportResult {
        let files = store.chunkStore(for: project.id)
        let usable = project.chunks.filter { $0.status == .done || $0.status == .suspicious }
        guard !usable.isEmpty else { throw SynthesisFailure.noAudio }

        // Kapitelnummern fortlaufend ab 1 (Text vor der ersten Überschrift ist Kapitel 0).
        var ordinal: [Int: Int] = [:]
        var titles: [Int: String] = [:]
        for pc in usable {
            if ordinal[pc.chunk.chapter] == nil { ordinal[pc.chunk.chapter] = ordinal.count + 1 }
            if pc.chunk.kind == .heading, let n = ordinal[pc.chunk.chapter] { titles[n] = pc.chunk.text }
        }
        let exportChunks = usable.map { pc in
            ExportChunk(
                cafURL: files.url(forIndex: pc.chunk.index),
                pauseAfter: Self.pause(after: pc.chunk.kind), chapter: ordinal[pc.chunk.chapter] ?? 1)
        }

        let target = request.outputURL ?? store.outputURL(title: title)
        do {
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch { throw SynthesisFailure.exportFailed(error.localizedDescription) }

        var options = ExportOptions()
        options.tempo = request.tempo
        options.targetLUFS = config.targetLUFS
        options.pauses = config.pauses
        options.documentTitle = title
        options.voiceName = request.voice.name
        options.comment = Self.comment(for: project.language)
        options.chapterTitles = titles
        options.chapterWord = Self.chapterWord(for: project.language)
        let base = target.deletingPathExtension().lastPathComponent
        options.chapterDirectory = target.deletingLastPathComponent()
            .appending(path: base + " – " + options.chapterWord, directoryHint: .isDirectory)

        let opts = options
        do {
            return try await Task.detached(priority: .userInitiated) {
                try AudioExporter.export(
                    chunks: exportChunks, to: target, options: opts,
                    progress: { out.yield(.exporting(fraction: $0)) })
            }.value
        } catch {
            throw SynthesisFailure.exportFailed("\(error)")
        }
    }

    static func pause(after kind: ChunkKind) -> PauseKind {
        switch kind {
        case .sentence: .sentence
        case .paragraphEnd: .paragraph
        case .heading: .chapter
        }
    }

    static func comment(for language: Language) -> String {
        switch language {
        case .pt: "Lido com IA"
        case .en: "Read aloud by AI"
        default: "Mit KI vorgelesen"
        }
    }

    static func chapterWord(for language: Language) -> String {
        switch language {
        case .de: "Kapitel"
        case .pt, .es: "Capítulo"
        case .en: "Chapter"
        case .fr: "Chapitre"
        case .it: "Capitolo"
        case .ru: "Глава"
        case .zh: "章节"
        case .ja: "章"
        case .ko: "장"
        }
    }

    @discardableResult
    private func storeCall<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as SynthesisFailure { throw e } catch is CancellationError {
            throw CancellationError()
        } catch { throw SynthesisFailure.storeFailed("\(error)") }
    }
}
