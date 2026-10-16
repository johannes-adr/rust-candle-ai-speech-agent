import AVFoundation

/// Fehler beim Aufbereiten von Audio.
public enum SpeechAudioError: Error, Sendable, Equatable {
    case converterUnavailable
    case conversionFailed(String)
    case emptyAudio
}

/// Bandbegrenztes Resampling (AVAudioConverter) und Hilfen für Referenz-Audio.
///
/// Lehre aus dem alten Rust-Projekt: Referenz-Audio immer auf die Rate
/// bringen, die das Modell meldet. Nie hart kodieren, nie linear interpolieren.
public enum AudioResampler {
    /// Wandelt Mono-Float-Samples von `sourceRate` nach `targetRate`.
    public static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { throw SpeechAudioError.emptyAudio }
        if abs(sourceRate - targetRate) < 0.5 { return samples }
        guard let inFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat)
        else { throw SpeechAudioError.converterUnavailable }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering

        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw SpeechAudioError.conversionFailed("Eingabepuffer")
        }
        inBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        let ratio = targetRate / sourceRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else {
            throw SpeechAudioError.conversionFailed("Ausgabepuffer")
        }
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let input = inBuffer
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed { outStatus.pointee = .endOfStream; return nil }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        if status == .error { throw SpeechAudioError.conversionFailed(error?.localizedDescription ?? "unbekannt") }
        let n = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: n))
    }

    /// Liest eine Audiodatei als Mono-Float (Kanäle werden gemittelt) samt Rate.
    public static func readMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SpeechAudioError.emptyAudio
        }
        try file.read(into: buffer)
        let channels = Int(format.channelCount)
        let n = Int(buffer.frameLength)
        var mono = [Float](repeating: 0, count: n)
        guard let data = buffer.floatChannelData else { throw SpeechAudioError.conversionFailed("kein Float-Puffer") }
        for c in 0..<channels {
            let p = data[c]
            for i in 0..<n { mono[i] += p[i] }
        }
        if channels > 1 {
            let k = 1 / Float(channels)
            for i in 0..<n { mono[i] *= k }
        }
        return (mono, format.sampleRate)
    }

    /// Referenz laden, auf `maxSeconds` kürzen und auf `targetRate` bringen.
    public static func loadReference(url: URL, targetRate: Double, maxSeconds: Double = 15) throws -> [Float] {
        let (raw, rate) = try readMono(url: url)
        let cut = Array(raw.prefix(Int(maxSeconds * rate)))
        return try resample(cut, from: rate, to: targetRate)
    }
}
