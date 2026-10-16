// Beispieldateien für den Hörtest (nur auf Anfrage über eine Umgebungsvariable).
import Foundation
import Testing
@testable import AudioOut

@Suite struct SpikeSample {
    /// `VORLESER_SPIKE_OUT=<Ordner> swift test --filter SpikeSample` schreibt Beispiel-MP3s.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["VORLESER_SPIKE_OUT"] != nil))
    func writeSample() throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VORLESER_SPIKE_OUT"]!)
        // Drei „Sätze“: Töne 220/330/440 Hz mit langsamer Hüllkurve, 24 kHz wie das Modell.
        func tone(_ f: Double, _ sec: Double) -> [Float] {
            let r = 24_000.0
            return (0..<Int(sec * r)).map { i in
                let t = Double(i) / r
                let env = 0.6 + 0.4 * sin(2 * Double.pi * 2.5 * t)
                return Float(0.35 * env * sin(2 * Double.pi * f * t))
            }
        }
        var o = ExportOptions()
        o.documentTitle = "Vorleser Testton"
        o.voiceName = "Testsprecherin"
        o.chapterTitles = [1: "Erster Teil", 2: "Zweiter Teil"]
        o.chapterDirectory = out.appendingPathComponent("Kapitel")
        let chunks = [
            ExportChunk(samples: tone(220, 2), sampleRate: 24_000, pauseAfter: .sentence, chapter: 1),
            ExportChunk(samples: tone(330, 2), sampleRate: 24_000, pauseAfter: .chapter, chapter: 1),
            ExportChunk(samples: tone(440, 2), sampleRate: 24_000, pauseAfter: .none, chapter: 2),
        ]
        let r = try AudioExporter.export(
            chunks: chunks, to: out.appendingPathComponent("Vorleser Testton.mp3"), options: o)
        print("SPIKE-SAMPLE \(r)")
    }
}
