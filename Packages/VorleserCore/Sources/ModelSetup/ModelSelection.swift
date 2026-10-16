import Foundation

/// Das in Gebrauch befindliche Modell einer Rolle.
public struct CurrentModel: Sendable, Equatable {
    /// `base` (Vorlesen und Klonen) oder `voiceDesign` (Stimme aus Beschreibung).
    public let role: String
    public let ref: ModelRef
    /// Dateiliste mit Prüfsummen: eingebaut oder im Modellordner. `nil`, wenn keine vorhanden ist.
    public let manifest: ModelManifest?
    /// `true`, wenn der Helfer das Modell gewählt hat; `false` für den eingebauten Standard.
    public let isChosen: Bool
}

public enum ModelSelectionError: Error, Equatable, LocalizedError {
    case notReady(String)

    public var errorDescription: String? {
        switch self {
        case let .notReady(repo): "Das Modell \(repo) ist noch nicht vollständig geladen."
        }
    }
}

/// Welches Modell je Rolle benutzt wird. Eine Wahl des Helfers steht in `Models/selection.json`
/// (Rolle → Modell), ihre Dateiliste in `Models/manifests/<Ordnername>.json`. Ohne Wahl gilt der
/// eingebaute Standard aus `Manifests/models.json` (für `base` je nach Qualität 4/8 Bit).
///
/// Alle Stellen (Engine, Einrichtung, CLI) fragen hier nach, nie direkt nach `ModelSpec.pinned`.
public enum ModelSelection {
    public static let fileName = "selection.json"

    /// Aufgelöstes Modell einer Rolle. `bits` gilt nur für den eingebauten Standard; eine Wahl hat Vorrang.
    /// `nil`, wenn es für die Rolle weder Wahl noch Standard gibt.
    public static func current(role: String, bits: Int, store: ModelStore = .standard) -> CurrentModel? {
        if let ref = chosenRefs(store: store)[role] {
            return CurrentModel(role: role, ref: ref, manifest: store.manifest(for: ref), isChosen: true)
        }
        guard let ref = ModelCatalog.ref(kind: role, bits: bits) else { return nil }
        return CurrentModel(role: role, ref: ref, manifest: store.manifest(for: ref), isChosen: false)
    }

    /// Die Wahlen des Helfers (Rolle → Modell). Fehlt die Datei oder ist sie unlesbar, gibt es keine Wahl.
    public static func chosenRefs(store: ModelStore = .standard) -> [String: ModelRef] {
        guard let data = try? Data(contentsOf: fileURL(store)),
              let refs = try? JSONDecoder().decode([String: ModelRef].self, from: data)
        else { return [:] }
        return refs
    }

    /// Setzt die Wahl einer Rolle. Nur ein vollständig geladenes Modell wird gewählt; das Manifest wird
    /// dazu im Modellordner abgelegt. Erst aufrufen, wenn der Installer `modelReady` gemeldet hat.
    public static func choose(role: String, manifest: ModelManifest, store: ModelStore = .standard) throws {
        guard store.status(of: manifest) == .ready else { throw ModelSelectionError.notReady(manifest.ref.repo) }
        try store.saveManifest(manifest)
        var refs = chosenRefs(store: store)
        refs[role] = manifest.ref
        try write(refs, store: store)
    }

    /// Entfernt die Wahl einer Rolle; danach gilt wieder der eingebaute Standard.
    /// Die geladenen Dateien bleiben im Modellordner (sie können wieder gewählt werden).
    public static func resetToDefault(role: String, store: ModelStore = .standard) throws {
        var refs = chosenRefs(store: store)
        refs[role] = nil
        try write(refs, store: store)
    }

    private static func fileURL(_ store: ModelStore) -> URL {
        store.root.appendingPathComponent(fileName)
    }

    private static func write(_ refs: [String: ModelRef], store: ModelStore) throws {
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(refs).write(to: fileURL(store), options: .atomic)
    }
}

extension ModelStore {
    /// Ort der gespeicherten Dateiliste einer gewählten Revision.
    public func manifestURL(for ref: ModelRef) -> URL {
        root.appendingPathComponent("manifests", isDirectory: true)
            .appendingPathComponent(ref.folderName + ".json")
    }

    /// Dateiliste eines Modells: zuerst die eingebaute, sonst die beim Wählen gespeicherte Kopie.
    public func manifest(for ref: ModelRef) -> ModelManifest? {
        if let builtIn = ModelManifest.bundled(for: ref) { return builtIn }
        guard let data = try? Data(contentsOf: manifestURL(for: ref)),
              let manifest = try? ModelManifest.decode(data),
              manifest.ref == ref
        else { return nil }
        return manifest
    }

    /// Legt die Dateiliste einer gewählten Revision im Modellordner ab.
    public func saveManifest(_ manifest: ModelManifest) throws {
        let url = manifestURL(for: manifest.ref)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifest.encoded().write(to: url, options: .atomic)
    }
}
