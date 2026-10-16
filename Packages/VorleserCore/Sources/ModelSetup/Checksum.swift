import CryptoKit
import Foundation

public enum Checksum {
    /// SHA-256 einer Datei in Stücken zu 4 MiB (Speicher bleibt klein). Bricht bei Abbruch der Task ab.
    public static func sha256(ofFileAt url: URL, progress: ((Int64) -> Void)? = nil) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: 4 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            total += Int64(chunk.count)
            progress?(total)
        }
        return hex(hasher.finalize())
    }

    public static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    public static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
