/// Reproduzierbare Seeds: Seed = Hash(Projekt, Index, Versuch) laut PLAN §4.4.
public enum SeedDerivation {
    /// FNV-1a 64 Bit, stabil über Läufe und Rechner (anders als `Hasher`).
    public static func seed(project: String, index: Int, attempt: Int) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                h ^= UInt64(b)
                h = h &* 0x100000001b3
            }
        }
        mix(project.utf8)
        mix([0xff])
        withUnsafeBytes(of: UInt64(truncatingIfNeeded: index).littleEndian) { mix($0) }
        mix([0xfe])
        withUnsafeBytes(of: UInt64(truncatingIfNeeded: attempt).littleEndian) { mix($0) }
        return h
    }
}
