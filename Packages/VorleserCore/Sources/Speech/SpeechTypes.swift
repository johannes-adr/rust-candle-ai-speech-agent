import Foundation
import TextPrep

/// Welches Modell gerade im Speicher liegt. Nie beide gleichzeitig.
public enum ModelKind: String, Sendable, CaseIterable, Codable {
    case base
    case voiceDesign
}

/// Quantisierung des MLX-Modells.
public enum ModelBits: Int, Sendable, CaseIterable, Codable {
    case four = 4
    case eight = 8
}

/// Ein fest gepinntes Modell auf Hugging Face.
public struct ModelSpec: Sendable, Hashable {
    public let repo: String
    public let revision: String

    public init(repo: String, revision: String) {
        self.repo = repo
        self.revision = revision
    }

    /// Gepinnte Repos (Stand 16.10.2026, siehe docs/spikes/S1-engine.md).
    public static func pinned(_ kind: ModelKind, bits: ModelBits) -> ModelSpec? {
        switch (kind, bits) {
        case (.base, .four):
            ModelSpec(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-4bit",
                      revision: "37e955a1deb861c088ae5f3a67043185f3d1a60c")
        case (.base, .eight):
            ModelSpec(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-8bit",
                      revision: "e7dd0585652209fa0d7783659aad4e8a324de11c")
        case (.voiceDesign, .four):
            ModelSpec(repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-4bit",
                      revision: "5c390979e4b93af5f2932f90742ca99c7dd04687")
        default:
            nil
        }
    }

    /// Ordner des Snapshots im Hugging-Face-Cache (`models--org--name/snapshots/<rev>`).
    public func huggingFaceSnapshotDirectory(cacheRoot: URL = ModelSpec.defaultCacheRoot) -> URL {
        cacheRoot
            .appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots")
            .appendingPathComponent(revision)
    }

    public static var defaultCacheRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }
}

/// Art der Stimme (PLAN §4.2).
public enum VoiceKind: String, Sendable, Codable {
    case preset, designed, recorded
}

/// Eine Stimme = Referenzaufnahme plus deren Text.
public struct Voice: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var language: Language
    public var kind: VoiceKind
    /// Audiodatei (beliebige Rate; wird auf die Modellrate gebracht).
    public var referenceAudio: URL
    /// Wortlaut der Referenz (für den ICL-Modus, deutlich besser als ohne).
    public var referenceText: String
    public var description: String?

    public init(id: String, name: String, language: Language, kind: VoiceKind,
                referenceAudio: URL, referenceText: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.language = language
        self.kind = kind
        self.referenceAudio = referenceAudio
        self.referenceText = referenceText
        self.description = description
    }
}

/// Griff auf einen vorbereiteten Klon-Prompt. Nur gültig, solange das Modell geladen bleibt.
public struct VoiceHandle: Sendable, Hashable {
    public let id: UUID
    public let voiceID: String
    public init(id: UUID = UUID(), voiceID: String) {
        self.id = id
        self.voiceID = voiceID
    }
}

/// Messwerte der letzten Erzeugung (für Spikes und Restzeit-Schätzung).
public struct GenerationStats: Sendable, Equatable {
    public var audioSeconds: Double
    public var wallSeconds: Double
    /// Zeit bis zum ersten Audio-Stück.
    public var timeToFirstAudio: Double
    /// Rechenzeit ÷ Audiodauer.
    public var realTimeFactor: Double { audioSeconds > 0 ? wallSeconds / audioSeconds : .infinity }
    /// Spitzenspeicher der MLX-GPU in GB seit dem letzten Zurücksetzen.
    public var mlxPeakGB: Double
}

public enum SpeechEngineError: Error, Sendable, Equatable, LocalizedError {
    case modelNotLoaded
    case wrongModel(expected: ModelKind, loaded: ModelKind)
    case modelMissing(String)
    case unknownVoiceHandle
    case invalidAudio(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Es ist kein Modell geladen."
        case let .wrongModel(expected, loaded): "Benötigt \(expected), geladen ist \(loaded)."
        case let .modelMissing(path): "Modell nicht gefunden: \(path)"
        case .unknownVoiceHandle: "Stimme wurde nicht vorbereitet."
        case let .invalidAudio(why): "Ungültiges Audio: \(why)"
        }
    }
}

public extension Language {
    /// Name, wie ihn Qwen3-TTS in `codec_language_id` erwartet.
    var qwenName: String {
        switch self {
        case .de: "german"
        case .pt: "portuguese"
        case .en: "english"
        case .es: "spanish"
        case .fr: "french"
        case .it: "italian"
        case .ru: "russian"
        case .zh: "chinese"
        case .ja: "japanese"
        case .ko: "korean"
        }
    }
}

/// Schnittstelle laut PLAN §4.2. Immer ein Actor; über die Grenze gehen nur `[Float]`.
public protocol SpeechEngine: Actor {
    /// Lädt genau ein Modell; ein bereits geladenes wird vorher entladen.
    func load(_ model: ModelKind) async throws
    func unload() async
    /// Klon-Prompt einmal pro Stimme berechnen und cachen.
    func prepare(_ voice: Voice) async throws -> VoiceHandle
    /// Streamt Mono-Samples in der Modellrate (`sampleRate`).
    func speak(_ text: String, voice: VoiceHandle, language: Language,
               seed: UInt64) -> AsyncThrowingStream<[Float], Error>
    /// Nur VoiceDesign: erzeugt eine Referenzaufnahme aus einer Beschreibung.
    func design(description: String, sampleText: String, language: Language,
                seed: UInt64) async throws -> [Float]
    /// Abtastrate des geladenen Modells (0, wenn nichts geladen ist).
    var sampleRate: Double { get }
}
