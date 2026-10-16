// Kleine Datei-Helfer: beliebige Audiodatei als Mono-Float lesen, WAV schreiben.
import AVFoundation
import Foundation

public enum AudioFileError: Error, Sendable, Equatable, CustomStringConvertible {
    case unreadable(String)
    case empty
    public var description: String {
        switch self {
        case .unreadable(let s): "Audiodatei nicht lesbar: \(s)"
        case .empty: "Die Audiodatei ist leer."
        }
    }
}

public enum AudioFiles {
    /// Endungen, die der Import annimmt.
    public static let importExtensions: Set<String> = ["wav", "m4a", "mp3", "caf", "aif", "aiff", "aac", "flac", "mp4"]

    /// Liest wav/m4a/mp3/caf … als Mono (Kanäle gemittelt) in der Rate der Datei.
    public static func readMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url) } catch { throw AudioFileError.unreadable(error.localizedDescription) }
        let format = file.processingFormat
        let total = file.length
        guard total > 0 else { throw AudioFileError.empty }
        let channels = Int(format.channelCount)
        var mono = [Float]()
        mono.reserveCapacity(Int(total))
        let block: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else { throw AudioFileError.unreadable("Puffer") }
        do {
            while file.framePosition < file.length {
                try file.read(into: buffer, frameCount: block)
                let n = Int(buffer.frameLength)
                if n == 0 { break }
                guard let data = buffer.floatChannelData else { throw AudioFileError.unreadable("kein Float-Puffer") }
                for i in 0..<n {
                    var s: Float = 0
                    for c in 0..<channels { s += data[c][i] }
                    mono.append(channels > 1 ? s / Float(channels) : s)
                }
            }
        } catch let e as AudioFileError {
            throw e
        } catch {
            throw AudioFileError.unreadable(error.localizedDescription)
        }
        guard !mono.isEmpty else { throw AudioFileError.empty }
        return (mono, format.sampleRate)
    }

    /// Mono-WAV, 16 bit (für die Spracherkennung und zum Anhören).
    public static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        guard !samples.isEmpty else { throw AudioFileError.empty }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        // Datei in eigenem Bereich schließen, bevor jemand sie liest.
        do {
            let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
                throw AudioFileError.unreadable("Puffer")
            }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
        }
    }
}
