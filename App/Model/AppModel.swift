// Zustand und Ablauf der Oberfläche ①→④. Enthält nur Bedienlogik; Arbeit macht das Package
// (DocumentImport, TextPrep, Projects) und der AudiobookService.
import AppKit
import DocumentImport
import Foundation
import Observation
import Projects
import TextPrep

enum Screen: Equatable {
    case start
    case typeText
    case importing
    case voice
    case comingSoon
    case working
    case done
    /// Freundliche Fehlermeldung (Schlüssel aus Localizable.xcstrings).
    case problem(String)
}

enum Tempo: String, CaseIterable, Identifiable {
    case slower, normal, faster
    var id: String { rawValue }
    var factor: Double {
        switch self {
        case .slower: 0.9
        case .normal: 1.0
        case .faster: 1.1
        }
    }
    var titleKey: String { "tempo.\(rawValue)" }
}

enum WorkPhase: Equatable { case preparing, working, finishing }

/// Was die Nutzerin bis Schritt 2 ausgewählt hat.
struct Draft {
    var title: String
    var document: TextDocument
    var sourceHash: String
    var sourceKind: String
    var sourceData: Data?
    var sourceExtension: String?
    var detection: LanguageDetection?
    var language: Language
    var voiceID: String?
    var style: VoiceStyle = .calm
    var tempo: Tempo = .normal
}

@MainActor
@Observable
final class AppModel {
    var screen: Screen = .start
    var typedText = ""
    var draft: Draft?
    var projects: [ProjectSummary] = []

    // Overlays (eigene große Dialoge statt kleiner Systemfenster)
    var showHelp = false
    var showLanguagePicker = false
    var confirmStop = false

    // Arbeit
    var phase: WorkPhase = .preparing
    var progress = AudiobookProgress(fraction: 0)
    var result: AudiobookResult?
    var sampleMessage: String?

    let settings: AppSettings
    let player = PlayerModel()
    let library: VoiceLibrary
    private(set) var store: ProjectStore
    private(set) var service: any AudiobookService
    private let makeService: @MainActor (ProjectStore, VoiceLibrary) -> any AudiobookService

    private var importTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var activity: NSObjectProtocol?

    init(
        settings: AppSettings = AppSettings(),
        library: VoiceLibrary = VoiceLibrary(),
        storeRoot: URL? = nil,
        makeService: @escaping @MainActor (ProjectStore, VoiceLibrary) -> any AudiobookService = { store, lib in
            PreviewAudiobookService(store: store, library: lib, simulatedSeconds: AppModel.previewSeconds)
        }
    ) {
        self.settings = settings
        self.library = library
        self.makeService = makeService
        let store = ProjectStore(
            root: storeRoot ?? ProjectStore.defaultRoot, outputDirectory: settings.effectiveOutputDirectory)
        self.store = store
        self.service = makeService(store, library)
        Task { await refreshProjects() }
    }

    nonisolated static var previewSeconds: Double {
        ProcessInfo.processInfo.environment["VORLESER_PREVIEW_SECONDS"].flatMap(Double.init) ?? 5
    }

    /// Nach Änderung des Ablageorts in den Einstellungen.
    func rebuildStore() {
        store = ProjectStore(root: store.rootDirectory, outputDirectory: settings.effectiveOutputDirectory)
        service = makeService(store, library)
        Task { await refreshProjects() }
    }

    func refreshProjects() async { projects = await store.list() }

    // MARK: Schritt 1: Quelle wählen

    func goHome() {
        importTask?.cancel()
        player.stop()
        Task { await service.stopSample() }
        draft = nil
        typedText = ""
        showLanguagePicker = false
        confirmStop = false
        screen = .start
        Task { await refreshProjects() }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "start.openPanelMessage")
        panel.prompt = String(localized: "start.openPanelPrompt")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.importFile(url) }
        }
    }

    func importFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        guard DocumentImporter.supportedExtensions.contains(ext) else {
            screen = .problem("problem.unsupported")
            return
        }
        screen = .importing
        importTask?.cancel()
        importTask = Task {
            do {
                let data = try Data(contentsOf: url)
                let imported = try await DocumentImporter().importDetailed(at: url, languageHint: nil)
                try Task.checkCancellation()
                let kind = ext == "pdf" ? "pdf" : (["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext) ? "image" : "document")
                let title = url.deletingPathExtension().lastPathComponent
                makeDraft(
                    title: title, document: imported.document, sourceHash: SourceHash.hex(of: data),
                    sourceKind: kind, sourceData: data, sourceExtension: ext)
            } catch is CancellationError {
                return
            } catch DocumentImportError.empty {
                screen = .problem("problem.noText")
            } catch DocumentImportError.passwordProtected {
                screen = .problem("problem.locked")
            } catch {
                screen = .problem("problem.unreadable")
            }
        }
    }

    func submitTypedText() {
        let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let doc = DocumentImporter().importText(text)
        guard !doc.blocks.isEmpty else {
            screen = .problem("problem.noText")
            return
        }
        makeDraft(
            title: Self.title(fromText: text), document: doc, sourceHash: SourceHash.hex(of: text),
            sourceKind: "text", sourceData: Data(text.utf8), sourceExtension: "txt")
    }

    /// Kurzer Titel aus den ersten Wörtern.
    nonisolated static func title(fromText text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
        let trimmed = String(words.prefix(48)).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        return trimmed.isEmpty ? String(localized: "title.fallback") : trimmed
    }

    private func makeDraft(
        title: String, document: TextDocument, sourceHash: String, sourceKind: String,
        sourceData: Data?, sourceExtension: String?
    ) {
        let text = document.blocks.map {
            switch $0 {
            case .heading(_, let t): t
            case .paragraph(let p): p
            }
        }.joined(separator: "\n")
        let detection = LanguageDetector().detect(text)
        let language = detection?.language ?? Self.uiDefaultLanguage
        var d = Draft(
            title: title, document: document, sourceHash: sourceHash, sourceKind: sourceKind,
            sourceData: sourceData, sourceExtension: sourceExtension, detection: detection, language: language)
        d.voiceID = library.voices(for: language).first?.id
        draft = d
        // Unsichere Erkennung: Sprachauswahl sofort zeigen.
        showLanguagePicker = detection?.isUncertain ?? true
        screen = .voice
    }

    nonisolated static var uiDefaultLanguage: Language {
        Locale.preferredLanguages.first.flatMap { $0.hasPrefix("pt") ? Language.pt : Language(rawValue: String($0.prefix(2))) } ?? .de
    }

    // MARK: Schritt 2: Stimme

    func setLanguage(_ language: Language) {
        guard var d = draft else { return }
        d.language = language
        d.voiceID = library.voices(for: language).first?.id
        draft = d
        showLanguagePicker = false
    }

    func selectVoice(_ id: String) { draft?.voiceID = id }
    func selectStyle(_ style: VoiceStyle) { draft?.style = style }
    func selectTempo(_ tempo: Tempo) { draft?.tempo = tempo }

    func playSample(voiceID: String) {
        guard let style = draft?.style else { return }
        sampleMessage = nil
        Task {
            do { try await service.playSample(voiceID: voiceID, style: style.rawValue) }
            catch { sampleMessage = "voice.sampleMissing" }
        }
    }

    func hasSample(voiceID: String) -> Bool {
        guard let style = draft?.style else { return false }
        return service.hasSample(voiceID: voiceID, style: style.rawValue)
    }

    func chooseOwnVoice() { screen = .comingSoon }

    // MARK: Schritt 3: Arbeit

    func startWork() {
        guard let d = draft, let voiceID = d.voiceID else { return }
        let voiceName = library.voice(id: voiceID)?.name ?? ""
        let job = AudiobookJob(
            title: d.title, document: d.document, sourceHash: d.sourceHash, sourceKind: d.sourceKind,
            sourceData: d.sourceData, sourceExtension: d.sourceExtension, language: d.language,
            voiceID: voiceID, voiceName: voiceName, style: d.style.rawValue, tempo: d.tempo.factor,
            resumeProjectID: nil)
        run(job)
    }

    private func run(_ job: AudiobookJob) {
        phase = .preparing
        progress = AudiobookProgress(fraction: 0)
        result = nil
        screen = .working
        beginKeepAwake()
        let stream = service.start(job)
        workTask?.cancel()
        workTask = Task {
            for await event in stream { handle(event) }
            endKeepAwake()
        }
    }

    private func handle(_ event: AudiobookEvent) {
        switch event {
        case .preparing:
            phase = .preparing
        case .progress(let p):
            phase = .working
            progress = p
        case .finishing:
            phase = .finishing
        case .finished(let r):
            result = r
            NSSound(named: "Glass")?.play()
            showFinished(r)
            Task { await refreshProjects() }
        case .failed(let key):
            screen = .problem(key)
            Task { await refreshProjects() }
        case .stopped:
            goHome()
        }
    }

    /// „Anhalten“ nach Rückfrage: Fertiges bleibt gespeichert, später weitermachen.
    func stopWork() async {
        confirmStop = false
        await service.cancel()
    }

    func listenAhead() {
        Task { try? await service.listenAhead() }
    }

    private func beginKeepAwake() {
        guard activity == nil else { return }
        // Der Mac schläft nicht ein, der Bildschirm darf aus.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Hörbuch wird erstellt")
    }

    private func endKeepAwake() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    // MARK: Schritt 4 und Liste „Meine Hörbücher“

    private func showFinished(_ r: AudiobookResult) {
        player.load(url: r.fileURL, key: r.projectID.uuidString)
        screen = .done
    }

    func open(_ summary: ProjectSummary) {
        if summary.state == .finished {
            let url = store.outputURL(title: summary.title)
            guard FileManager.default.fileExists(atPath: url.path) else {
                screen = .problem("problem.fileMissing")
                return
            }
            let r = AudiobookResult(
                projectID: summary.id, title: summary.title, fileURL: url, durationSeconds: summary.duration)
            result = r
            showFinished(r)
        } else {
            // Unfertig: dort weitermachen, wo es aufgehört hat.
            Task {
                guard let p = try? await store.load(id: summary.id) else {
                    screen = .problem("problem.unreadable")
                    return
                }
                let job = AudiobookJob(
                    title: p.title, document: TextDocument(blocks: []), sourceHash: p.sourceHash,
                    sourceKind: p.sourceKind, sourceData: nil, sourceExtension: nil, language: p.language,
                    voiceID: p.voiceID, voiceName: library.voice(id: p.voiceID)?.name ?? "", style: p.style,
                    tempo: p.tempo, resumeProjectID: p.id)
                run(job)
            }
        }
    }

    func showInFinder() {
        guard let url = result?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Anzeige

    /// „Musik › Vorgelesen“ bzw. Ordnername bei eigenem Ablageort.
    var savedInDescription: String {
        settings.usesDefaultOutputDirectory
            ? String(localized: "done.defaultFolder")
            : settings.effectiveOutputDirectory.lastPathComponent
    }
}
