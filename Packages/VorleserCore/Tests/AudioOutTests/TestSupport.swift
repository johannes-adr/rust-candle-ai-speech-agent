// Hilfen für die Tests: synthetische Signale und Prüfwerkzeuge (ffprobe/ffmpeg nur zum Prüfen).
import Foundation

enum Synth {
    static func sine(freq: Double, seconds: Double, sampleRate: Double, amplitudeDB: Double = -6) -> [Float] {
        let n = Int(seconds * sampleRate)
        let a = pow(10.0, amplitudeDB / 20.0)
        return (0..<n).map { Float(a * sin(2 * Double.pi * freq * Double($0) / sampleRate)) }
    }

    static func noise(seconds: Double, sampleRate: Double, amplitude: Float = 0.3, seed: UInt64 = 1) -> [Float] {
        var state = seed &* 6364136223846793005 &+ 1442695040888963407
        return (0..<Int(seconds * sampleRate)).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let u = Float(state >> 40) / Float(1 << 24)
            return (u * 2 - 1) * amplitude
        }
    }

    static func silence(seconds: Double, sampleRate: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * sampleRate))
    }

    /// Goertzel: Amplitude der Frequenz `freq` im Signal (linear, Sinus-Amplitude).
    static func amplitude(of samples: [Float], freq: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * freq / sampleRate
        var re = 0.0, im = 0.0
        for (i, s) in samples.enumerated() {
            re += Double(s) * cos(w * Double(i))
            im -= Double(s) * sin(w * Double(i))
        }
        return 2 * (re * re + im * im).squareRoot() / Double(samples.count)
    }

    /// Frequenz über Nulldurchgänge (aufsteigend).
    static func zeroCrossingFrequency(_ samples: [Float], sampleRate: Double) -> Double {
        var crossings = 0
        var first = -1, last = -1
        for i in 1..<samples.count where samples[i - 1] < 0 && samples[i] >= 0 {
            if first < 0 { first = i }
            last = i
            crossings += 1
        }
        guard crossings > 1 else { return 0 }
        return Double(crossings - 1) * sampleRate / Double(last - first)
    }
}

enum Tools {
    static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let p = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    static var ffprobe: String? { find("ffprobe") }
    static var ffmpeg: String? { find("ffmpeg") }

    static func run(_ path: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    /// ffprobe-Ausgabe als JSON-Wörterbuch.
    static func probe(_ url: URL) throws -> [String: Any] {
        let data = try run(ffprobe!, ["-v", "error", "-show_format", "-show_streams", "-of", "json", url.path])
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    /// Dekodiert per ffmpeg zu mono Float32 bei 44,1 kHz.
    static func decode(_ url: URL) throws -> [Float] {
        let data = try run(ffmpeg!, ["-v", "error", "-i", url.path, "-f", "f32le", "-ac", "1", "-ar", "44100", "-"])
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

func makeTempDir(_ name: String = "AudioOutTests") throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
