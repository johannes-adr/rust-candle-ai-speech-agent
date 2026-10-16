// Ein- und Ausgabetypen der Vorlese-Pipeline. Reine Werte, damit sie über Actor-Grenzen gehen.
import AudioOut
import Foundation
import Projects
import Speech
import TextPrep

/// Woher der Text kommt.
public enum SynthesisSource: Sendable {
    /// PDF, Text, Word … (`DocumentImporter`). Die Quelle wird im Projekt mitgespeichert.
    case file(URL)
    /// Eingefügter Text.
    case text(String)
    /// Schon importiert (die App hat den Import in Schritt ① gemacht).
    case document(TextDocument, sourceHash: String, kind: String)
}

public struct SynthesisRequest: Sendable {
    public var title: String?
    public var source: SynthesisSource
    /// `nil` = aus dem Text erkennen.
    public var language: Language?
    public var voice: Voice
    /// Stil-Kennung (`calm` …), nur für Fortsetzen-Zuordnung und Anzeige.
    public var style: String?
    /// 0,8 … 1,2
    public var tempo: Double
    /// Zieldatei; `nil` = `ProjectStore.outputURL(title:)`.
    public var outputURL: URL?
    /// Gesetzt: genau dieses Projekt fortsetzen, die Quelle wird ignoriert.
    public var resumeProjectID: UUID?
    /// Bei `.document`: Seitenzahl der Quelle (für „Seite x von y“).
    public var pageCount: Int?
    /// Bei `.document`: Originaldatei, die im Projekt abgelegt werden soll.
    public var sourceData: Data?
    public var sourceExtension: String?

    public init(
        title: String? = nil, source: SynthesisSource, language: Language? = nil, voice: Voice,
        style: String? = nil, tempo: Double = 1.0, outputURL: URL? = nil, resumeProjectID: UUID? = nil,
        pageCount: Int? = nil, sourceData: Data? = nil, sourceExtension: String? = nil
    ) {
        self.title = title
        self.source = source
        self.language = language
        self.voice = voice
        self.style = style
        self.tempo = tempo
        self.outputURL = outputURL
        self.resumeProjectID = resumeProjectID
        self.pageCount = pageCount
        self.sourceData = sourceData
        self.sourceExtension = sourceExtension
    }

    /// Schlüssel im Projekt-Manifest: Stimme plus Stil, damit ein anderer Stil kein altes
    /// Projekt fortsetzt.
    var voiceKey: String { style.map { "\(voice.id)@\($0)" } ?? voice.id }
}

public struct SynthesisConfig: Sendable {
    /// Wiederholungen mit neuem Seed bei Verdacht (PLAN §4.4).
    public var maxRetries = 2
    /// Nach so vielen Sekunden Leerlauf nach einem Auftrag wird das Modell entladen.
    public var idleUnloadSeconds: Double = 60
    public var targetLUFS: Double = -18
    public var pauses = PauseDurations()
    /// Qualitätsprüfung; `expectedCharsPerSecond` wird je Sprache aus `SpeechRate` gesetzt.
    public var qc = ChunkQCConfig()
    /// Abschnitte unter dieser Zeichenzahl werden nicht auf Dauer geprüft (Überschriften).
    public var minCharsForDurationCheck = 10
    /// Bricht ab, wenn so viele Abschnitte hintereinander gar kein Audio liefern.
    public var maxConsecutiveFailures = 3
    /// Wärmezustand; bei `.serious` oder schlimmer folgt vor jedem Abschnitt eine kurze Pause.
    public var thermalState: @Sendable () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    public var thermalPauseSeconds: Double = 3
    /// Schlafsperre während der Arbeit (`ProcessInfo.beginActivity`).
    public var preventSleep = true

    public init() {}
}

/// Ein auffälliger Versuch oder ein auffällig behaltener Abschnitt.
public struct SuspiciousChunk: Sendable, Equatable {
    public var chunkIndex: Int
    /// 0 = erster Versuch.
    public var attempt: Int
    public var issues: [QCIssue]
    public var durationRatio: Double?
    /// Es folgt eine Wiederholung mit neuem Seed.
    public var willRetry: Bool
    /// Nach den Wiederholungen behalten und markiert (nur beim letzten Versuch wahr).
    public var kept: Bool
    public var message: String?
}

public struct SynthesisProgress: Sendable, Equatable {
    public var chunkIndex: Int
    public var chunksDone: Int
    public var chunksTotal: Int
    /// 0…1, nach Zeichen gewichtet.
    public var fraction: Double
    public var currentPage: Int?
    public var totalPages: Int?
    public var remainingSeconds: Double?
    /// Dauer des Abschnitts in Sekunden (nach dem Kürzen der Stille).
    public var audioSeconds: Double
    /// Rechenzeit ÷ Audiodauer dieses Abschnitts (alle Versuche).
    public var realTimeFactor: Double
    public var attempts: Int
    public var isSuspicious: Bool
    /// Fertiger Abschnitt als CAF (für „sofort vorlesen“).
    public var fileURL: URL
    public var sampleRate: Double
}

public enum SynthesisStage: String, Sendable, Equatable {
    case importing, detectingLanguage, planning, loadingModel, preparingVoice, synthesizing, exporting
}

public struct SynthesisResult: Sendable, Equatable {
    public var projectID: UUID
    public var title: String
    public var fileURL: URL
    public var chapterFiles: [URL]
    public var durationSeconds: Double
    public var chunkCount: Int
    /// Wurde ein angefangenes Projekt fortgesetzt?
    public var resumed: Bool
    /// Abschnitte, die in diesem Lauf erzeugt wurden (ohne Fortgesetztes).
    public var chunksSynthesized: Int
    public var retryCount: Int
    public var suspicious: [SuspiciousChunk]
    /// Abschnitte ohne verwertbares Audio (fehlen in der MP3).
    public var failedChunks: [Int]
    /// Rechenzeit der Sprachausgabe in diesem Lauf und die dabei erzeugte Audiodauer.
    public var computeSeconds: Double
    public var synthesizedAudioSeconds: Double
    public var language: Language
    public var measuredLUFS: Double?
}

public enum SynthesisFailure: Error, Sendable, Equatable {
    case noText
    case importFailed(String)
    case languageUnknown
    case modelMissing(String)
    case engineFailed(String)
    case noAudio
    case exportFailed(String)
    case storeFailed(String)
    case busy

    /// Schlüssel in `Localizable.xcstrings` der App, nie Rohtext.
    public var reasonKey: String {
        switch self {
        case .noText, .importFailed, .languageUnknown: "problem.noText"
        default: "problem.generic"
        }
    }

    public var message: String {
        switch self {
        case .noText: "Im Dokument wurde kein Text gefunden."
        case let .importFailed(s): "Import fehlgeschlagen: \(s)"
        case .languageUnknown: "Die Sprache wurde nicht erkannt."
        case let .modelMissing(s): "Modell fehlt: \(s)"
        case let .engineFailed(s): "Sprachausgabe fehlgeschlagen: \(s)"
        case .noAudio: "Es ist kein Audio entstanden."
        case let .exportFailed(s): "MP3 konnte nicht geschrieben werden: \(s)"
        case let .storeFailed(s): "Projekt konnte nicht gespeichert werden: \(s)"
        case .busy: "Es läuft schon ein Auftrag."
        }
    }
}

public enum SynthesisEvent: Sendable {
    case stage(SynthesisStage)
    /// Projekt steht fest (neu oder fortgesetzt).
    case projectReady(projectID: UUID, resumed: Bool, chunksTotal: Int, chunksAlreadyDone: Int, language: Language)
    /// Ein Abschnitt ist fertig (auch der erste, für „sofort vorlesen“).
    case chunkDone(SynthesisProgress)
    case suspicious(SuspiciousChunk)
    /// Pause wegen Hitze des Macs.
    case coolingDown(seconds: Double)
    case paused
    case resumed
    /// MP3 wird geschrieben, 0…1.
    case exporting(fraction: Double)
    case finished(SynthesisResult)
    /// Angehalten oder abgebrochen; alles Fertige bleibt für „Fortsetzen“ erhalten.
    case stopped
    case failed(SynthesisFailure)
}
