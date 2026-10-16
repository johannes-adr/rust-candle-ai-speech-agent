import Foundation

/// Platzprüfung vor dem Laden: benötigt gegen frei, mit Puffer.
public struct SpaceCheck: Sendable, Equatable {
    public var needed: Int64
    public var available: Int64
    public var buffer: Int64

    public init(needed: Int64, available: Int64, buffer: Int64? = nil) {
        self.needed = needed
        self.available = available
        self.buffer = buffer ?? Self.defaultBuffer(for: needed)
    }

    /// 1 GiB plus 10 % des Bedarfs: macOS braucht selbst Platz (Zwischenablage, Wiederherstellung).
    public static func defaultBuffer(for needed: Int64) -> Int64 {
        (1 << 30) + needed / 10
    }

    public var isEnough: Bool { needed == 0 || available >= needed + buffer }
    /// Wie viel noch fehlt (0, wenn genug da ist).
    public var shortfall: Int64 { isEnough ? 0 : needed + buffer - available }

    /// Freier Platz auf dem Datenträger, auf dem `url` liegt (auch wenn der Ordner noch nicht existiert).
    /// Nutzt die Zahl, die auch das Finder-Fenster zeigt (inkl. löschbarem Platz).
    public static func freeBytes(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return Int64(values?.volumeAvailableCapacity ?? 0)
    }
}
