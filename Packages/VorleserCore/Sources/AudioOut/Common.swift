// Gemeinsame Typen und kleine Hilfsfunktionen für AudioOut.
// Es gibt hier bewusst nur [Float] (mono, Float32, ±1,0 Vollaussteuerung),
// kein MLXArray und keine Zeiger über Modulgrenzen.
import Foundation

/// Art der Pause *nach* einem Abschnitt.
public enum PauseKind: String, Codable, Sendable, CaseIterable {
    case none
    case sentence
    case paragraph
    case chapter
}

/// Pausenlängen in Sekunden (PLAN.md §4.5).
public struct PauseDurations: Codable, Sendable, Equatable {
    public var sentence: Double
    public var paragraph: Double
    public var chapter: Double

    public init(sentence: Double = 0.35, paragraph: Double = 0.8, chapter: Double = 1.5) {
        self.sentence = sentence
        self.paragraph = paragraph
        self.chapter = chapter
    }

    public func seconds(for kind: PauseKind) -> Double {
        switch kind {
        case .none: 0
        case .sentence: sentence
        case .paragraph: paragraph
        case .chapter: chapter
        }
    }
}

public enum AudioOutError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidParameter(String)
    case converterFailed(String)
    case engineFailed(String)
    case fileFailed(String)
    case encoderFailed(String)

    public var description: String {
        switch self {
        case .invalidParameter(let s): "Ungültiger Parameter: \(s)"
        case .converterFailed(let s): "Umwandlung fehlgeschlagen: \(s)"
        case .engineFailed(let s): "Audio-Engine fehlgeschlagen: \(s)"
        case .fileFailed(let s): "Dateifehler: \(s)"
        case .encoderFailed(let s): "MP3-Encoder fehlgeschlagen: \(s)"
        }
    }
}

enum DB {
    static func toLinear(_ db: Double) -> Float { Float(pow(10.0, db / 20.0)) }
    static func fromLinear(_ x: Double) -> Double { x > 0 ? 20.0 * log10(x) : -Double.infinity }
}

enum Fade {
    /// Blendet Anfang und Ende mit einer Halbkosinus-Rampe der Länge `seconds` ein bzw. aus.
    static func apply(_ samples: inout [Float], sampleRate: Double, seconds: Double) {
        let n = samples.count
        guard n > 1, seconds > 0 else { return }
        let len = min(Int((seconds * sampleRate).rounded()), n / 2)
        guard len > 0 else { return }
        for i in 0..<len {
            let g = Float(0.5 - 0.5 * cos(Double.pi * (Double(i) + 0.5) / Double(len)))
            samples[i] *= g
            samples[n - 1 - i] *= g
        }
    }
}
