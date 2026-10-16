// Schreibt Referenzaufnahmen: WAV für Kandidaten (Finder-Vorschau per Leertaste) und
// ALAC-CAF für die eingecheckten Stimmen.
import AVFoundation
import Foundation

public enum ReferenceFiles {
    /// Mono-WAV mit 16 bit (klein, überall abspielbar).
    public static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try write(samples, sampleRate: sampleRate, to: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    }

    /// Mono-ALAC (Apple Lossless) in einem CAF-Container, 16 bit.
    public static func writeALAC(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        try write(samples, sampleRate: sampleRate, to: url, settings: [
            AVFormatIDKey: kAudioFormatAppleLossless,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitDepthHintKey: 16,
        ])
    }

    private static func write(_ samples: [Float], sampleRate: Double, to url: URL, settings: [String: Any]) throws {
        guard !samples.isEmpty else { throw SpeechAudioError.emptyAudio }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: url)
        // Die Datei muss geschlossen sein, bevor jemand sie liest: eigener Bereich.
        do {
            let file = try AVAudioFile(
                forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else { throw SpeechAudioError.conversionFailed("Puffer") }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer {
                buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count)
            }
            try file.write(from: buffer)
        }
    }
}
