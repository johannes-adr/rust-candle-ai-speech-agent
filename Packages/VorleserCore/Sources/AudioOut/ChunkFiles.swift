// Zwischenspeicher für fertige Abschnitte als CAF (Float32, mono) für „Fortsetzen“:
// `chunks/0001.caf`, `chunks/0002.caf`, …
import AVFoundation

public enum CAFFile {
    /// Schreibt mono Float32 als CAF. Es wird erst in `*.part.caf` geschrieben und dann
    /// umbenannt, damit nach einem Absturz keine halbe Datei als fertig gilt.
    public static func write(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = url.deletingPathExtension().appendingPathExtension("part.caf")
        try? fm.removeItem(at: tmp)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        do {
            // Datei in eigenem Bereich schließen, bevor umbenannt wird (Freigabe schließt AVAudioFile).
            do {
                let file = try AVAudioFile(
                    forWriting: tmp, settings: settings,
                    commonFormat: .pcmFormatFloat32, interleaved: false)
                if !samples.isEmpty {
                    guard let buf = AVAudioPCMBuffer(
                        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
                    else { throw AudioOutError.fileFailed("Puffer") }
                    buf.frameLength = AVAudioFrameCount(samples.count)
                    samples.withUnsafeBufferPointer {
                        buf.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
                    }
                    try file.write(from: buf)
                }
            }
            try? fm.removeItem(at: url)
            try fm.moveItem(at: tmp, to: url)
        } catch let e as AudioOutError {
            throw e
        } catch {
            throw AudioOutError.fileFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Liest eine CAF-Datei (Kanal 1 bei mehreren Kanälen) samt Abtastrate.
    public static func read(from url: URL) throws -> (samples: [Float], sampleRate: Double) {
        do {
            let file = try AVAudioFile(
                forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let rate = file.processingFormat.sampleRate
            let count = AVAudioFrameCount(file.length)
            if count == 0 { return ([], rate) }
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else {
                throw AudioOutError.fileFailed("Puffer")
            }
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            let out = Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: n))
            return (out, rate)
        } catch let e as AudioOutError {
            throw e
        } catch {
            throw AudioOutError.fileFailed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }
}

/// Ordner mit nummerierten Abschnitten (`0001.caf` …).
public struct ChunkStore: Sendable {
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public func url(forIndex index: Int) -> URL {
        directory.appendingPathComponent(String(format: "%04d.caf", index))
    }

    @discardableResult
    public func write(_ samples: [Float], sampleRate: Double, index: Int) throws -> URL {
        let u = url(forIndex: index)
        try CAFFile.write(samples, sampleRate: sampleRate, to: u)
        return u
    }

    public func read(index: Int) throws -> (samples: [Float], sampleRate: Double) {
        try CAFFile.read(from: url(forIndex: index))
    }

    public func exists(index: Int) -> Bool {
        FileManager.default.fileExists(atPath: url(forIndex: index).path)
    }

    /// Indizes aller fertigen Abschnitte (angefangene `*.part.caf` zählen nicht).
    public func existingIndices() -> [Int] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> Int? in
            guard name.hasSuffix(".caf"), !name.hasSuffix(".part.caf") else { return nil }
            return Int(name.dropLast(4))
        }.sorted()
    }
}
