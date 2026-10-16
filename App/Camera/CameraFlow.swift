// Ablauf „Vom iPhone fotografieren“: iPhone suchen → Live-Bild → Foto → „Gut lesbar?“ → „Noch eine Seite?“ →
// lesen → Schritt 2. Ein Gedanke pro Bildschirm, immer „Zurück“, Abbrechen fragt nach (PLAN.md §3).
// Alles Logische steht hier und ist mit einer Kamera-Attrappe testbar.
import DocumentImport
import Foundation
import Observation
import Projects

/// Liest die Fotos zu einem Dokument. Austauschbar für Tests.
typealias PhotoReader = @Sendable (_ urls: [URL], _ progress: @escaping @Sendable (Int, Int) -> Void) async throws -> ImportResult

@MainActor
@Observable
final class CameraFlow {
    enum Step: Equatable {
        /// Kein iPhone gefunden: freundlicher Hinweis, sucht weiter.
        case waiting
        /// Kamera nicht erlaubt.
        case denied
        /// Live-Bild und großer Aufnahmeknopf.
        case shoot
        /// Das eben aufgenommene Foto: „Ist die Seite gut zu lesen?“
        case review
        /// „Noch eine Seite?“
        case more
        /// Die Fotos werden gelesen.
        case reading
        /// Einige Seiten ließen sich nicht lesen (1-basierte Nummern).
        case partial([Int])
    }

    private(set) var step: Step = .waiting
    /// Aufgenommene Seiten als Bilddateien, in der Reihenfolge der Aufnahme.
    private(set) var pages: [URL] = []
    /// Nach einem Fehler beim Aufnehmen.
    private(set) var captureFailed = false
    private(set) var isCapturing = false
    private(set) var readingPage = 0
    /// Frage „Fotos verwerfen?“ ist offen.
    var confirmDiscard = false
    /// Fertig gelesen; `AppModel` übernimmt das Ergebnis.
    private(set) var result: ImportResult?

    let camera: any PhotoCamera
    private let reader: PhotoReader
    private let directory: URL
    private var searchTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    /// Wird mit dem Ergebnis gerufen, wenn die Oma „Fertig“ gewählt hat und gelesen wurde.
    var onFinished: ((ImportResult, [URL]) -> Void)?
    var onFailed: ((String) -> Void)?
    var onExit: (() -> Void)?
    /// Pause zwischen zwei Suchläufen nach dem iPhone.
    var searchInterval: Duration = .seconds(1)

    init(
        camera: any PhotoCamera, reader: @escaping PhotoReader,
        directory: URL = FileManager.default.temporaryDirectory.appending(path: "Vorleser-Fotos-\(UUID().uuidString)", directoryHint: .isDirectory)
    ) {
        self.camera = camera
        self.reader = reader
        self.directory = directory
    }

    var pageCount: Int { pages.count }
    var lastPage: URL? { pages.last }

    // MARK: Start und Suche

    func start() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            guard let self else { return }
            if await camera.authorization() == .denied { step = .denied; return }
            await connect()
        }
    }

    /// Sucht, bis ein iPhone da ist, und startet dann das Live-Bild.
    private func connect() async {
        while !Task.isCancelled {
            if camera.phoneAvailable() {
                do {
                    try await camera.startSession()
                    if step == .waiting { step = .shoot }
                    return
                } catch {
                    AppLog.warning("camera", "Kamera startet nicht: \(error)")
                }
            } else if pages.isEmpty {
                step = .waiting
            }
            try? await Task.sleep(for: searchInterval)
        }
    }

    // MARK: Aufnehmen

    func takePhoto() {
        guard step == .shoot, !isCapturing else { return }
        isCapturing = true
        captureFailed = false
        Task {
            defer { isCapturing = false }
            do {
                let data = try await camera.capture()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appending(path: String(format: "Seite-%02d.jpg", pages.count + 1))
                try data.write(to: url)
                pages.append(url)
                step = .review
            } catch {
                AppLog.warning("camera", "Foto fehlgeschlagen: \(error)")
                if camera.phoneAvailable() {
                    captureFailed = true
                } else {
                    // iPhone weggelegt oder abgeschaltet: zurück zur Suche.
                    camera.stopSession()
                    step = .waiting
                    start()
                }
            }
        }
    }

    /// „Nochmal fotografieren“: das letzte Foto verwerfen.
    func retakeLast() {
        if let url = pages.popLast() { try? FileManager.default.removeItem(at: url) }
        captureFailed = false
        step = .shoot
    }

    /// „Ja, weiter“ nach dem Prüfen.
    func acceptLast() { step = .more }

    func anotherPage() {
        captureFailed = false
        step = .shoot
    }

    // MARK: Lesen

    func finish() {
        guard !pages.isEmpty else { return }
        camera.stopSession()
        step = .reading
        readingPage = 1
        let urls = pages
        let reader = reader
        readTask?.cancel()
        let progress: @Sendable (Int, Int) -> Void = { [weak self] n, _ in
            Task { @MainActor in self?.readingPage = n }
        }
        readTask = Task { [weak self] in
            do {
                let r = try await reader(urls, progress)
                guard let self, !Task.isCancelled else { return }
                self.result = r
                if r.unreadablePages.isEmpty {
                    self.handOver()
                } else {
                    self.step = .partial(r.unreadablePages.map { $0 + 1 })
                }
            } catch is CancellationError {
                return
            } catch DocumentImportError.empty {
                AppLog.warning("camera", "Fotos ohne lesbaren Text (\(urls.count) Seiten)")
                self?.cleanup()
                self?.onFailed?("camera.problem.noText")
            } catch {
                AppLog.error("camera", "Fotos lesen fehlgeschlagen: \(error)")
                self?.cleanup()
                self?.onFailed?("problem.unreadable")
            }
        }
    }

    /// „Trotzdem weiter“ nach der Meldung über unlesbare Seiten.
    func continueAnyway() { handOver() }

    /// „Neu fotografieren“: alles verwerfen und von vorn anfangen.
    func startOver() {
        for url in pages { try? FileManager.default.removeItem(at: url) }
        pages = []
        result = nil
        step = .waiting
        start()
    }

    private func handOver() {
        guard let result else { return }
        onFinished?(result, pages)
    }

    // MARK: Zurück und Abbrechen

    /// „Zurück“: ohne Fotos sofort zum Start, sonst erst nachfragen.
    func back() {
        switch step {
        case .reading:
            confirmDiscard = true
        case .more, .review, .partial:
            confirmDiscard = true
        case .shoot where !pages.isEmpty:
            // Zurück vom Live-Bild geht zu „Noch eine Seite?“ (nichts geht verloren).
            step = .more
        default:
            exit()
        }
    }

    /// „Ja, verwerfen“.
    func discardAll() {
        confirmDiscard = false
        exit()
    }

    func exit() {
        searchTask?.cancel()
        readTask?.cancel()
        camera.stopSession()
        cleanup()
        onExit?()
    }

    /// Löscht die Fotodateien (nach dem Lesen sind sie nicht mehr nötig).
    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
        pages = []
    }

    /// Räumt auf, ohne `onExit` zu rufen (Fotos sind übernommen).
    func finishAndClean() {
        searchTask?.cancel()
        camera.stopSession()
        cleanup()
    }
}
