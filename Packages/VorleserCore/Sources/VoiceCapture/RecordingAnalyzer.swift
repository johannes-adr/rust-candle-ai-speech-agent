// Prüft eine Aufnahme der eigenen Stimme: zu leise, zu laut, Übersteuerung, Grundrauschen,
// zu kurz. Schneidet Stille an Anfang und Ende ab (AudioOut.ChunkQC) und hebt den Pegel
// sanft an. Alles Werte in dBFS; die Schwellen stehen in `RecordingCheckConfig`.
import AudioOut
import Foundation

public enum RecordingIssue: String, Sendable, Codable, CaseIterable, Equatable {
    /// Nichts zu hören.
    case silent
    case tooShort
    case tooLong
    case tooQuiet
    case tooLoud
    /// Übersteuert (Samples am Anschlag).
    case clipping
    /// Grundrauschen oder Nebengeräusche.
    case noisy
    /// NaN/Inf im Signal.
    case nonFinite

    /// Schlüssel in Localizable.xcstrings (freundlicher Hinweis an die Nutzerin).
    public var hintKey: String {
        switch self {
        case .silent: "ownVoice.hint.silent"
        case .tooShort: "ownVoice.hint.tooShort"
        case .tooLong: "ownVoice.hint.tooLong"
        case .tooQuiet: "ownVoice.hint.tooQuiet"
        case .tooLoud, .clipping: "ownVoice.hint.tooLoud"
        case .noisy: "ownVoice.hint.noisy"
        case .nonFinite: "ownVoice.hint.failed"
        }
    }

    /// Diese Aufnahme taugt nicht; „So behalten“ wird nicht angeboten.
    public var isBlocking: Bool {
        switch self {
        case .silent, .tooShort, .nonFinite: true
        default: false
        }
    }
}

public struct RecordingCheckConfig: Sendable, Equatable {
    /// Unter dieser Dauer (nach dem Trimmen) gilt die Aufnahme als zu kurz.
    public var minSeconds = 8.0
    /// Über dieser Dauer als zu lang (die Engine nutzt höchstens 20 s Referenz).
    public var maxSeconds = 18.0
    /// Sprechpegel (90. Perzentil der 50-ms-RMS-Werte) darunter: zu leise.
    public var quietBelowDBFS = -38.0
    /// Sprechpegel darüber: zu laut.
    public var loudAboveDBFS = -9.0
    /// Unter diesem Sprechpegel zählt die Aufnahme als Stille.
    public var silentBelowDBFS = -60.0
    /// Grundrauschen über diesem Wert: zu laut im Raum.
    public var noisyAboveDBFS = -45.0
    /// Abstand Sprache zu Rauschen darunter: zu laut im Raum.
    public var minSNRDB = 20.0
    /// Anteil geclippter Samples, ab dem übersteuert gemeldet wird.
    public var maxClippingFraction = 0.001
    /// Spitze nach der Anhebung (dBFS) und größte Anhebung/Absenkung in dB.
    public var targetPeakDBFS = -3.0
    public var maxGainDB = 12.0
    /// So viel natürliche Pause bleibt an Anfang/Ende (Sekunden).
    public var keepMarginSeconds = 0.15

    public init() {}
}

public struct RecordingReport: Sendable, Equatable {
    public var issues: [RecordingIssue]
    /// Dauer nach dem Abschneiden der Stille.
    public var trimmedSeconds: Double
    public var originalSeconds: Double
    public var speechLevelDBFS: Double
    public var noiseFloorDBFS: Double
    public var snrDB: Double
    public var peakDBFS: Double
    public var clippingFraction: Double
    /// Angewendete Anhebung in dB.
    public var appliedGainDB: Double

    public var hasBlockingIssue: Bool { issues.contains { $0.isBlocking } }
    public var isClean: Bool { issues.isEmpty }
}

public enum RecordingAnalyzer {
    /// - Returns: die bereinigte (getrimmte, im Pegel angeglichene) Aufnahme und der Bericht.
    public static func analyze(
        samples: [Float], sampleRate: Double, config: RecordingCheckConfig = RecordingCheckConfig()
    ) -> (samples: [Float], report: RecordingReport) {
        let original = sampleRate > 0 ? Double(samples.count) / sampleRate : 0
        var issues: [RecordingIssue] = []

        // Rauschschätzung auf dem Rohsignal (in den Pausen), danach adaptiv trimmen.
        let rawLevels = LevelMeter.frameLevels(samples.map { $0.isFinite ? $0 : 0 }, sampleRate: sampleRate)
        let rawNoise = noiseFloor(rawLevels)
        var qc = ChunkQCConfig()
        qc.silenceThresholdDBFS = min(-30, max(-55, rawNoise + 8))
        qc.keepMarginSeconds = config.keepMarginSeconds
        qc.maxClippingFraction = config.maxClippingFraction
        let (trimmed, qcReport) = ChunkQC.analyze(samples: samples, sampleRate: sampleRate, config: qc)

        if qcReport.issues.contains(.nonFinite) { issues.append(.nonFinite) }
        let levels = LevelMeter.frameLevels(trimmed, sampleRate: sampleRate)
        let speech = percentile(levels, 0.9)
        let noise = levels.isEmpty ? rawNoise : min(noiseFloor(levels), rawNoise + 6)
        let snr = speech - noise
        let peak = qcReport.peakDBFS.isFinite ? qcReport.peakDBFS : LevelMeter.floorDBFS
        let trimmedSeconds = qcReport.trimmedDurationSeconds

        if trimmed.isEmpty || speech < config.silentBelowDBFS {
            issues.append(.silent)
        } else {
            if trimmedSeconds < config.minSeconds { issues.append(.tooShort) }
            if trimmedSeconds > config.maxSeconds { issues.append(.tooLong) }
            let tooQuiet = speech < config.quietBelowDBFS
            if tooQuiet { issues.append(.tooQuiet) }
            if qcReport.clippingFraction > config.maxClippingFraction {
                issues.append(.clipping)
            } else if speech > config.loudAboveDBFS {
                issues.append(.tooLoud)
            }
            // Leise Aufnahmen haben automatisch wenig Abstand: dann zuerst „näher ans Mikrofon“.
            if noise > config.noisyAboveDBFS || (snr < config.minSNRDB && !tooQuiet) {
                issues.append(.noisy)
            }
        }

        // Sanft angleichen: Spitze auf -3 dBFS, höchstens ±12 dB. Übersteuertes nicht anheben.
        var out = trimmed
        var gainDB = 0.0
        if !trimmed.isEmpty, !issues.contains(.silent), !issues.contains(.clipping), peak.isFinite {
            gainDB = min(max(config.targetPeakDBFS - peak, -config.maxGainDB), config.maxGainDB)
            let g = Float(pow(10, gainDB / 20))
            for i in out.indices { out[i] *= g }
        }

        return (out, RecordingReport(
            issues: issues, trimmedSeconds: trimmedSeconds, originalSeconds: original,
            speechLevelDBFS: speech, noiseFloorDBFS: noise, snrDB: snr, peakDBFS: peak,
            clippingFraction: qcReport.clippingFraction, appliedGainDB: gainDB))
    }

    /// Grundrauschen: Mittel (in dB) der leisesten 10 % der 50-ms-Blöcke, also der Pausen.
    /// In dB gemittelt, damit einzelne lautere Blöcke das Ergebnis nicht nach oben ziehen.
    static func noiseFloor(_ levels: [Double]) -> Double {
        guard !levels.isEmpty else { return LevelMeter.floorDBFS }
        let sorted = levels.sorted()
        let k = max(1, Int(Double(sorted.count) * 0.10))
        return sorted.prefix(k).reduce(0.0, +) / Double(k)
    }

    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return LevelMeter.floorDBFS }
        let s = values.sorted()
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }
}
