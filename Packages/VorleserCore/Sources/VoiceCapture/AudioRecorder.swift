// Aufnahme vom Mikrofon (AVAudioEngine) mit Pegelwerten für die Anzeige.
// Das Mikrofon selbst lässt sich nicht automatisch testen; die Logik drumherum (Pegel,
// Prüfung, Ablauf) schon. Die App spricht nur das Protokoll `AudioRecording` an.
import AVFoundation
import Foundation
import os

public enum MicrophonePermission: Sendable, Equatable {
    case notDetermined, granted, denied
}

/// Eine fertige Aufnahme: mono, Float32, Rate des Eingabegeräts.
public struct RecordedAudio: Sendable, Equatable {
    public var samples: [Float]
    public var sampleRate: Double
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum RecordingError: Error, Sendable, Equatable, CustomStringConvertible {
    case noInputDevice
    case engineFailed(String)
    case notRecording

    public var description: String {
        switch self {
        case .noInputDevice: "Es ist kein Mikrofon vorhanden."
        case .engineFailed(let s): "Die Aufnahme konnte nicht starten: \(s)"
        case .notRecording: "Es läuft keine Aufnahme."
        }
    }
}

public protocol AudioRecording: AnyObject, Sendable {
    var permission: MicrophonePermission { get }
    /// Fragt beim ersten Mal nach (Systemdialog), sonst gibt es den Stand zurück.
    func requestPermission() async -> MicrophonePermission
    /// Beginnt die Aufnahme. Der Strom liefert Pegelwerte und endet bei `stop()`/`cancel()`.
    func start() throws -> AsyncStream<LevelReading>
    /// Beendet und liefert alles, was aufgenommen wurde.
    func stop() -> RecordedAudio
    /// Verwirft die Aufnahme.
    func cancel()
}

/// Echte Aufnahme. Der Tap läuft auf dem Audio-Thread; geteilt wird nur über das Schloss.
public final class MicrophoneRecorder: AudioRecording, @unchecked Sendable {
    private struct State {
        var samples: [Float] = []
        var rate: Double = 0
        var continuation: AsyncStream<LevelReading>.Continuation?
        var running = false
        var sinceLastReading = 0
    }

    private let engine = AVAudioEngine()
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Sicherheitsgrenze: danach werden keine Samples mehr gesammelt.
    public let maxSeconds: Double
    /// So oft kommt ein Pegelwert (Sekunden).
    public let readingInterval: Double

    public init(maxSeconds: Double = 60, readingInterval: Double = 0.06) {
        self.maxSeconds = maxSeconds
        self.readingInterval = readingInterval
    }

    public var permission: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    public func requestPermission() async -> MicrophonePermission {
        if permission == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .audio) }
        return permission
    }

    public func start() throws -> AsyncStream<LevelReading> {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecordingError.noInputDevice }
        let (stream, continuation) = AsyncStream.makeStream(of: LevelReading.self, bufferingPolicy: .bufferingNewest(1))
        state.withLock {
            $0 = State()
            $0.rate = format.sampleRate
            $0.continuation = continuation
            $0.running = true
        }
        let rate = format.sampleRate
        let limit = Int(maxSeconds * rate)
        let hop = max(1, Int(readingInterval * rate))
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [state] buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            let channels = Int(buffer.format.channelCount)
            var mono = [Float](repeating: 0, count: n)
            for c in 0..<channels {
                let p = data[c]
                for i in 0..<n { mono[i] += p[i] }
            }
            if channels > 1 {
                let k = 1 / Float(channels)
                for i in 0..<n { mono[i] *= k }
            }
            let level = LevelMeter.measure(mono)
            let block = mono
            state.withLock { s in
                guard s.running else { return }
                if s.samples.count < limit { s.samples.append(contentsOf: block) }
                s.sinceLastReading += n
                if s.sinceLastReading >= hop {
                    s.sinceLastReading = 0
                    s.continuation?.yield(LevelReading(
                        rmsDBFS: level.rmsDBFS, peakDBFS: level.peakDBFS,
                        elapsedSeconds: Double(s.samples.count) / rate))
                }
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            state.withLock { $0.running = false; $0.continuation?.finish(); $0.continuation = nil }
            throw RecordingError.engineFailed(error.localizedDescription)
        }
        return stream
    }

    public func stop() -> RecordedAudio {
        halt()
        return state.withLock { s in
            let out = RecordedAudio(samples: s.samples, sampleRate: s.rate)
            s.samples = []
            return out
        }
    }

    public func cancel() {
        halt()
        state.withLock { $0.samples = [] }
    }

    private func halt() {
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        state.withLock { s in
            s.running = false
            s.continuation?.finish()
            s.continuation = nil
        }
    }
}
