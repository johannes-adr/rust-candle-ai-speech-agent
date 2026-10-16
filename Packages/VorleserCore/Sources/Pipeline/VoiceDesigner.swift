// Stimme beschreiben (Phase 4, „Design → Klon“): aus einem Wunsch zwei Vorschläge erzeugen.
//
// Warum in `Pipeline` und nicht in `Speech`: Der Designer braucht die Prüfung aus `AudioOut`
// (`ChunkQC`) und die Sprechraten aus `Pipeline`; `Speech` kennt beides nicht und soll nur die
// Engine und das Speichern von Stimmen enthalten (`DesignedVoiceStore`).
//
// Speicher: VoiceDesign und Base liegen nie zugleich im Speicher. `engine.load(.voiceDesign)`
// entlädt Base, und nach den Vorschlägen (auch bei Fehler und Abbruch) wird VoiceDesign wieder
// entladen. Base wird erst beim Vorlesen neu geladen (`SynthesisJob`).
import AudioOut
import CryptoKit
import Foundation
import Speech
import TextPrep

public enum VoiceGender: String, Sendable, Codable, CaseIterable {
    case female, male
}

public enum VoiceAgeHint: String, Sendable, Codable, CaseIterable {
    case young, middleAged, elderly
}

/// Der Wunsch der Nutzerin.
public struct VoiceWish: Sendable, Equatable {
    /// Freitext, in der Sprache der Oberfläche geschrieben („ruhig und warm, wie eine Großmutter“).
    public var description: String
    /// Sprache, in der `description` geschrieben ist (Oberflächensprache); `nil` = unbekannt.
    public var descriptionLanguage: Language?
    /// Sprache, in der später vorgelesen wird.
    public var readingLanguage: Language
    public var gender: VoiceGender?
    public var age: VoiceAgeHint?
    /// Optionaler Herkunftshinweis auf Englisch, z. B. „from Lisbon, Portugal“.
    public var regionHint: String?

    public init(
        description: String, descriptionLanguage: Language? = nil, readingLanguage: Language,
        gender: VoiceGender? = nil, age: VoiceAgeHint? = nil, regionHint: String? = nil
    ) {
        self.description = description
        self.descriptionLanguage = descriptionLanguage
        self.readingLanguage = readingLanguage
        self.gender = gender
        self.age = age
        self.regionHint = regionHint
    }
}

public enum VoiceDesignError: Error, Sendable, Equatable, LocalizedError {
    case emptyWish
    /// Kein einziger brauchbarer Vorschlag trotz Wiederholungen.
    case noUsableProposal
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .emptyWish: "Der Wunsch ist leer."
        case .noUsableProposal: "Es ist kein brauchbarer Vorschlag entstanden."
        case let .engine(why): why
        }
    }
}

/// Ein Vorschlag: eine Referenzaufnahme von ca. 10–12 s.
public struct DesignProposal: Sendable, Equatable, Identifiable {
    /// 1 oder 2
    public var index: Int
    public var id: Int { index }
    /// Mono-Samples in `sampleRate`, geprüft (Stille am Rand abgeschnitten, nie NaN).
    public var samples: [Float]
    public var sampleRate: Double
    public var seed: UInt64
    /// Anzahl Versuche bis zum brauchbaren Ergebnis (1 = auf Anhieb).
    public var attempts: Int
    public var report: ChunkQCReport
    /// Rechenzeit dieses Vorschlags (alle Versuche) in Sekunden.
    public var wallSeconds: Double
    /// Verdächtig, aber nach allen Wiederholungen das beste Ergebnis.
    public var isSuspicious: Bool { report.isSuspicious }
    public var durationSeconds: Double { Double(samples.count) / sampleRate }
}

public enum DesignProgress: Sendable, Equatable {
    case translating
    case loading
    /// `proposal` von `total` (1-basiert), `attempt` ab 1.
    case generating(proposal: Int, total: Int, attempt: Int)
    case unloading
}

public struct DesignResult: Sendable {
    public var proposals: [DesignProposal]
    /// Die an VoiceDesign gegebene Anweisung.
    public var prompt: VoicePrompt
    public var referenceText: String
    public var totalSeconds: Double
}

public actor VoiceDesigner {
    public struct Config: Sendable {
        /// Höchstzahl an Versuchen je Vorschlag (neuer Seed bei Verdacht).
        public var maxAttempts = 3
        /// Referenz soll ca. 8–20 s lang sein (ruhige Stimmen brauchen für den Lesetext bis 16 s); außerhalb gilt als verdächtig.
        public var minSeconds = 7.0
        public var maxSeconds = 20.0
        public init() {}
    }

    private let engine: any SpeechEngine
    private let translator: (any DescriptionTranslating)?
    private let config: Config

    public init(engine: any SpeechEngine, translator: (any DescriptionTranslating)? = nil, config: Config = .init()) {
        self.engine = engine
        self.translator = translator
        self.config = config
    }

    /// Erzeugt `count` Vorschläge mit verschiedenen Seeds. Entlädt danach VoiceDesign, auch bei Fehler.
    /// - Parameters:
    ///   - referenceText: fester Lesetext der Lesesprache (`Resources/ReadAloud`), wird zugleich das Transkript.
    ///   - seedBase: Ausgangswert der Seeds; wechselt bei jedem Aufruf („Nochmal andere Vorschläge“).
    public func propose(
        _ wish: VoiceWish, referenceText: String, count: Int = 2, seedBase: UInt64 = .random(in: .min ... .max),
        onProgress: (@Sendable (DesignProgress) -> Void)? = nil
    ) async throws -> DesignResult {
        guard !wish.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VoiceDesignError.emptyWish
        }
        onProgress?(.translating)
        let prompt = await VoicePromptBuilder.build(wish, translator: translator)
        return try await propose(prompt: prompt, language: wish.readingLanguage, referenceText: referenceText,
                                 count: count, seedBase: seedBase, onProgress: onProgress)
    }

    /// Wie `propose(_:)`, aber mit fertiger Anweisung (CLI-Messungen, Tests).
    public func propose(
        prompt: VoicePrompt, language: Language, referenceText: String, count: Int = 2,
        seedBase: UInt64 = .random(in: .min ... .max),
        onProgress: (@Sendable (DesignProgress) -> Void)? = nil
    ) async throws -> DesignResult {
        let started = Date()
        var proposals: [DesignProposal] = []
        do {
            onProgress?(.loading)
            try await engine.load(.voiceDesign)
            for index in 1...max(count, 1) {
                try Task.checkCancellation()
                if let p = try await makeProposal(
                    index: index, total: count, prompt: prompt, language: language,
                    referenceText: referenceText, seedBase: seedBase, onProgress: onProgress)
                { proposals.append(p) }
            }
        } catch {
            onProgress?(.unloading)
            await engine.unload()
            if error is CancellationError || error is VoiceDesignError || error is SpeechEngineError { throw error }
            throw VoiceDesignError.engine("\(error)")
        }
        onProgress?(.unloading)
        await engine.unload()
        guard !proposals.isEmpty else { throw VoiceDesignError.noUsableProposal }
        return DesignResult(
            proposals: proposals, prompt: prompt, referenceText: referenceText,
            totalSeconds: Date().timeIntervalSince(started))
    }

    private func makeProposal(
        index: Int, total: Int, prompt: VoicePrompt, language: Language, referenceText: String,
        seedBase: UInt64, onProgress: (@Sendable (DesignProgress) -> Void)?
    ) async throws -> DesignProposal? {
        var qc = ChunkQCConfig()
        qc.expectedCharsPerSecond = SpeechRate.charsPerSecond(for: language)
        var best: DesignProposal?
        var bestScore = Double.infinity
        let started = Date()
        for attempt in 1...max(config.maxAttempts, 1) {
            try Task.checkCancellation()
            onProgress?(.generating(proposal: index, total: total, attempt: attempt))
            let seed = Self.seed(base: seedBase, index: index, attempt: attempt)
            // Das Modell kann zwischendurch entladen worden sein (Leerlauf-Timer eines früheren Auftrags).
            try await engine.load(.voiceDesign)
            let raw = try await engine.design(
                description: prompt.text, sampleText: referenceText, language: language, seed: seed)
            let rate = await engine.sampleRate
            let (samples, report) = ChunkQC.analyze(
                samples: raw, sampleRate: rate, characterCount: referenceText.count, config: qc)
            var issues = report.issues
            let seconds = report.trimmedDurationSeconds
            if !samples.isEmpty, seconds < config.minSeconds, !issues.contains(.tooShort) { issues.append(.tooShort) }
            if seconds > config.maxSeconds, !issues.contains(.tooLong) { issues.append(.tooLong) }
            var checked = report
            checked.issues = issues
            let candidate = DesignProposal(
                index: index, samples: samples, sampleRate: rate, seed: seed, attempts: attempt,
                report: checked, wallSeconds: Date().timeIntervalSince(started))
            if issues.isEmpty { return candidate }
            // Brauchbar ist nur Audio ohne NaN/Stille; sonst bestes Dauerverhältnis merken.
            let hard = issues.contains { $0 == .nonFinite || $0 == .silent || $0 == .empty || $0 == .clipping }
            if !samples.isEmpty, !hard {
                let score = abs(log(max(report.durationRatio ?? 1, 0.01)))
                if score < bestScore { bestScore = score; best = candidate }
            }
        }
        // Nach allen Versuchen verdächtig: nur ein Vorschlag mit echtem Audio bleibt übrig.
        return best
    }

    /// Stabiler Seed je Aufruf, Vorschlag und Versuch.
    static func seed(base: UInt64, index: Int, attempt: Int) -> UInt64 {
        let digest = SHA256.hash(data: Data("\(base)|\(index)|\(attempt)".utf8))
        return digest.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
