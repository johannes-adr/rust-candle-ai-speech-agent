import Darwin
import Foundation

/// Übernimmt Dateien aus dem Hugging-Face-Cache (`~/.cache/huggingface/hub`), statt sie neu zu laden.
/// Auf APFS entsteht per `clonefile` eine Kopie, die keinen zusätzlichen Platz braucht,
/// solange Quelle und Kopie unverändert bleiben. Quelle wird vorher per SHA-256 geprüft.
public struct HFCacheImporter: Sendable {
    public let cacheRoot: URL

    public init(cacheRoot: URL = ModelRef.defaultHuggingFaceCacheRoot) {
        self.cacheRoot = cacheRoot
    }

    /// Datei im Cache-Snapshot derselben Revision, wenn sie existiert und die Größe passt.
    /// Symbolische Links (Hugging Face legt `snapshots/<rev>/x -> ../../blobs/<hash>`) werden aufgelöst.
    public func candidate(for file: ModelManifest.File, of ref: ModelRef) -> URL? {
        let url = ref.huggingFaceSnapshotDirectory(cacheRoot: cacheRoot)
            .appendingPathComponent(file.path)
            .resolvingSymlinksInPath()
        guard ModelStore.fileSize(url) == file.size else { return nil }
        return url
    }

    /// Liegt `a` auf demselben Datenträger wie `b` (Voraussetzung für `clonefile`)?
    /// `b` darf noch nicht existieren; dann zählt der nächste vorhandene übergeordnete Ordner.
    public static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        func volume(_ url: URL) -> Int? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
                probe.deleteLastPathComponent()
            }
            var st = stat()
            return stat(probe.path, &st) == 0 ? Int(st.st_dev) : nil
        }
        guard let va = volume(a), let vb = volume(b) else { return false }
        return va == vb
    }

    /// Klont `source` nach `destination` (APFS, kein Platzverbrauch). Fällt auf Kopieren zurück,
    /// wenn Klonen nicht geht. Gibt zurück, ob geklont wurde.
    @discardableResult
    public static func cloneOrCopy(from source: URL, to destination: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        if clonefile(source.path, destination.path, 0) == 0 { return true }
        try fm.copyItem(at: source, to: destination)
        return false
    }
}
