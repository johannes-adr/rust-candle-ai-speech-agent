// Streamender MP3-Schreiber auf Basis von LAME 3.100 (Target CLAME).
// CBR, mono, 44,1 kHz, ID3v2 (UTF-16), Xing/Info-Header für die korrekte Dauer.
import CLAME
import Foundation

/// ID3v2-Metadaten.
public struct MP3Tags: Sendable, Equatable {
    public var title: String
    /// Interpret = Name der Stimme.
    public var artist: String
    /// Album = Dokument.
    public var album: String
    /// Track = Kapitelnummer (`track` von `trackCount`).
    public var track: Int?
    public var trackCount: Int?
    public var comment: String
    public var year: Int?

    public init(
        title: String = "", artist: String = "", album: String = "",
        track: Int? = nil, trackCount: Int? = nil,
        comment: String = "Mit KI vorgelesen", year: Int? = nil
    ) {
        self.title = title; self.artist = artist; self.album = album
        self.track = track; self.trackCount = trackCount
        self.comment = comment; self.year = year
    }
}

public struct MP3Settings: Sendable, Equatable {
    public var sampleRate: Int = 44_100
    public var bitrateKbps: Int = 64
    /// LAME-Qualität 0 (beste/langsamste) bis 9. 2 = „near-best“.
    public var quality: Int = 2
    public init() {}
}

/// Hängt Blöcke von `[Float]` (mono, ±1,0) an eine MP3-Datei an.
/// Geschrieben wird in `<Ziel>.part`, `finalize()` benennt um; so bleibt nie eine halbe Datei liegen.
/// Nicht für parallelen Zugriff gedacht; die Sperre schützt nur vor versehentlichem Mehrfachzugriff.
public final class MP3Writer: @unchecked Sendable {
    public let destination: URL
    public let settings: MP3Settings
    /// Bisher geschriebene Samples (Dauer = `samplesWritten ÷ sampleRate`).
    public private(set) var samplesWritten: Int = 0

    private let lock = NSLock()
    private var gf: OpaquePointer?
    private var handle: FileHandle?
    private let partURL: URL
    private var id3Size = 0
    private var finished = false
    private var outBuffer = [UInt8]()

    public init(destination: URL, tags: MP3Tags, settings: MP3Settings = MP3Settings()) throws {
        self.destination = destination
        self.settings = settings
        self.partURL = destination.appendingPathExtension("part")

        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.removeItem(at: partURL)
        guard fm.createFile(atPath: partURL.path, contents: nil) else {
            throw AudioOutError.fileFailed("Kann \(partURL.lastPathComponent) nicht anlegen")
        }
        handle = try FileHandle(forWritingTo: partURL)

        guard let g = lame_init() else { throw AudioOutError.encoderFailed("lame_init") }
        gf = g
        lame_set_num_channels(g, 1)
        lame_set_mode(g, MONO)
        lame_set_in_samplerate(g, Int32(settings.sampleRate))
        lame_set_out_samplerate(g, Int32(settings.sampleRate))
        lame_set_VBR(g, vbr_off)                       // CBR
        lame_set_brate(g, Int32(settings.bitrateKbps))
        lame_set_quality(g, Int32(settings.quality))
        lame_set_bWriteVbrTag(g, 1)                    // Info-Header (Xing-Variante für CBR)
        lame_set_write_id3tag_automatic(g, 0)          // ID3v2 schreiben wir selbst an den Anfang

        id3tag_init(g)
        id3tag_v2_only(g)
        id3tag_set_pad(g, 0)
        Self.apply(tags: tags, to: g)

        guard lame_init_params(g) >= 0 else {
            lame_close(g); gf = nil
            throw AudioOutError.encoderFailed("lame_init_params (Parameter nicht zulässig)")
        }

        // ID3v2-Tag zuerst in die Datei.
        let size = lame_get_id3v2_tag(g, nil, 0)
        if size > 0 {
            var tag = [UInt8](repeating: 0, count: size)
            let written = lame_get_id3v2_tag(g, &tag, size)
            guard written == size else { throw AudioOutError.encoderFailed("ID3v2-Tag") }
            try handle?.write(contentsOf: tag)
            id3Size = size
        }
    }

    deinit {
        if !finished { abort() }
    }

    /// Hängt einen Block an. Beliebige Blockgrößen sind erlaubt.
    public func append(_ samples: [Float]) throws {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let g = gf else { throw AudioOutError.encoderFailed("Writer bereits beendet") }
        guard !samples.isEmpty else { return }
        // In Teilen, damit der Ausgabepuffer klein bleibt.
        let step = 1 << 16
        var offset = 0
        while offset < samples.count {
            let n = min(step, samples.count - offset)
            let cap = Int(1.25 * Double(n)) + 7200
            if outBuffer.count < cap { outBuffer = [UInt8](repeating: 0, count: cap) }
            let produced: Int32 = samples.withUnsafeBufferPointer { src in
                outBuffer.withUnsafeMutableBufferPointer { dst in
                    lame_encode_buffer_ieee_float(
                        g, src.baseAddress! + offset, nil, Int32(n), dst.baseAddress!, Int32(cap))
                }
            }
            guard produced >= 0 else { throw AudioOutError.encoderFailed("lame_encode_buffer: Fehler \(produced)") }
            if produced > 0 { try handle?.write(contentsOf: outBuffer[0..<Int(produced)]) }
            offset += n
        }
        samplesWritten += samples.count
    }

    /// Schließt den Strom ab, schreibt den Info-Header und benennt die Datei in den Zielnamen um.
    @discardableResult
    public func finalize() throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !finished, let g = gf else { throw AudioOutError.encoderFailed("Writer bereits beendet") }
        finished = true
        defer { lame_close(g); gf = nil }

        let cap = 7200
        var buf = [UInt8](repeating: 0, count: cap)
        let flushed = lame_encode_flush(g, &buf, Int32(cap))
        guard flushed >= 0 else { throw AudioOutError.encoderFailed("lame_encode_flush: \(flushed)") }
        if flushed > 0 { try handle?.write(contentsOf: buf[0..<Int(flushed)]) }

        // Info-Header ersetzt den von LAME reservierten leeren ersten Frame.
        let tagSize = lame_get_lametag_frame(g, nil, 0)
        if tagSize > 0 {
            var frame = [UInt8](repeating: 0, count: tagSize)
            let n = lame_get_lametag_frame(g, &frame, tagSize)
            if n == tagSize {
                try handle?.seek(toOffset: UInt64(id3Size))
                try handle?.write(contentsOf: frame)
            }
        }
        try handle?.close()
        handle = nil

        let fm = FileManager.default
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: partURL, to: destination)
        return destination
    }

    /// Bricht ab und löscht die angefangene Datei.
    public func abort() {
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        finished = true
        if let g = gf { lame_close(g); gf = nil }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: partURL)
    }

    // MARK: - Tags

    private static func utf16(_ s: String) -> [UInt16] {
        // Mit Byte-Order-Mark (0xFEFF) und Abschluss-Null, wie LAME es für *_utf16 erwartet.
        [0xFEFF] + Array(s.utf16) + [0]
    }

    private static func apply(tags: MP3Tags, to g: OpaquePointer) {
        func set(_ id: String, _ value: String) {
            guard !value.isEmpty else { return }
            let text = utf16(value)
            text.withUnsafeBufferPointer { _ = id3tag_set_textinfo_utf16(g, id, $0.baseAddress!) }
        }
        set("TIT2", tags.title)
        set("TPE1", tags.artist)
        set("TALB", tags.album)
        if let t = tags.track {
            set("TRCK", tags.trackCount.map { "\(t)/\($0)" } ?? "\(t)")
        }
        if let y = tags.year { set("TYER", String(y)) }
        if !tags.comment.isEmpty {
            let desc = utf16("")
            let text = utf16(tags.comment)
            desc.withUnsafeBufferPointer { d in
                text.withUnsafeBufferPointer { t in
                    _ = id3tag_set_comment_utf16(g, "XXX", d.baseAddress!, t.baseAddress!)
                }
            }
        }
    }
}
