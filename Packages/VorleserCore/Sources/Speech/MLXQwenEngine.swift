import Foundation
@preconcurrency import MLX
import MLXAudioTTS
import TextPrep

/// Qwen3-TTS über `mlx-audio-swift` (MLX, Metal-GPU).
///
/// - Genau ein Modell im Speicher (`load` entlädt ein vorhandenes zuerst).
/// - Klon-Prompt (Referenz-Encoder + Text-Tokens) wird einmal pro Stimme
///   berechnet (`prepare`) und für jeden Abschnitt wiederverwendet.
/// - Über die Actor-Grenze gehen nur `[Float]`, nie `MLXArray`.
public actor MLXQwenEngine: SpeechEngine {
    public typealias ModelLocator = @Sendable (ModelKind) throws -> URL

    private var model: Qwen3TTSModel?
    private var loadedKind: ModelKind?
    private var languageIDs: [String: Int] = [:]
    private var prompts: [UUID: Qwen3TTSModel.Qwen3TTSReferenceConditioning] = [:]
    private let locator: ModelLocator
    /// Länge der Audio-Stücke beim Streamen in Sekunden (CLAUDE.md: 0,32).
    public var streamingInterval: Double = 0.32

    public private(set) var lastStats: GenerationStats?
    public private(set) var sampleRate: Double = 0

    /// - Parameter locator: liefert den lokalen Modellordner je Modellart.
    public init(locator: @escaping ModelLocator) {
        self.locator = locator
    }

    /// Bequem: gepinntes Modell aus dem Hugging-Face-Cache.
    public init(bits: ModelBits, cacheRoot: URL = ModelSpec.defaultCacheRoot) {
        self.init(locator: { kind in
            guard let spec = ModelSpec.pinned(kind, bits: bits) else {
                throw SpeechEngineError.modelMissing("\(kind) \(bits.rawValue)-bit ist nicht festgelegt")
            }
            let dir = spec.huggingFaceSnapshotDirectory(cacheRoot: cacheRoot)
            guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path) else {
                throw SpeechEngineError.modelMissing(dir.path)
            }
            return dir
        })
    }

    public func setStreamingInterval(_ seconds: Double) {
        streamingInterval = max(0.08, seconds)
    }

    public var loadedModel: ModelKind? { loadedKind }

    // MARK: Laden / Entladen

    public func load(_ kind: ModelKind) async throws {
        if loadedKind == kind, model != nil { return }
        await unload()
        let dir = try locator(kind)
        let loaded = try await Qwen3TTSModel.fromModelDirectory(dir)
        languageIDs = Self.readLanguageIDs(modelDir: dir)
        model = loaded
        loadedKind = kind
        sampleRate = Double(loaded.sampleRate)
    }

    public func unload() async {
        let hadModel = model != nil
        model = nil
        loadedKind = nil
        prompts.removeAll()
        sampleRate = 0
        if hadModel { Memory.clearCache() }
    }

    // MARK: Stimme vorbereiten

    public func prepare(_ voice: Voice) async throws -> VoiceHandle {
        guard let model else { throw SpeechEngineError.modelNotLoaded }
        guard loadedKind == .base else { throw SpeechEngineError.wrongModel(expected: .base, loaded: loadedKind ?? .voiceDesign) }
        // Immer auf die vom Modell gemeldete Rate bringen, nie hart kodieren.
        let samples = try AudioResampler.loadReference(url: voice.referenceAudio, targetRate: sampleRate)
        let reference = MLXArray(samples)
        let cond = try model.prepareReferenceConditioning(
            refAudio: reference, refText: voice.referenceText, language: voice.language.qwenName)
        // Auswerten, damit die Kosten hier anfallen und nicht im ersten Abschnitt.
        eval(cond.referenceSpeechCodes)
        if let s = cond.speakerEmbedding { eval(s) }
        let handle = VoiceHandle(voiceID: voice.id)
        prompts[handle.id] = cond
        return handle
    }

    public func release(_ handle: VoiceHandle) {
        prompts[handle.id] = nil
    }

    // MARK: Sprechen

    public func speak(_ text: String, voice: VoiceHandle, language: Language,
                      seed: UInt64) -> AsyncThrowingStream<[Float], Error> {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream()
        let task = Task { await self.run(text, voice: voice, language: language, seed: seed, continuation: continuation) }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    private func run(_ text: String, voice: VoiceHandle, language: Language, seed: UInt64,
                     continuation: AsyncThrowingStream<[Float], Error>.Continuation) async {
        do {
            guard let model else { throw SpeechEngineError.modelNotLoaded }
            guard loadedKind == .base else { throw SpeechEngineError.wrongModel(expected: .base, loaded: loadedKind ?? .voiceDesign) }
            guard let base = prompts[voice.id] else { throw SpeechEngineError.unknownVoiceHandle }
            // Sprache des Klon-Prompts ersetzen (Referenz darf in anderer Sprache sein).
            let langName = language.qwenName
            let cond = Qwen3TTSModel.Qwen3TTSReferenceConditioning(
                speakerEmbedding: base.speakerEmbedding,
                referenceSpeechCodes: base.referenceSpeechCodes,
                referenceTextTokenIDs: base.referenceTextTokenIDs,
                resolvedLanguage: langName,
                codecLanguageID: languageIDs[langName])

            MLXRandom.seed(seed)
            Memory.peakMemory = 0
            let start = Date()
            var firstAudio: Double?
            var samplesOut = 0
            let events = model.generateStream(
                text: text, conditioning: cond,
                generationParameters: model.defaultGenerationParameters,
                streamingInterval: streamingInterval)
            for try await event in events {
                try Task.checkCancellation()
                if case let .audio(chunk) = event {
                    let floats = chunk.asArray(Float.self)
                    if firstAudio == nil { firstAudio = Date().timeIntervalSince(start) }
                    samplesOut += floats.count
                    continuation.yield(floats)
                }
            }
            lastStats = GenerationStats(
                audioSeconds: Double(samplesOut) / sampleRate,
                wallSeconds: Date().timeIntervalSince(start),
                timeToFirstAudio: firstAudio ?? 0,
                mlxPeakGB: Double(Memory.peakMemory) / 1e9)
            Memory.clearCache()
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: VoiceDesign

    public func design(description: String, sampleText: String, language: Language,
                       seed: UInt64) async throws -> [Float] {
        guard let model else { throw SpeechEngineError.modelNotLoaded }
        guard loadedKind == .voiceDesign else { throw SpeechEngineError.wrongModel(expected: .voiceDesign, loaded: loadedKind ?? .base) }
        MLXRandom.seed(seed)
        Memory.peakMemory = 0
        let start = Date()
        // Streaming statt `generate`: das nicht streamende VoiceDesign brauchte in S1 bis 9,8 GB
        // Spitze (Footprint); stückweises Dekodieren hält den Speicher flach.
        var floats: [Float] = []
        var firstAudio: Double?
        let events = model.generateStream(
            text: sampleText, voice: description, refAudio: nil, refText: nil,
            language: language.qwenName, generationParameters: model.defaultGenerationParameters,
            streamingInterval: streamingInterval)
        for try await event in events {
            try Task.checkCancellation()
            if case let .audio(chunk) = event {
                if firstAudio == nil { firstAudio = Date().timeIntervalSince(start) }
                floats.append(contentsOf: chunk.asArray(Float.self))
            }
        }
        lastStats = GenerationStats(
            audioSeconds: Double(floats.count) / sampleRate,
            wallSeconds: Date().timeIntervalSince(start),
            timeToFirstAudio: firstAudio ?? 0,
            mlxPeakGB: Double(Memory.peakMemory) / 1e9)
        Memory.clearCache()
        return floats
    }

    // MARK: Hilfen

    /// `talker_config.codec_language_id` aus der config.json des Modells.
    static func readLanguageIDs(modelDir: URL) -> [String: Int] {
        guard let data = try? Data(contentsOf: modelDir.appendingPathComponent("config.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let talker = json["talker_config"] as? [String: Any],
              let map = talker["codec_language_id"] as? [String: Any]
        else { return [:] }
        return map.compactMapValues { $0 as? Int }
    }
}
