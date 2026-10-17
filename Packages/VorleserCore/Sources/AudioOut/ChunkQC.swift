// Qualitätsprüfung je Abschnitt (PLAN.md §4.4, Schritt 1 und 2):
// NaN/Inf, Clipping, Stille an den Rändern, Dauerplausibilität.
import Foundation

public enum QCIssue: String, Codable, Sendable, Equatable {
    /// NaN oder Inf im Signal (z. B. F16-Überlauf im Sampling).
    case nonFinite
    /// Zu viele Samples am Anschlag.
    case clipping
    /// Der Abschnitt enthält nach dem Abschneiden gar kein Signal.
    case silent
    /// Kürzer als die 0,5-fache erwartete Dauer (abgeschnitten, verschluckter Text?).
    case tooShort
    /// Länger als die 2-fache erwartete Dauer (Wiederholungen, Gebrabbel?).
    case tooLong
    /// Kein Audio vorhanden.
    case empty
}

public struct ChunkQCConfig: Sendable, Equatable {
    /// Alles unter dieser Schwelle gilt am Rand als Stille.
    public var silenceThresholdDBFS: Double = -50
    /// So viel Stille bleibt an Anfang/Ende stehen (damit nichts abgehackt klingt).
    public var keepMarginSeconds: Double = 0.02
    /// Betrag ab dem ein Sample als „am Anschlag“ zählt.
    public var clipLevel: Float = 0.999
    /// Anteil geclippter Samples, ab dem der Abschnitt verdächtig ist.
    public var maxClippingFraction: Double = 0.001
    /// Sprechrate (Zeichen je Sekunde) zur Schätzung der erwarteten Dauer.
    /// Für CJK-Sprachen kleiner wählen bzw. Zeichenzahl entsprechend umrechnen.
    public var expectedCharsPerSecond: Double = 14
    public var minDurationRatio: Double = 0.5
    public var maxDurationRatio: Double = 2.0

    public init() {}
}

public struct ChunkQCReport: Codable, Sendable, Equatable {
    public var sampleRate: Double
    /// Dauer vor dem Abschneiden.
    public var originalDurationSeconds: Double
    /// Dauer nach dem Abschneiden der Stille.
    public var trimmedDurationSeconds: Double
    public var leadingSilenceSeconds: Double
    public var trailingSilenceSeconds: Double
    public var nonFiniteCount: Int
    public var clippingFraction: Double
    public var peakDBFS: Double
    public var rmsDBFS: Double
    public var expectedDurationSeconds: Double?
    /// getrimmte Dauer ÷ erwartete Dauer.
    public var durationRatio: Double?
    public var issues: [QCIssue]

    public var isSuspicious: Bool { !issues.isEmpty }
}

public enum ChunkQC {
    /// Prüft einen Abschnitt und liefert ihn bereinigt zurück
    /// (nicht-endliche Werte werden 0, Stille an den Rändern wird abgeschnitten).
    /// - Parameter characterCount: Zeichenzahl des Textabschnitts; `nil` = keine Dauerprüfung.
    public static func analyze(
        samples: [Float],
        sampleRate: Double,
        characterCount: Int? = nil,
        config: ChunkQCConfig = ChunkQCConfig()
    ) -> (samples: [Float], report: ChunkQCReport) {
        var issues: [QCIssue] = []
        var cleaned = samples
        var nonFinite = 0
        var clipped = 0
        var peak: Float = 0
        var sumSq = 0.0
        for i in cleaned.indices {
            let v = cleaned[i]
            if !v.isFinite {
                nonFinite += 1
                cleaned[i] = 0
                continue
            }
            let a = abs(v)
            if a > peak { peak = a }
            if a >= config.clipLevel { clipped += 1 }
            sumSq += Double(v) * Double(v)
        }
        let n = max(cleaned.count, 1)
        let (trimmed, lead, trail) = trimSilence(
            cleaned, sampleRate: sampleRate,
            thresholdDBFS: config.silenceThresholdDBFS, marginSeconds: config.keepMarginSeconds)

        let orig = Double(samples.count) / sampleRate
        let trimmedDur = Double(trimmed.count) / sampleRate
        let clipFraction = Double(clipped) / Double(n)

        if samples.isEmpty { issues.append(.empty) }
        if nonFinite > 0 { issues.append(.nonFinite) }
        if clipFraction > config.maxClippingFraction { issues.append(.clipping) }
        if !samples.isEmpty && trimmed.isEmpty { issues.append(.silent) }

        var expected: Double?
        var ratio: Double?
        if let chars = characterCount, chars > 0, config.expectedCharsPerSecond > 0 {
            let e = Double(chars) / config.expectedCharsPerSecond
            expected = e
            let r = trimmedDur / e
            ratio = r
            if !trimmed.isEmpty {
                if r < config.minDurationRatio { issues.append(.tooShort) }
                if r > config.maxDurationRatio { issues.append(.tooLong) }
            }
        }

        let report = ChunkQCReport(
            sampleRate: sampleRate,
            originalDurationSeconds: orig,
            trimmedDurationSeconds: trimmedDur,
            leadingSilenceSeconds: lead,
            trailingSilenceSeconds: trail,
            nonFiniteCount: nonFinite,
            clippingFraction: clipFraction,
            peakDBFS: DB.fromLinear(Double(peak)),
            rmsDBFS: DB.fromLinear((sumSq / Double(n)).squareRoot()),
            expectedDurationSeconds: expected,
            durationRatio: ratio,
            issues: issues)
        return (trimmed, report)
    }

    /// Schneidet Stille an Anfang und Ende ab. Gibt außerdem die abgeschnittenen Sekunden zurück.
    /// Besteht das ganze Signal aus Stille, kommt ein leeres Array zurück.
    public static func trimSilence(
        _ samples: [Float], sampleRate: Double,
        thresholdDBFS: Double = -50, marginSeconds: Double = 0.02
    ) -> (samples: [Float], leadingSeconds: Double, trailingSeconds: Double) {
        let threshold = DB.toLinear(thresholdDBFS)
        guard let first = samples.firstIndex(where: { abs($0) > threshold }),
              let last = samples.lastIndex(where: { abs($0) > threshold })
        else {
            let d = Double(samples.count) / sampleRate
            return ([], d, 0)
        }
        let margin = Int((marginSeconds * sampleRate).rounded())
        let start = max(0, first - margin)
        let end = min(samples.count - 1, last + margin)
        return (
            Array(samples[start...end]),
            Double(start) / sampleRate,
            Double(samples.count - 1 - end) / sampleRate)
    }
}
