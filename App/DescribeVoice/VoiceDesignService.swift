// „Stimme beschreiben“ (Phase 4): Schnittstelle zwischen Oberfläche und VoiceDesigner (Package `Pipeline`).
// Die Oberfläche kennt nur das Protokoll; dahinter arbeitet `LiveVoiceDesignService`.
import AVFoundation
import Foundation
import Pipeline
import Speech
import TextPrep

/// Eine Stimmprobe zum Anhören.
struct DesignedProposal: Identifiable, Sendable, Equatable {
    var index: Int
    var id: Int { index }
    /// WAV zum Abspielen (temporärer Ordner).
    var previewURL: URL
    var duration: Double
    /// Hat die Prüfung etwas bemerkt (zu kurz, zu lang …)? Dann bleibt es ein Vorschlag, aber mit Hinweis.
    var isSuspicious: Bool
}

/// Grober Fortschritt für die Anzeige.
enum DesignStage: Sendable, Equatable {
    case preparing
    case proposal(Int, of: Int)
    case finishing
}

enum DesignServiceError: Error, Sendable, Equatable {
    /// Die Modelldateien fehlen.
    case modelMissing
    /// Trotz Wiederholungen kam nichts Brauchbares heraus.
    case nothingUsable
    case other
}

protocol VoiceDesignService: Sendable {
    /// Erzeugt zwei Vorschläge. Danach ist das Sprachmodell wieder entladen.
    func propose(
        wish: VoiceWish, referenceText: String, onStage: @escaping @Sendable (DesignStage) -> Void
    ) async throws -> [DesignedProposal]
    /// Speichert den Vorschlag `index` des letzten Aufrufs als Stimme.
    func save(proposal index: Int, name: String) async throws -> Voice
}

/// Teilt eine einzige Engine zwischen Vorlesen und Stimme beschreiben. Nur so ist garantiert, dass
/// nie zwei Modelle zugleich im Speicher liegen: `load(.voiceDesign)` entlädt Base und umgekehrt.
enum SharedSpeechEngine {
    static let shared = MLXQwenEngine(bits: .four)
}

actor LiveVoiceDesignService: VoiceDesignService {
    private let engine: any SpeechEngine
    private let store: DesignedVoiceStore
    private let previewDirectory: URL
    private let translator: (any DescriptionTranslating)?
    private var last: DesignResult?
    private var lastWish: VoiceWish?

    init(
        engine: any SpeechEngine = SharedSpeechEngine.shared, store: DesignedVoiceStore = .standard,
        translator: (any DescriptionTranslating)? = nil,
        previewDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "Vorleser-Vorschlaege")
    ) {
        self.engine = engine
        self.store = store
        self.translator = translator
        self.previewDirectory = previewDirectory
    }

    func propose(
        wish: VoiceWish, referenceText: String, onStage: @escaping @Sendable (DesignStage) -> Void
    ) async throws -> [DesignedProposal] {
        onStage(.preparing)
        let designer = VoiceDesigner(engine: engine, translator: translator)
        let result: DesignResult
        do {
            result = try await designer.propose(wish, referenceText: referenceText, count: 2) { progress in
                switch progress {
                case .translating, .loading: onStage(.preparing)
                case let .generating(i, n, _): onStage(.proposal(i, of: n))
                case .unloading: onStage(.finishing)
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch VoiceDesignError.noUsableProposal {
            throw DesignServiceError.nothingUsable
        } catch SpeechEngineError.modelMissing {
            throw DesignServiceError.modelMissing
        } catch {
            throw DesignServiceError.other
        }
        last = result
        lastWish = wish
        try? FileManager.default.removeItem(at: previewDirectory)
        try FileManager.default.createDirectory(at: previewDirectory, withIntermediateDirectories: true)
        return try result.proposals.map { p in
            let url = previewDirectory.appending(path: "vorschlag-\(p.index).wav")
            try ReferenceFiles.writeWAV(p.samples, sampleRate: p.sampleRate, to: url)
            return DesignedProposal(index: p.index, previewURL: url, duration: p.durationSeconds, isSuspicious: p.isSuspicious)
        }
    }

    func save(proposal index: Int, name: String) throws -> Voice {
        guard let result = last, let wish = lastWish, let p = result.proposals.first(where: { $0.index == index }) else {
            throw DesignServiceError.other
        }
        return try store.save(
            samples: p.samples, sampleRate: p.sampleRate, name: name, language: wish.readingLanguage,
            description: wish.description, referenceText: result.referenceText, prompt: result.prompt.text, seed: p.seed)
    }
}
