// Ablauf „Meine eigene Stimme“ (PLAN §3): Lesetext → Aufnehmen → 3-2-1 → Pegelanzeige →
// Anhören → „So behalten“/„Nochmal“ → Hinweise → Zustimmung und Name → zurück zu ②.
// Nur Bedienlogik; Aufnahme, Prüfung und Speichern machen die Packages `VoiceCapture` und `Speech`.
import AVFoundation
import Foundation
import Observation
import VorleserSpeech
import TextPrep
import VoiceCapture

enum OwnVoiceStep: Equatable {
    /// Lesetext steht da, roter Knopf „Aufnehmen“.
    case ready
    /// Mikrofon verweigert: Weg zu den Systemeinstellungen erklären.
    case micDenied
    case countdown(Int)
    case recording
    case analyzing
    case review
    /// Häkchen (Pflicht) und Name.
    case consent
    case saving
    /// Freundliche Fehlermeldung (Schlüssel).
    case failed(String)
}

@MainActor
@Observable
final class OwnVoiceFlow {
    private(set) var step: OwnVoiceStep = .ready
    private(set) var level = LevelReading(rmsDBFS: LevelMeter.floorDBFS, peakDBFS: LevelMeter.floorDBFS, elapsedSeconds: 0)
    private(set) var issues: [RecordingIssue] = []
    private(set) var readingResult: ReadingCheckResult?
    private(set) var isPlaying = false
    var consent = false
    var name: String

    let language: Language
    /// Der feste Lesetext. Er ist auch das Transkript für die Stimme; die Oma tippt nichts.
    let readingText: String

    /// Länger als das nimmt die Aufnahme nicht auf (Sicherheitsgrenze, Lesetext dauert ca. 12 s).
    nonisolated static let autoStopSeconds = 25.0

    private let recorder: any AudioRecording
    private let transcriber: any SpeechTranscribing
    private let store: RecordedVoiceStore
    private let pause: @Sendable (Duration) async -> Void
    private let onSaved: (Voice) -> Void
    private let onCancel: () -> Void
    private var cleaned: [Float] = []
    private var cleanedRate: Double = 0
    private var flowTask: Task<Void, Never>?
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?

    init(
        language: Language, readingText: String, defaultName: String,
        recorder: any AudioRecording = MicrophoneRecorder(),
        transcriber: any SpeechTranscribing = SystemTranscriber(),
        store: RecordedVoiceStore = RecordedVoiceStore(),
        pause: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        onSaved: @escaping (Voice) -> Void, onCancel: @escaping () -> Void
    ) {
        self.language = language
        self.readingText = readingText
        self.name = defaultName
        self.recorder = recorder
        self.transcriber = transcriber
        self.store = store
        self.pause = pause
        self.onSaved = onSaved
        self.onCancel = onCancel
        if recorder.permission == .denied { step = .micDenied }
    }

    // MARK: Anzeige

    /// Hinweise für die Nutzerin (Schlüssel), ohne Doppelte, wichtigste zuerst.
    var hintKeys: [String] {
        var keys: [String] = []
        for i in issues where !keys.contains(i.hintKey) { keys.append(i.hintKey) }
        if let k = readingResult?.hintKey, !keys.contains(k) { keys.append(k) }
        return keys
    }

    /// Kann die Aufnahme behalten werden? Bei Stille oder zu kurzer Aufnahme nicht.
    var canKeep: Bool { !issues.contains { $0.isBlocking } }
    /// Alles in Ordnung: kein Hinweis.
    var isClean: Bool { hintKeys.isEmpty }
    var canSave: Bool { consent && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: Aufnehmen

    /// Roter Knopf.
    func tapRecord() {
        guard step == .ready else { return }
        flowTask?.cancel()
        flowTask = Task { [weak self] in await self?.runCountdownAndRecord() }
    }

    private func runCountdownAndRecord() async {
        let permission = await recorder.requestPermission()
        guard !Task.isCancelled else { return }
        guard permission == .granted else { step = .micDenied; return }
        for n in [3, 2, 1] {
            step = .countdown(n)
            await pause(.seconds(1))
            guard !Task.isCancelled else { return }
        }
        do {
            let levels = try recorder.start()
            level = LevelReading(rmsDBFS: LevelMeter.floorDBFS, peakDBFS: LevelMeter.floorDBFS, elapsedSeconds: 0)
            step = .recording
            for await reading in levels {
                level = reading
                if reading.elapsedSeconds >= Self.autoStopSeconds { break }
            }
            if !Task.isCancelled, step == .recording { await finishRecording() }
        } catch RecordingError.noInputDevice {
            step = .failed("ownVoice.error.noMic")
        } catch {
            step = .failed("ownVoice.error.start")
        }
    }

    /// Knopf „Fertig“.
    func tapDone() {
        guard step == .recording else { return }
        Task { await finishRecording() }
    }

    private func finishRecording() async {
        guard step == .recording else { return }
        let audio = recorder.stop()
        step = .analyzing
        flowTask?.cancel()
        let (clean, report) = RecordingAnalyzer.analyze(samples: audio.samples, sampleRate: audio.sampleRate)
        cleaned = clean
        cleanedRate = audio.sampleRate
        issues = report.issues
        readingResult = nil
        // Spracherkennung nur, wenn die Aufnahme grundsätzlich brauchbar ist.
        if report.hasBlockingIssue || clean.isEmpty {
            step = .review
            return
        }
        var result = await ReadingChecker.check(
            samples: clean, sampleRate: audio.sampleRate, expectedText: readingText, language: language,
            transcriber: transcriber)
        if case .unchecked(.notAuthorized) = result, SystemTranscriber.legacyAuthorizationNotDetermined {
            if await SystemTranscriber.requestLegacyAuthorization() {
                result = await ReadingChecker.check(
                    samples: clean, sampleRate: audio.sampleRate, expectedText: readingText, language: language,
                    transcriber: transcriber)
            }
        }
        readingResult = result
        step = .review
    }

    // MARK: Anhören, behalten, nochmal

    func togglePlayback() {
        if isPlaying { stopPlayback(); return }
        guard !cleaned.isEmpty else { return }
        do {
            let url = FileManager.default.temporaryDirectory.appending(path: "vorleser-vorschau.wav")
            try AudioFiles.writeWAV(cleaned, sampleRate: cleanedRate, to: url)
            let p = try AVAudioPlayer(contentsOf: url)
            p.play()
            player = p
            isPlaying = true
            playbackTask?.cancel()
            let duration = p.duration
            playbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration + 0.2))
                if !Task.isCancelled { self?.isPlaying = false }
            }
        } catch {
            isPlaying = false
        }
    }

    private func stopPlayback() {
        playbackTask?.cancel()
        player?.stop()
        player = nil
        isPlaying = false
    }

    /// „Nochmal“: Aufnahme verwerfen.
    func retry() {
        flowTask?.cancel()
        stopPlayback()
        recorder.cancel()
        cleaned = []
        issues = []
        readingResult = nil
        step = recorder.permission == .denied ? .micDenied : .ready
    }

    /// „So behalten“ (oder „Trotzdem behalten“).
    func keep() {
        guard step == .review, canKeep else { return }
        stopPlayback()
        step = .consent
    }

    // MARK: Speichern

    /// Nur mit Häkchen. Das Transkript ist immer der feste Lesetext.
    func save() {
        guard step == .consent, canSave else { return }
        step = .saving
        let samples = cleaned, rate = cleanedRate, text = readingText, lang = language
        let chosenName = name, store = store
        Task { [weak self] in
            do {
                let voice = try store.save(
                    samples: samples, sampleRate: rate, transcript: text, name: chosenName, language: lang,
                    consent: true, source: "recording", transcriptSource: "reading")
                self?.onSaved(voice)
            } catch {
                self?.step = .failed("ownVoice.error.save")
            }
        }
    }

    // MARK: Zurück und Mikrofon-Hilfe

    /// Immer möglich. Geht einen Schritt zurück; vom ersten Bildschirm zu ②.
    func back() {
        switch step {
        case .ready, .micDenied, .failed:
            flowTask?.cancel()
            stopPlayback()
            recorder.cancel()
            onCancel()
        case .countdown, .recording, .analyzing, .review:
            retry()
        case .consent:
            consent = false
            step = .review
        case .saving:
            break
        }
    }

    /// Nach Änderung in den Systemeinstellungen noch einmal versuchen.
    func recheckMicrophone() {
        if recorder.permission == .denied { step = .micDenied } else { step = .ready }
    }
}
