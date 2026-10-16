// Tempoänderung ohne Tonhöhenänderung: AVAudioUnitTimePitch, offline gerendert
// (AVAudioEngine im Manual-Rendering-Modus, braucht keine Audio-Hardware).
import AVFoundation

public enum TempoShifter {
    public static let allowedRange: ClosedRange<Double> = 0.8...1.2

    /// Ändert das Tempo um `tempo` (1,0 = unverändert, 1,2 = 20 % schneller).
    /// Die Ausgabelänge beträgt etwa `count ÷ tempo`.
    public static func apply(_ samples: [Float], sampleRate: Double, tempo: Double) throws -> [Float] {
        guard allowedRange.contains(tempo) else {
            throw AudioOutError.invalidParameter("Tempo \(tempo) außerhalb \(allowedRange)")
        }
        if samples.isEmpty || abs(tempo - 1.0) < 0.001 { return samples }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
        else { throw AudioOutError.engineFailed("Format") }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let timePitch = AVAudioUnitTimePitch()
        timePitch.rate = Float(tempo)
        timePitch.pitch = 0
        engine.attach(player)
        engine.attach(timePitch)
        engine.connect(player, to: timePitch, format: format)
        engine.connect(timePitch, to: engine.mainMixerNode, format: format)

        let maxFrames: AVAudioFrameCount = 4096
        do {
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: maxFrames)
            try engine.start()
        } catch {
            throw AudioOutError.engineFailed(error.localizedDescription)
        }
        defer { engine.stop() }

        // Eingabe plus etwas Stille hinten, damit der Time-Pitch-Puffer vollständig ausläuft.
        let tail = Int(0.3 * sampleRate)
        let total = samples.count + tail
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(total)) else {
            throw AudioOutError.engineFailed("Eingabepuffer")
        }
        inBuffer.frameLength = AVAudioFrameCount(total)
        let ch = inBuffer.floatChannelData![0]
        samples.withUnsafeBufferPointer { ch.update(from: $0.baseAddress!, count: samples.count) }
        (ch + samples.count).update(repeating: 0, count: tail)

        player.scheduleBuffer(inBuffer, completionHandler: nil)
        player.play()

        let latency = Int((timePitch.latency * sampleRate).rounded())
        let expected = Int((Double(samples.count) / tempo).rounded())
        let wanted = expected + latency
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: maxFrames) else {
            throw AudioOutError.engineFailed("Ausgabepuffer")
        }
        var out = [Float]()
        out.reserveCapacity(wanted)
        while out.count < wanted {
            let want = AVAudioFrameCount(min(Int(maxFrames), wanted - out.count))
            let status: AVAudioEngineManualRenderingStatus
            do { status = try engine.renderOffline(want, to: outBuffer) } catch {
                throw AudioOutError.engineFailed(error.localizedDescription)
            }
            switch status {
            case .success:
                let n = Int(outBuffer.frameLength)
                out.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: n))
            case .insufficientDataFromInputNode:
                // Player liefert noch nichts; weiter rendern.
                let n = Int(outBuffer.frameLength)
                out.append(contentsOf: UnsafeBufferPointer(start: outBuffer.floatChannelData![0], count: n))
                if n == 0 { throw AudioOutError.engineFailed("Keine Daten vom Player") }
            case .cannotDoInCurrentContext:
                continue
            case .error:
                throw AudioOutError.engineFailed("renderOffline lieferte einen Fehler")
            @unknown default:
                throw AudioOutError.engineFailed("unbekannter Status")
            }
        }
        // Anlaufverzögerung des Time-Pitch-Geräts abschneiden.
        if latency > 0, out.count > latency { out.removeFirst(latency) }
        if out.count > expected { out.removeLast(out.count - expected) }
        return out
    }
}
