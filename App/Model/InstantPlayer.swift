// „Sofort vorlesen“ bei kurzen Texten: spielt die fertigen Abschnitte nacheinander ab,
// sobald der erste da ist, mit denselben Pausen wie später in der MP3.
import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class InstantPlayer {
    private(set) var isActive = false

    private var queue: [(url: URL, pause: Double)] = []
    private var player: AVAudioPlayer?
    private var runner: Task<Void, Never>?
    private var inputFinished = false
    private var tempo: Double = 1

    /// Neuer Auftrag: alte Wiedergabe verwerfen.
    func start(tempo: Double) {
        stop()
        self.tempo = tempo
        inputFinished = false
        isActive = true
        runner = Task { await loop() }
    }

    func enqueue(url: URL, pauseAfterSeconds: Double) {
        guard isActive else { return }
        queue.append((url, pauseAfterSeconds))
    }

    /// Es kommt nichts mehr nach; läuft aus, wenn die Warteschlange leer ist.
    func finishInput() { inputFinished = true }

    func stop() {
        runner?.cancel()
        runner = nil
        player?.stop()
        player = nil
        queue.removeAll()
        isActive = false
    }

    /// Wartet, bis alles abgespielt ist (oder `stop` aufgerufen wurde).
    func waitUntilDrained() async {
        while isActive { try? await Task.sleep(for: .milliseconds(150)) }
    }

    private func loop() async {
        while !Task.isCancelled {
            if queue.isEmpty {
                if inputFinished { break }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            let item = queue.removeFirst()
            guard let p = try? AVAudioPlayer(contentsOf: item.url) else { continue }
            p.enableRate = true
            p.rate = Float(tempo)
            player = p
            p.play()
            while p.isPlaying, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(80)) }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(item.pause / tempo))
        }
        if !Task.isCancelled {
            player = nil
            isActive = false
        }
    }
}
