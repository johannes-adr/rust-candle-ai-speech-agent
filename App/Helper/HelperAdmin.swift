// Logik hinter den Helfer-Einstellungen (ohne Oberfläche, damit testbar): Stimmenliste, Hörbücherliste,
// Protokolltext.
import AVFoundation
import Foundation
import Observation
import Projects
import TextPrep
import VorleserSpeech

// MARK: Stimmen

enum VoiceOrigin: Equatable { case builtIn, recorded, designed }

struct HelperVoiceEntry: Identifiable, Equatable {
    var id: String
    var name: String
    var language: Language
    var origin: VoiceOrigin
    var createdAt: Date?
    var durationSeconds: Double?
    /// Nur eigene und beschriebene Stimmen lassen sich umbenennen und löschen; eingebaute nie.
    var isEditable: Bool { origin != .builtIn }
}

enum HelperVoiceError: Error, Equatable { case notEditable }

@MainActor
@Observable
final class HelperVoicesModel {
    private(set) var entries: [HelperVoiceEntry] = []
    private(set) var playingID: String?
    private let library: VoiceLibrary
    private var player: AVAudioPlayer?

    init(library: VoiceLibrary) {
        self.library = library
        reload()
    }

    func reload() {
        var out: [HelperVoiceEntry] = library.store.allPresets.map {
            HelperVoiceEntry(id: $0.id, name: $0.name, language: $0.language, origin: .builtIn)
        }
        for info in library.store.custom?.list() ?? [] {
            out.append(HelperVoiceEntry(
                id: info.id, name: info.name, language: info.language,
                origin: info.kind == .designed ? .designed : .recorded,
                createdAt: info.createdAt, durationSeconds: info.durationSeconds))
        }
        entries = out
    }

    func rename(id: String, to name: String) throws {
        guard entry(id)?.isEditable == true, let store = library.store.custom else { throw HelperVoiceError.notEditable }
        try store.rename(id: id, to: name)
        reload()
    }

    func delete(id: String) throws {
        guard entry(id)?.isEditable == true, let store = library.store.custom else { throw HelperVoiceError.notEditable }
        if playingID == id { stopSample() }
        try store.delete(id: id)
        reload()
    }

    func entry(_ id: String) -> HelperVoiceEntry? { entries.first { $0.id == id } }

    /// Aufnahme, die als Probe gespielt wird: eingebaute Stimmen im ruhigen Stil, sonst der erste vorhandene.
    func sampleURL(for id: String) -> URL? {
        guard let e = entry(id) else { return nil }
        if e.isEditable { return library.store.custom?.audioURL(id: id) }
        let styles = library.store.availableStyles(voiceID: id)
        guard let style = styles.contains("calm") ? "calm" : styles.first else { return nil }
        return library.store.referenceURL(voiceID: id, style: style)
    }

    func hasSample(_ id: String) -> Bool { sampleURL(for: id) != nil }

    func toggleSample(id: String) {
        if playingID == id { stopSample(); return }
        stopSample()
        guard let url = sampleURL(for: id), let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.play()
        player = p
        playingID = id
        let length = p.duration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(length + 0.2))
            if self?.playingID == id { self?.playingID = nil }
        }
    }

    func stopSample() {
        player?.stop()
        player = nil
        playingID = nil
    }
}

// MARK: Hörbücher

@MainActor
@Observable
final class HelperBooksModel {
    private(set) var rows: [ProjectOverview] = []
    private(set) var message: String?
    private let store: ProjectStore

    init(store: ProjectStore) { self.store = store }

    func reload() async { rows = await store.overview() }

    /// Löscht die Zwischendateien eines fertigen Projekts. Liefert freigegebene Bytes.
    @discardableResult
    func cleanIntermediates(id: UUID) async -> Int64? {
        do {
            let freed = try await store.cleanIntermediates(id: id)
            AppLog.info("helper", "Zwischendateien aufgeräumt: \(freed) Bytes freigegeben")
            await reload()
            return freed
        } catch {
            AppLog.warning("helper", "Aufräumen nicht möglich: \(error)")
            await reload()
            return nil
        }
    }

    /// Löscht das Projekt (Manifest, Quelle, Abschnitte). Die fertige Datei im Ablageordner bleibt.
    func delete(id: UUID) async {
        do { try await store.delete(id: id) } catch { AppLog.warning("helper", "Löschen fehlgeschlagen: \(error)") }
        await reload()
    }

    /// Summe der Zwischendateien aller aufräumbaren Hörbücher.
    var reclaimableBytes: Int64 { rows.filter(\.canCleanIntermediates).reduce(0) { $0 + $1.usage.intermediates } }
}

// MARK: Protokoll

enum HelperProtocol {
    /// Kopfzeilen: App-Version, System, Gerät.
    static func header(bundle: Bundle = .main, process: ProcessInfo = .processInfo) -> [String] {
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return [
            "Vorleser \(version) (\(build))",
            "macOS \(process.operatingSystemVersionString)",
            "Arbeitsspeicher \(process.physicalMemory / 1_073_741_824) GB",
        ]
    }

    /// Text zum Kopieren: Auffälligkeiten der letzten Läufe plus Ausschnitt der Protokolldatei.
    static func report(store: ProjectStore, log: EventLog, lastProjects: Int = 10, logLines: Int = 60) async -> String {
        let problems = await store.recentProblems(limit: lastProjects)
        return ProblemProtocol.render(problems, header: header(), log: log.tail(lines: logLines))
    }
}
