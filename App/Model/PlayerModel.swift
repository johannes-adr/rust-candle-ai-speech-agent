// Eingebauter Player: großes Play/Pause, „30 s zurück“, merkt die Position je Hörbuch.
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class PlayerModel {
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var isLoaded = false

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var key: String?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// Lädt die Datei und springt an die gemerkte Position (nicht ans Ende).
    func load(url: URL, key: String) {
        stop()
        self.key = key
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            player = p
            duration = p.duration
            let saved = defaults.double(forKey: Self.defaultsKey(key))
            position = saved > 0 && saved < p.duration - 2 ? saved : 0
            p.currentTime = position
            isLoaded = true
        } catch {
            player = nil
            isLoaded = false
            duration = 0
            position = 0
        }
    }

    func toggle() {
        guard let p = player else { return }
        if p.isPlaying { pause() } else { play() }
    }

    func play() {
        guard let p = player else { return }
        if p.currentTime >= p.duration - 0.1 { p.currentTime = 0 }
        p.play()
        isPlaying = true
        startTimer()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
        sync()
        remember()
    }

    func back30() {
        guard let p = player else { return }
        p.currentTime = max(0, p.currentTime - 30)
        sync()
        remember()
    }

    /// Beim Verlassen des Bildschirms.
    func stop() {
        player?.stop()
        timer?.invalidate()
        remember()
        isPlaying = false
        player = nil
        isLoaded = false
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard let p = player else { return }
        sync()
        if !p.isPlaying {
            isPlaying = false
            timer?.invalidate()
            if p.currentTime >= p.duration - 0.3 { p.currentTime = 0; position = 0 }
            remember()
        } else if Int(p.currentTime) % 5 == 0 {
            remember()
        }
    }

    private func sync() {
        guard let p = player else { return }
        position = p.currentTime
    }

    private func remember() {
        guard let key, let p = player else { return }
        defaults.set(p.currentTime, forKey: Self.defaultsKey(key))
    }

    nonisolated static func defaultsKey(_ key: String) -> String { "playerPosition.\(key)" }
}
