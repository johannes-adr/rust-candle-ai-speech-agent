// Pegelwerte für die Anzeige beim Aufnehmen (RMS und Spitze in dBFS).
import Foundation

/// Ein Messwert des Mikrofons, etwa 10 bis 20 Mal pro Sekunde.
public struct LevelReading: Sendable, Equatable {
    public var rmsDBFS: Double
    public var peakDBFS: Double
    /// Bisher aufgenommene Sekunden.
    public var elapsedSeconds: Double

    public init(rmsDBFS: Double, peakDBFS: Double, elapsedSeconds: Double) {
        self.rmsDBFS = rmsDBFS
        self.peakDBFS = peakDBFS
        self.elapsedSeconds = elapsedSeconds
    }

    /// 0 … 1 für einen Balken: −60 dBFS = leer, 0 dBFS = voll.
    public var meterFraction: Double { LevelMeter.fraction(forDBFS: rmsDBFS) }

    /// Spitze nahe Vollaussteuerung: die Anzeige soll warnen.
    public var isHot: Bool { peakDBFS > -1.5 }
}

public enum LevelMeter {
    /// Untergrenze für Anzeige und Rechnung (Stille).
    public static let floorDBFS = -120.0

    public static func dBFS(linear x: Double) -> Double {
        x > 1e-6 ? max(floorDBFS, 20 * log10(x)) : floorDBFS
    }

    public static func fraction(forDBFS db: Double) -> Double {
        min(max((db + 60) / 60, 0), 1)
    }

    /// RMS und Spitze eines Blocks als dBFS. Nicht endliche Werte zählen als 0.
    public static func measure(_ samples: UnsafeBufferPointer<Float>) -> (rmsDBFS: Double, peakDBFS: Double) {
        guard !samples.isEmpty else { return (floorDBFS, floorDBFS) }
        var sum = 0.0
        var peak: Float = 0
        for v in samples where v.isFinite {
            sum += Double(v) * Double(v)
            peak = max(peak, abs(v))
        }
        return (dBFS(linear: (sum / Double(samples.count)).squareRoot()), dBFS(linear: Double(peak)))
    }

    public static func measure(_ samples: [Float]) -> (rmsDBFS: Double, peakDBFS: Double) {
        samples.withUnsafeBufferPointer { measure($0) }
    }

    /// Pegel je Block fester Länge (für die Rauschschätzung).
    public static func frameLevels(_ samples: [Float], sampleRate: Double, frameSeconds: Double = 0.05) -> [Double] {
        let n = max(1, Int(sampleRate * frameSeconds))
        guard samples.count >= n else { return samples.isEmpty ? [] : [measure(samples).rmsDBFS] }
        var out: [Double] = []
        out.reserveCapacity(samples.count / n)
        samples.withUnsafeBufferPointer { p in
            var i = 0
            while i + n <= p.count {
                out.append(measure(UnsafeBufferPointer(rebasing: p[i..<(i + n)])).rmsDBFS)
                i += n
            }
        }
        return out
    }
}
