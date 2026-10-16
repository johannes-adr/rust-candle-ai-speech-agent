// Lautheit nach ITU-R BS.1770-4 (K-Gewichtung, Gating) für Mono,
// plus Spitzenbegrenzung. Eigene schlanke Implementierung, keine Abhängigkeit.
import Foundation

/// Biquad (Direct Form I) in Double.
struct Biquad: Sendable {
    var b0, b1, b2, a1, a2: Double
    var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0; self.b1 = b1; self.b2 = b2; self.a1 = a1; self.a2 = a2
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x; y2 = y1; y1 = y
        return y
    }
}

/// K-Gewichtung für beliebige Abtastraten (Koeffizientenformeln wie in libebur128;
/// bei 48 kHz identisch mit den Tabellenwerten der Norm).
struct KWeighting: Sendable {
    var shelf: Biquad
    var highpass: Biquad

    init(sampleRate fs: Double) {
        // Stufe 1: Kopf-Akustik, Hochton-Shelf (+4 dB).
        let f0 = 1681.974450955533
        let g = 3.999843853973347
        let q = 0.7071752369554196
        let k = tan(Double.pi * f0 / fs)
        let vh = pow(10.0, g / 20.0)
        let vb = pow(vh, 0.4996667741545416)
        let a0 = 1.0 + k / q + k * k
        shelf = Biquad(
            b0: (vh + vb * k / q + k * k) / a0,
            b1: 2.0 * (k * k - vh) / a0,
            b2: (vh - vb * k / q + k * k) / a0,
            a1: 2.0 * (k * k - 1.0) / a0,
            a2: (1.0 - k / q + k * k) / a0)

        // Stufe 2: RLB-Hochpass.
        let f1 = 38.13547087602444
        let q1 = 0.5003270373238773
        let k1 = tan(Double.pi * f1 / fs)
        let a01 = 1.0 + k1 / q1 + k1 * k1
        highpass = Biquad(
            b0: 1.0, b1: -2.0, b2: 1.0,
            a1: 2.0 * (k1 * k1 - 1.0) / a01,
            a2: (1.0 - k1 / q1 + k1 * k1) / a01)
    }

    @inline(__always)
    mutating func process(_ x: Double) -> Double {
        highpass.process(shelf.process(x))
    }
}

/// Streamender Lautheitsmesser (integriert, mit absolutem und relativem Gate).
/// Merkt sich nur eine Zahl je 100 ms, der Speicher bleibt also flach.
public struct LoudnessMeter: Sendable {
    public let sampleRate: Double
    private var filter: KWeighting
    private let hop: Int
    private var hopSum = 0.0
    private var hopCount = 0
    private var hopEnergies: [Double] = []   // mittlere Energie je 100-ms-Schritt
    private var totalSum = 0.0
    private var totalCount = 0

    public init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.filter = KWeighting(sampleRate: sampleRate)
        self.hop = max(1, Int((0.1 * sampleRate).rounded()))
    }

    public mutating func process(_ samples: [Float]) {
        for s in samples {
            let y = filter.process(Double(s))
            let e = y * y
            hopSum += e
            hopCount += 1
            totalSum += e
            totalCount += 1
            if hopCount == hop {
                hopEnergies.append(hopSum / Double(hop))
                hopSum = 0
                hopCount = 0
            }
        }
    }

    /// Integrierte Lautheit in LUFS; `nil`, wenn nichts oberhalb des Gates (−70 LUFS) liegt.
    public var integratedLUFS: Double? {
        // Blöcke à 400 ms mit 75 % Überlappung = 4 aufeinanderfolgende 100-ms-Schritte.
        var blocks: [Double] = []
        if hopEnergies.count >= 4 {
            var window = hopEnergies[0..<4].reduce(0, +)
            blocks.append(window / 4)
            for i in 4..<hopEnergies.count {
                window += hopEnergies[i] - hopEnergies[i - 4]
                blocks.append(window / 4)
            }
        } else if totalCount > 0 {
            // Kürzer als 400 ms: ganzes Signal als ein Block.
            blocks.append(totalSum / Double(totalCount))
        }
        func lufs(_ z: Double) -> Double { -0.691 + 10.0 * log10(z) }

        let absGated = blocks.filter { $0 > 0 && lufs($0) > -70.0 }
        guard !absGated.isEmpty else { return nil }
        let meanAbs = absGated.reduce(0, +) / Double(absGated.count)
        let relThreshold = lufs(meanAbs) - 10.0
        let relGated = absGated.filter { lufs($0) > relThreshold }
        guard !relGated.isEmpty else { return nil }
        return lufs(relGated.reduce(0, +) / Double(relGated.count))
    }
}

public enum Loudness {
    /// Integrierte Lautheit eines Signals in LUFS (`nil` = praktisch stumm).
    public static func integratedLUFS(of samples: [Float], sampleRate: Double) -> Double? {
        var m = LoudnessMeter(sampleRate: sampleRate)
        m.process(samples)
        return m.integratedLUFS
    }

    /// Verstärkung (dB), um von `measured` auf `target` zu kommen, begrenzt auf ±`maxAbsDB`.
    public static func gainDB(measuredLUFS measured: Double?, targetLUFS target: Double, maxAbsDB: Double = 24) -> Double {
        guard let m = measured else { return 0 }
        return min(max(target - m, -maxAbsDB), maxAbsDB)
    }
}

public enum PeakLimiter {
    /// Sample-Spitzenwert (linear).
    public static func samplePeak(_ samples: [Float]) -> Float {
        var p: Float = 0
        for s in samples { let a = abs(s); if a > p { p = a } }
        return p
    }

    /// Geschätzter True-Peak (linear) durch 4-fache Überabtastung (gefensterter Sinc).
    public static func truePeak(_ samples: [Float]) -> Float {
        let taps = 12                       // je Phase, also 48 insgesamt
        let phases = 4
        // Koeffizienten für die Zwischenpositionen 1/4, 2/4, 3/4.
        var coeffs = [[Double]](repeating: [], count: phases)
        for p in 1..<phases {
            let frac = Double(p) / Double(phases)
            coeffs[p] = (0..<taps).map { j in
                let x = Double(j - taps / 2 + 1) - frac      // Abstand zum Stützpunkt
                let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let w = 0.5 + 0.5 * cos(Double.pi * x / Double(taps / 2 + 1))   // Hann
                return sinc * w
            }
        }
        var peak = Double(samplePeak(samples))
        let n = samples.count
        guard n >= taps else { return Float(peak) }
        for i in 0..<(n - taps) {
            for p in 1..<phases {
                var acc = 0.0
                for j in 0..<taps { acc += Double(samples[i + j]) * coeffs[p][j] }
                peak = max(peak, abs(acc))
            }
        }
        return Float(peak)
    }

    /// Begrenzt die Spitzen auf `ceilingDBFS` mit einer weichen Verstärkungskurve
    /// (vorausschauend, ca. 5 ms), damit es nicht knackt. Prüft danach den True-Peak
    /// und senkt die Schwelle bei Bedarf einmal nach.
    public static func limit(_ samples: inout [Float], sampleRate: Double, ceilingDBFS: Double = -1.5) {
        guard !samples.isEmpty else { return }
        var ceiling = Double(DB.toLinear(ceilingDBFS))
        let target = ceiling
        for _ in 0..<3 {
            applySmooth(&samples, sampleRate: sampleRate, ceiling: Float(ceiling))
            let tp = Double(truePeak(samples))
            if tp <= target * 1.0005 { return }
            ceiling *= target / tp
        }
    }

    private static func applySmooth(_ samples: inout [Float], sampleRate: Double, ceiling: Float) {
        let n = samples.count
        guard samplePeak(samples) > ceiling else { return }
        let look = max(2, Int((0.005 * sampleRate).rounded()))

        // Benötigte Verstärkung je Sample.
        var need = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let a = abs(samples[i])
            if a > ceiling { need[i] = ceiling / a }
        }
        // Gleitendes Minimum über [i-look, i+look], dann Mittelwert über `look+1`
        // zentriert: das Ergebnis liegt an jeder Stelle <= need.
        var minFiltered = [Float](repeating: 1, count: n)
        var deque = [Int]()      // Indizes mit aufsteigenden Werten
        deque.reserveCapacity(2 * look + 2)
        var head = 0
        var nextAdd = 0
        for i in 0..<n {
            let hi = min(n - 1, i + look)
            while nextAdd <= hi {
                while deque.count > head, need[deque[deque.count - 1]] >= need[nextAdd] { deque.removeLast() }
                deque.append(nextAdd)
                nextAdd += 1
            }
            while deque[head] < i - look { head += 1 }
            minFiltered[i] = need[deque[head]]
        }
        // Box-Mittelung der Breite `look + 1` (Fenster bleibt innerhalb des Min-Fensters).
        let w = look + 1
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + Double(minFiltered[i]) }
        for i in 0..<n {
            let lo = max(0, i - w / 2)
            let hi = min(n, i - w / 2 + w)
            let g = Float((prefix[hi] - prefix[lo]) / Double(max(hi - lo, 1)))
            samples[i] *= min(g, need[i] == 1 ? 1 : need[i])
        }
    }
}
