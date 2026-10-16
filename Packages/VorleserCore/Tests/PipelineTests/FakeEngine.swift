// Attrappe für die Engine: erzeugt Sinuston in der Länge, die ein Mensch bräuchte,
// oder gezielt kaputtes Audio (NaN, zu kurz, stumm, Fehler).
import Foundation
import VorleserSpeech
import TextPrep

enum FakeBehavior: Sendable {
    case good
    case nan
    case tooShort
    case silent
    case tooLong
    case fail
}

actor FakeEngine: SpeechEngine {
    struct Call: Sendable, Equatable { var text: String; var seed: UInt64 }

    typealias Script = @Sendable (_ text: String, _ attempt: Int) -> FakeBehavior

    nonisolated let rate = 24_000.0
    var sampleRate: Double { loaded ? rate : 0 }
    private(set) var loaded = false
    private(set) var loadCount = 0
    private(set) var unloadCount = 0
    private(set) var prepareCount = 0
    private(set) var calls: [Call] = []
    private var attemptsByText: [String: Int] = [:]
    private let script: Script
    private let delay: Duration

    init(delay: Duration = .zero, script: @escaping Script = { _, _ in .good }) {
        self.script = script
        self.delay = delay
    }

    func load(_ model: ModelKind) async throws { loaded = true; loadCount += 1 }
    func unload() async { loaded = false; unloadCount += 1 }
    func prepare(_ voice: Voice) async throws -> VoiceHandle {
        prepareCount += 1
        return VoiceHandle(voiceID: voice.id)
    }

    func design(description: String, sampleText: String, language: Language, seed: UInt64) async throws -> [Float] {
        Self.tone(seconds: 2, rate: rate)
    }

    func speak(_ text: String, voice: VoiceHandle, language: Language, seed: UInt64) -> AsyncThrowingStream<[Float], Error> {
        calls.append(Call(text: text, seed: seed))
        let attempt = attemptsByText[text, default: 0]
        attemptsByText[text] = attempt + 1
        let behavior = script(text, attempt)
        let expected = Double(text.count) / SpeechRateForTests.de
        let rate = rate
        let delay = delay
        return AsyncThrowingStream { continuation in
            Task {
                if delay != .zero { try? await Task.sleep(for: delay) }
                switch behavior {
                case .fail:
                    continuation.finish(throwing: FakeError.boom)
                    return
                case .good:
                    Self.yieldInPieces(Self.tone(seconds: expected, rate: rate), continuation)
                case .tooLong:
                    Self.yieldInPieces(Self.tone(seconds: expected * 3, rate: rate), continuation)
                case .tooShort:
                    Self.yieldInPieces(Self.tone(seconds: expected * 0.2, rate: rate), continuation)
                case .silent:
                    Self.yieldInPieces([Float](repeating: 0, count: Int(expected * rate)), continuation)
                case .nan:
                    var s = Self.tone(seconds: expected, rate: rate)
                    s[s.count / 2] = .nan
                    s[s.count / 2 + 1] = .infinity
                    Self.yieldInPieces(s, continuation)
                }
                continuation.finish()
            }
        }
    }

    static func tone(seconds: Double, rate: Double) -> [Float] {
        let n = max(1, Int(seconds * rate))
        return (0..<n).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
    }

    private static func yieldInPieces(_ s: [Float], _ c: AsyncThrowingStream<[Float], Error>.Continuation) {
        let step = 7_680
        var i = 0
        while i < s.count {
            c.yield(Array(s[i..<min(i + step, s.count)]))
            i += step
        }
    }
}

enum FakeError: Error { case boom }

/// Gleicher Wert wie `SpeechRate.charsPerSecond(for: .de)`; die Tests prüfen das extra.
enum SpeechRateForTests { static let de = 15.8 }
