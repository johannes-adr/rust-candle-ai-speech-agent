// Ablauf „Stimme beschreiben“: Wunsch → Warten → Vorschlag wählen → Name → zurück zu ②.
// Nur Bedienlogik; die Arbeit macht `VoiceDesignService` (Package `Pipeline`).
import AVFoundation
import Foundation
import Observation
import Pipeline
import Speech
import TextPrep

/// Spielt Vorschläge und Proben ab. Genau ein Klang zugleich.
@MainActor
final class PreviewPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = PreviewPlayer()
    private var player: AVAudioPlayer?
    private var onFinish: (() -> Void)?

    func play(_ url: URL, onFinish: @escaping () -> Void = {}) {
        stop()
        guard let p = try? AVAudioPlayer(contentsOf: url) else { onFinish(); return }
        p.delegate = self
        self.onFinish = onFinish
        player = p
        p.play()
    }

    func stop() {
        player?.stop()
        player = nil
        let done = onFinish
        onFinish = nil
        done?()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            let done = self.onFinish
            self.onFinish = nil
            done?()
        }
    }
}

enum DescribeStep: Equatable {
    case wish
    case working
    case choose
    case name
    /// Schlüssel der Fehlermeldung
    case failed(String)
}

@MainActor
@Observable
final class DescribeVoiceModel {
    var step: DescribeStep = .wish
    var wishText = ""
    var proposals: [DesignedProposal] = []
    var chosen: Int?
    var name = ""
    var stage: DesignStage = .preparing
    /// Index des Vorschlags, der gerade läuft.
    var playing: Int?
    var confirmCancel = false
    var dictationUnavailable = false

    private(set) var readingLanguage: Language = .de
    private(set) var uiLanguage: Language = .de
    private let service: any VoiceDesignService
    private let readAloud: (Language) -> String?
    private var task: Task<Void, Never>?

    /// Zurück zu ② (ohne neue Stimme).
    var onExit: () -> Void = {}
    /// Gespeichert: ② mit der neuen Stimme.
    var onSaved: (Voice) -> Void = { _ in }

    init(service: any VoiceDesignService, readAloud: @escaping (Language) -> String? = { ReadAloudText.text(for: $0) }) {
        self.service = service
        self.readAloud = readAloud
    }

    func begin(readingLanguage: Language, uiLanguage: Language) {
        self.readingLanguage = readingLanguage
        self.uiLanguage = uiLanguage
        step = .wish
        proposals = []
        chosen = nil
        playing = nil
        confirmCancel = false
        dictationUnavailable = false
    }

    var canTry: Bool { !wishText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Fortschritt 0 … 1 für den Balken (grob nach Abschnitt).
    var fraction: Double {
        switch stage {
        case .preparing: 0.06
        case let .proposal(i, n): 0.1 + 0.85 * Double(i - 1) / Double(max(n, 1)) + 0.05
        case .finishing: 0.97
        }
    }

    // MARK: Wunsch → Vorschläge

    func tryVoices() {
        guard canTry, let text = readAloud(readingLanguage) else {
            if canTry { step = .failed("describeVoice.failed.text") }
            return
        }
        stopPlaying()
        proposals = []
        chosen = nil
        stage = .preparing
        step = .working
        let wish = VoiceWish(
            description: wishText.trimmingCharacters(in: .whitespacesAndNewlines),
            descriptionLanguage: uiLanguage, readingLanguage: readingLanguage)
        let service = self.service
        // Ein abgebrochener Lauf muss erst fertig entladen haben, bevor der nächste das Modell lädt.
        let previous = task
        previous?.cancel()
        task = Task {
            await previous?.value
            do {
                let result = try await service.propose(wish: wish, referenceText: text) { [weak self] stage in
                    Task { @MainActor in self?.stage = stage }
                }
                try Task.checkCancellation()
                proposals = result
                step = .choose
            } catch is CancellationError {
                return
            } catch DesignServiceError.modelMissing {
                step = .failed("describeVoice.failed.noModel")
            } catch {
                step = .failed("describeVoice.failed.text")
            }
        }
    }

    /// Abbrechen nach Rückfrage; die Arbeit hört bald auf, danach ist das Modell wieder frei.
    func cancelWork() {
        confirmCancel = false
        task?.cancel()
        step = .wish
    }

    // MARK: Anhören und wählen

    func togglePlay(_ proposal: DesignedProposal) {
        if playing == proposal.index {
            stopPlaying()
            return
        }
        playing = proposal.index
        PreviewPlayer.shared.play(proposal.previewURL) { [weak self] in
            Task { @MainActor in if self?.playing == proposal.index { self?.playing = nil } }
        }
    }

    func stopPlaying() {
        playing = nil
        PreviewPlayer.shared.stop()
    }

    func take(_ proposal: DesignedProposal) {
        stopPlaying()
        chosen = proposal.index
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = String(localized: "describeVoice.name.default") }
        step = .name
    }

    func save() {
        guard let index = chosen else { return }
        let service = self.service
        let name = self.name
        Task {
            do {
                let voice = try await service.save(proposal: index, name: name)
                onSaved(voice)
            } catch {
                step = .failed("describeVoice.failed.text")
            }
        }
    }

    // MARK: Zurück

    /// Eine Stufe zurück; vom Wunsch aus zu ②.
    func back() {
        stopPlaying()
        switch step {
        case .wish: onExit()
        case .working: confirmCancel = true
        case .choose, .failed: step = .wish
        case .name: step = .choose
        }
    }

    func leave() {
        stopPlaying()
        task?.cancel()
        onExit()
    }
}
