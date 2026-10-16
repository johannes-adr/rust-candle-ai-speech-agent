// Bandbegrenztes Resampling mit AVAudioConverter (nie linear interpolieren:
// siehe CLAUDE.md, Lehren aus dem alten Rust-Projekt).
import AVFoundation

public enum Resampler {
    /// Wandelt mono Float32 von `from` Hz nach `to` Hz um.
    /// Die Ausgabelänge beträgt `round(count × to ÷ from)`.
    public static func resample(_ samples: [Float], from: Double, to: Double) throws -> [Float] {
        guard from > 0, to > 0 else { throw AudioOutError.invalidParameter("Abtastrate \(from) → \(to)") }
        if samples.isEmpty || from == to { return samples }

        guard
            let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: from, channels: 1, interleaved: false),
            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: to, channels: 1, interleaved: false),
            let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw AudioOutError.converterFailed("Format \(from) → \(to) nicht unterstützt") }

        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
        converter.primeMethod = .none

        let inCount = AVAudioFrameCount(samples.count)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inCount) else {
            throw AudioOutError.converterFailed("Eingabepuffer")
        }
        inBuffer.frameLength = inCount
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }

        let expected = Int((Double(samples.count) * to / from).rounded())
        let capacity = AVAudioFrameCount(expected + 4096)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw AudioOutError.converterFailed("Ausgabepuffer")
        }

        // Der Block liefert die Eingabe genau einmal, danach „Ende des Stroms“.
        final class Feed: @unchecked Sendable { var done = false }
        let feed = Feed()
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if feed.done {
                outStatus.pointee = .endOfStream
                return nil
            }
            feed.done = true
            outStatus.pointee = .haveData
            return inBuffer
        }
        if status == .error {
            throw AudioOutError.converterFailed(error?.localizedDescription ?? "unbekannt")
        }
        let produced = Int(outBuffer.frameLength)
        var out = [Float](repeating: 0, count: produced)
        out.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: outBuffer.floatChannelData![0], count: produced)
        }
        // Auf die erwartete Länge bringen (der Wandler liefert gelegentlich ein paar Samples mehr/weniger).
        if out.count > expected { out.removeLast(out.count - expected) }
        if out.count < expected { out.append(contentsOf: repeatElement(0, count: expected - out.count)) }
        return out
    }
}
