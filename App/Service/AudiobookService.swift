// Schnittstelle zwischen Oberfläche und Hörbuch-Erzeugung.
// Die App kennt nur dieses Protokoll. Dahinter steht LiveAudiobookService (Package `Pipeline`);
// PreviewAudiobookService ist die Attrappe für Entwicklung (Debug, VORLESER_PREVIEW=1).
import Foundation
import TextPrep

/// Alles, was die Erzeugung braucht. Reine Werte, damit sie über Actor-Grenzen gehen.
struct AudiobookJob: Sendable {
    var title: String
    var document: TextDocument
    /// SHA-256 der Quelle (Datei oder Text), für „Gleiches Dokument schon angefangen“.
    var sourceHash: String
    /// "pdf", "text", "image" …
    var sourceKind: String
    var sourceData: Data?
    var sourceExtension: String?
    var language: Language
    var voiceID: String
    var voiceName: String
    /// Stil-Kennung (`calm`, `happy`, `fairytale`, `factual`), bei eigener Stimme nil.
    var style: String?
    /// 0,8 … 1,2
    var tempo: Double
    /// Gesetzt: dort weitermachen, `document` wird ignoriert.
    var resumeProjectID: UUID?
    /// Bei mehreren Kapiteln zusätzlich eine Datei je Kapitel (Einstellung des Helfers).
    var writeChapterFiles = true
}

struct AudiobookProgress: Sendable, Equatable {
    /// 0 … 1
    var fraction: Double
    var currentPage: Int?
    var totalPages: Int?
    var remainingSeconds: Double?
}

struct AudiobookResult: Sendable, Equatable {
    var projectID: UUID
    var title: String
    var fileURL: URL
    var durationSeconds: Double
}

enum AudiobookEvent: Sendable, Equatable {
    /// Text wird vorbereitet (noch kein Fortschritt messbar).
    case preparing
    case progress(AudiobookProgress)
    /// Ein Abschnitt ist fertig und liegt als Audiodatei bereit (für „sofort vorlesen“).
    case chunkReady(fileURL: URL, pauseAfterSeconds: Double)
    /// Die MP3 wird geschrieben.
    case finishing
    case finished(AudiobookResult)
    /// `reason` ist ein Schlüssel aus Localizable.xcstrings, nie Rohtext des Fehlers.
    case failed(reasonKey: String)
    /// Vom Nutzer angehalten; das Projekt bleibt erhalten und kann fortgesetzt werden.
    case stopped
}

protocol AudiobookService: Sendable {
    /// Startet die Erzeugung. Der Strom endet nach `.finished`, `.failed` oder `.stopped`.
    func start(_ job: AudiobookJob) -> AsyncStream<AudiobookEvent>
    /// Hält zwischendurch an, ohne den Strom zu beenden.
    func pause() async
    func resume() async
    /// Bricht ab; bereits Fertiges bleibt auf der Platte (Fortsetzen möglich).
    func cancel() async
    /// Gibt es eine Hörprobe für diese Stimme und diesen Stil?
    func hasSample(voiceID: String, style: String) -> Bool
    /// Spielt die Hörprobe ab (sofort, ohne Modell).
    func playSample(voiceID: String, style: String) async throws
    func stopSample() async
    /// „Schon mal reinhören“: spielt das bisher Fertige ab.
    func listenAhead() async throws
}
