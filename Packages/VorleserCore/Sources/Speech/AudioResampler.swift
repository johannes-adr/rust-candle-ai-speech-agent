import AudioOut
import AVFoundation

/// Fehler beim Aufbereiten von Audio.
public enum SpeechAudioError: Error, Sendable, Equatable {
    case conversionFailed(String)
    case emptyAudio
}

/// Hilfen für Referenz-Audio. Das Resampling selbst macht `AudioOut.Resampler`
/// (bandbegrenzt, AVAudioConverter); Speech hängt dafür von AudioOut ab.
///
/// Lehre aus dem alten Rust-Projekt: Referenz-Audio immer auf die Rate
/// bringen, die das Modell meldet. Nie hart kodieren, nie linear interpolieren.
public enum AudioResampler {
    /// Liest eine Audiodatei als Mono-Float (Kanäle werden gemittelt) samt Rate.
    public static func readMono(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            throw SpeechAudioError.emptyAudio
        }
        try file.read(into: buffer)
        // AVAudioFile liefert bei manchen Dateien weniger als angefragt; nachlesen.
        while buffer.frameLength < frames, file.framePosition < file.length {
            guard let rest = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames - buffer.frameLength) else { break }
            try file.read(into: rest)
            if rest.frameLength == 0 { break }
            let ch = Int(format.channelCount)
            for c in 0..<ch {
                (buffer.floatChannelData![c] + Int(buffer.frameLength)).update(from: rest.floatChannelData![c], count: Int(rest.frameLength))
            }
            buffer.frameLength += rest.frameLength
        }
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
        return try Resampler.resample(cut, from: rate, to: targetRate)
    }
}
