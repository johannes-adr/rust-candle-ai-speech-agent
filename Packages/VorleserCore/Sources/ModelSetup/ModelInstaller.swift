import CryptoKit
import Foundation

public struct InstallProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable { case checking, importing, downloading, verifying, finishing }

    public var phase: Phase
    public var bytesDone: Int64
    public var bytesTotal: Int64
    /// Bytes pro Sekunde, gemittelt über die letzten Sekunden (nur Download); 0 = unbekannt.
    public var bytesPerSecond: Double
    /// Geschätzte Restzeit für den Rest des Downloads, `nil` solange unbekannt.
    public var remainingSeconds: Double?
    public var currentFile: String?
    public var currentModel: ModelRef?

    public init(phase: Phase, bytesDone: Int64, bytesTotal: Int64, bytesPerSecond: Double = 0,
                remainingSeconds: Double? = nil, currentFile: String? = nil, currentModel: ModelRef? = nil) {
        self.phase = phase
        self.bytesDone = bytesDone
        self.bytesTotal = bytesTotal
        self.bytesPerSecond = bytesPerSecond
        self.remainingSeconds = remainingSeconds
        self.currentFile = currentFile
        self.currentModel = currentModel
    }

    public var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 1 }
    public var percent: Int { Int((fraction * 100).rounded(.down)) }
}

public enum InstallEvent: Sendable, Equatable {
    case progress(InstallProgress)
    /// Ein Modell ist fertig und geprüft.
    case modelReady(ModelRef)
}

public enum InstallError: Error, Equatable, Sendable, LocalizedError {
    case notEnoughSpace(needed: Int64, available: Int64)
    /// Keine Internetverbindung (nie erreicht oder unterwegs verloren).
    case offline
    case server(status: Int)
    case checksumMismatch(path: String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .notEnoughSpace(needed, available): "Zu wenig Platz: \(needed) Bytes nötig, \(available) frei."
        case .offline: "Keine Internetverbindung."
        case let .server(status): "Der Server antwortete mit Fehler \(status)."
        case let .checksumMismatch(path): "Prüfsumme stimmt nicht: \(path)"
        case let .io(text): text
        }
    }
}

/// Was ein Aufruf von `install` tun würde (für „Was wird geladen?“ im Assistenten).
public struct InstallPlan: Sendable, Equatable {
    /// Gesamtgröße aller Modelle des Plans.
    public var totalBytes: Int64
    /// Schon vorhanden (fertig oder im Zwischenordner).
    public var presentBytes: Int64
    /// Kommt aus dem Hugging-Face-Cache, kostet auf APFS keinen Platz und kein Netz.
    public var importBytes: Int64
    /// Muss aus dem Netz geladen werden.
    public var downloadBytes: Int64
    /// Neuer Platzbedarf auf dem Datenträger (Download plus nicht klonbarer Import).
    public var space: SpaceCheck

    public init(totalBytes: Int64, presentBytes: Int64, importBytes: Int64, downloadBytes: Int64, space: SpaceCheck) {
        self.totalBytes = totalBytes
        self.presentBytes = presentBytes
        self.importBytes = importBytes
        self.downloadBytes = downloadBytes
        self.space = space
    }

    public var isComplete: Bool { totalBytes == presentBytes }
}

/// Lädt Modelle in den `ModelStore`: aus dem Hugging-Face-Cache, wenn dort derselbe Snapshot liegt,
/// sonst per HTTPS. Fortsetzbar, mit Prüfsumme je Datei, atomar.
public struct ModelInstaller: Sendable {
    public let store: ModelStore
    public let cache: HFCacheImporter?
    public let baseURL: URL
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let freeSpace: @Sendable (URL) -> Int64

    public init(
        store: ModelStore = .standard,
        cache: HFCacheImporter? = HFCacheImporter(),
        baseURL: URL = URL(string: "https://huggingface.co")!,
        sessionConfiguration: @escaping @Sendable () -> URLSessionConfiguration = {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30
            c.waitsForConnectivity = false
            return c
        },
        freeSpace: @escaping @Sendable (URL) -> Int64 = SpaceCheck.freeBytes(at:)
    ) {
        self.store = store
        self.cache = cache
        self.baseURL = baseURL
        self.makeConfiguration = sessionConfiguration
        self.freeSpace = freeSpace
    }

    // MARK: Plan

    public func plan(_ manifests: [ModelManifest]) -> InstallPlan {
        var total: Int64 = 0, present: Int64 = 0, imported: Int64 = 0, download: Int64 = 0, copyCost: Int64 = 0
        for m in manifests {
            total += m.totalBytes
            if store.status(of: m).isReady { present += m.totalBytes; continue }
            let staging = store.stagingDirectory(for: m.ref)
            for f in m.files {
                let have = ModelStore.fileSize(staging.appendingPathComponent(f.path))
                if have == f.size { present += f.size; continue }
                let part = max(0, ModelStore.fileSize(staging.appendingPathComponent(f.path + ".part")))
                if let src = cache?.candidate(for: f, of: m.ref) {
                    imported += f.size
                    if !HFCacheImporter.sameVolume(src, staging) { copyCost += f.size }
                } else {
                    present += part
                    download += f.size - part
                }
            }
        }
        let needed = download + copyCost
        return InstallPlan(
            totalBytes: total, presentBytes: present, importBytes: imported, downloadBytes: download,
            space: SpaceCheck(needed: needed, available: freeSpace(store.root)))
    }

    // MARK: Installieren

    /// Lädt alle noch nicht fertigen Modelle nacheinander. Abbrechen = die Task des Konsumenten abbrechen
    /// (Pause); ein erneuter Aufruf macht an derselben Stelle weiter. `repair` prüft vorhandene Dateien mit SHA-256.
    public func install(_ manifests: [ModelManifest], repair: Bool = false) -> AsyncThrowingStream<InstallEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream<InstallEvent, Error>.makeStream()
        let task = Task {
            do {
                try await run(manifests, repair: repair, continuation)
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: CancellationError())
            } catch {
                continuation.finish(throwing: Self.map(error))
            }
        }
        continuation.onTermination = { @Sendable _ in task.cancel() }
        return stream
    }

    private func run(_ manifests: [ModelManifest], repair: Bool,
                     _ out: AsyncThrowingStream<InstallEvent, Error>.Continuation) async throws {
        let plan = plan(manifests)
        guard plan.space.isEnough else {
            throw InstallError.notEnoughSpace(needed: plan.space.needed + plan.space.buffer, available: plan.space.available)
        }
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        // Bei `repair` zählt „bereit“ erst nach voller SHA-256-Prüfung (gleiche Größe, anderer Inhalt).
        var readyRefs = Set<ModelRef>()
        var present = plan.presentBytes
        for m in manifests where store.status(of: m).isReady {
            if repair, try store.verify(m) != .ready {
                present -= m.totalBytes // `plan` zählte es schon als vorhanden
            } else {
                readyRefs.insert(m.ref)
            }
        }
        var tracker = ProgressTracker(
            total: manifests.reduce(0) { $0 + $1.totalBytes }, done: present, downloadTotal: plan.downloadBytes)
        out.yield(.progress(tracker.snapshot(.checking, force: true)!))

        for manifest in manifests {
            if readyRefs.contains(manifest.ref) { out.yield(.modelReady(manifest.ref)); continue }
            try await installOne(manifest, repair: repair, tracker: &tracker, out)
            out.yield(.modelReady(manifest.ref))
        }
    }

    private func installOne(_ manifest: ModelManifest, repair: Bool, tracker: inout ProgressTracker,
                            _ out: AsyncThrowingStream<InstallEvent, Error>.Continuation) async throws {
        let fm = FileManager.default
        let ref = manifest.ref
        let staging = store.stagingDirectory(for: ref)
        let final = store.directory(for: ref)
        var repair = repair
        var movedCorrupt = false // diese Dateien zählte `plan` noch nicht als vorhanden

        // Beschädigter Zielordner: als Zwischenordner weiterverwenden, alles neu prüfen.
        if fm.fileExists(atPath: final.path) {
            if fm.fileExists(atPath: staging.path) {
                try fm.removeItem(at: final)
            } else {
                try fm.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: final, to: staging)
                try? fm.removeItem(at: staging.appendingPathComponent(ModelStore.markerName))
                repair = true
                movedCorrupt = true
            }
        }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        for file in manifest.files {
            try Task.checkCancellation()
            let staged = staging.appendingPathComponent(file.path)
            let existing = ModelStore.fileSize(staged)

            if existing == file.size {
                if repair {
                    tracker.phase = .verifying; tracker.file = file.path; tracker.model = ref
                    let hash = try Checksum.sha256(ofFileAt: staged) { _ in }
                    if hash == file.sha256 {
                        if movedCorrupt { tracker.add(file.size, download: false) }
                        continue
                    }
                    try fm.removeItem(at: staged)
                    if !movedCorrupt { tracker.add(-file.size, download: false) }
                } else {
                    continue // schon in `plan.presentBytes` gezählt
                }
            } else if existing >= 0 {
                try fm.removeItem(at: staged) // halb kopiert o. Ä.
            }

            tracker.model = ref
            tracker.file = file.path
            if let src = cache?.candidate(for: file, of: ref) {
                tracker.phase = .importing
                if try importFromCache(src, file: file, to: staged, tracker: &tracker, out) { continue }
            }
            tracker.phase = .downloading
            try await download(file, ref: ref, staging: staging, tracker: &tracker, out)
        }

        // Abschluss: Prüfmarke, dann ein einziges rename an den Zielort.
        tracker.phase = .finishing
        if let p = tracker.snapshot(.finishing, force: true) { out.yield(.progress(p)) }
        let marker = ReadyMarker(repo: ref.repo, revision: ref.revision, verifiedAt: Date())
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(marker).write(to: staging.appendingPathComponent(ModelStore.markerName), options: .atomic)
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: staging, to: final)
    }

    /// Prüft die Quelle im Cache, klont sie in den Zwischenordner. `false`, wenn die Quelle beschädigt ist
    /// (dann wird normal geladen).
    private func importFromCache(_ source: URL, file: ModelManifest.File, to staged: URL,
                                 tracker: inout ProgressTracker,
                                 _ out: AsyncThrowingStream<InstallEvent, Error>.Continuation) throws -> Bool {
        var last: Int64 = 0
        var local = tracker
        let hash = try Checksum.sha256(ofFileAt: source) { total in
            local.add(total - last, download: false)
            last = total
            if let p = local.snapshot(.importing) { out.yield(.progress(p)) }
        }
        tracker = local
        guard hash == file.sha256 else {
            tracker.add(-last, download: false) // Zähler zurück, Datei wird geladen
            return false
        }
        try HFCacheImporter.cloneOrCopy(from: source, to: staged)
        return true
    }

    private func download(_ file: ModelManifest.File, ref: ModelRef, staging: URL,
                          tracker: inout ProgressTracker,
                          _ out: AsyncThrowingStream<InstallEvent, Error>.Continuation) async throws {
        let fm = FileManager.default
        let staged = staging.appendingPathComponent(file.path)
        let part = staging.appendingPathComponent(file.path + ".part")
        try fm.createDirectory(at: part.deletingLastPathComponent(), withIntermediateDirectories: true)

        var offset = max(0, ModelStore.fileSize(part))
        if offset > file.size { try fm.removeItem(at: part); offset = 0 }

        // Bereits Geladenes neu hashen, damit am Ende die Gesamtsumme stimmt.
        var hasher = SHA256()
        if offset > 0 {
            let handle = try FileHandle(forReadingFrom: part)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                hasher.update(data: chunk)
            }
        }
        if !fm.fileExists(atPath: part.path) { fm.createFile(atPath: part.path, contents: nil) }

        if offset < file.size {
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try handle.seekToEnd()
            let url = file.path.split(separator: "/").reduce(
                baseURL.appendingPathComponent(ref.repo).appendingPathComponent("resolve").appendingPathComponent(ref.revision)
            ) { $0.appendingPathComponent(String($1)) }

            for try await event in FileDownload.stream(url: url, offset: offset, configuration: makeConfiguration()) {
                try Task.checkCancellation()
                switch event {
                case let .response(status):
                    if status == 200, offset > 0 {
                        // Server ignoriert Range: von vorn.
                        try handle.truncate(atOffset: 0)
                        try handle.seek(toOffset: 0)
                        tracker.add(-offset, download: false)
                        offset = 0
                        hasher = SHA256()
                    } else if status == 416 {
                        try? fm.removeItem(at: part)
                        throw InstallError.server(status: status)
                    } else if !(200..<300).contains(status) {
                        throw InstallError.server(status: status)
                    }
                case let .data(data):
                    try handle.write(contentsOf: data)
                    hasher.update(data: data)
                    offset += Int64(data.count)
                    tracker.add(Int64(data.count), download: true)
                    if let p = tracker.snapshot(.downloading) { out.yield(.progress(p)) }
                }
            }
        }

        // Ein Abbruch (Pause) beendet den Strom ohne Fehler: Teildatei unbedingt behalten.
        try Task.checkCancellation()
        // Verbindung vorzeitig zu, ohne Fehlermeldung: wie ein Netzabbruch behandeln, Teildatei bleibt.
        if offset < file.size { throw URLError(.networkConnectionLost) }
        tracker.phase = .verifying
        guard offset == file.size, Checksum.hex(hasher.finalize()) == file.sha256 else {
            try? fm.removeItem(at: part)
            tracker.add(-offset, download: false)
            throw InstallError.checksumMismatch(path: file.path)
        }
        try fm.moveItem(at: part, to: staged)
    }

    static func map(_ error: Error) -> Error {
        if let e = error as? InstallError { return e }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
                return InstallError.offline
            default: return InstallError.io(u.localizedDescription)
            }
        }
        if let c = error as? CocoaError, c.code == .fileWriteOutOfSpace {
            return InstallError.notEnoughSpace(needed: 0, available: 0)
        }
        return InstallError.io((error as NSError).localizedDescription)
    }
}

/// Zählt Bytes, schätzt Geschwindigkeit (gleitendes Fenster) und drosselt die Meldungen auf ~4 pro Sekunde.
struct ProgressTracker {
    var total: Int64
    var done: Int64
    var downloadTotal: Int64
    var downloaded: Int64 = 0
    var phase: InstallProgress.Phase = .checking
    var file: String?
    var model: ModelRef?
    private var samples: [(time: Date, bytes: Int64)] = []
    private var lastEmit = Date.distantPast

    init(total: Int64, done: Int64, downloadTotal: Int64) {
        self.total = total
        self.done = done
        self.downloadTotal = downloadTotal
    }

    mutating func add(_ n: Int64, download: Bool) {
        done = max(0, done + n)
        guard download else { return }
        downloaded += n
        let now = Date()
        samples.append((now, downloaded))
        samples.removeAll { now.timeIntervalSince($0.time) > 8 }
    }

    /// `nil`, wenn zu früh nach der letzten Meldung (außer `force` oder Phasenwechsel).
    mutating func snapshot(_ phase: InstallProgress.Phase, force: Bool = false) -> InstallProgress? {
        let now = Date()
        if !force, phase == self.phase, now.timeIntervalSince(lastEmit) < 0.25 { return nil }
        self.phase = phase
        lastEmit = now
        var speed = 0.0
        if let first = samples.first, let last = samples.last, last.time.timeIntervalSince(first.time) >= 1 {
            speed = Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
        }
        let remaining: Double? = speed > 1 ? Double(max(0, downloadTotal - downloaded)) / speed : nil
        return InstallProgress(
            phase: phase, bytesDone: min(done, total), bytesTotal: total, bytesPerSecond: speed,
            remainingSeconds: remaining, currentFile: file, currentModel: model)
    }
}
