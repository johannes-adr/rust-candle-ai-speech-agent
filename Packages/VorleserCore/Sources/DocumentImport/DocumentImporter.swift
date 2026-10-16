import AppKit
import Foundation
import TextPrep
import PDFKit

public enum DocumentImportError: Error, Sendable, Equatable {
    case unreadable(String)
    case passwordProtected
    case unsupportedType(String)
    case empty
}

/// Ergebnis mit Messdaten (für den Spike und die Oberfläche).
public struct ImportResult: Sendable {
    public var document: TextDocument
    public var report: CleaningReport?
    public var pageCount: Int
    /// Seiten (0-basiert), die per OCR gelesen wurden.
    public var ocrPages: [Int]
    public var language: String?
}

/// Liest PDF, Word/ODT/RTF/HTML, Text und Bilder in ein `TextDocument`.
public struct DocumentImporter: Sendable {
    public var cleaner: PDFCleaner
    /// Eine PDF-Seite mit weniger Buchstaben als dies gilt als „ohne Text“ und wird per OCR gelesen.
    public var minLettersPerTextPage = 25
    /// Anteil der Buchstaben an den Nicht-Leerzeichen, darunter ist die Textebene Müll (z. B. kaputte Schriftkodierung).
    public var minLetterRatio = 0.5
    /// Texterkennung: `RecognizeDocumentsRequest` (Absätze) oder nur `VNRecognizeTextRequest` (für Vergleiche).
    var ocrEngine: OCR.Engine = .documents
    public mutating func useLegacyOCR() { ocrEngine = .text }

    public init(cleaner: PDFCleaner = PDFCleaner()) {
        self.cleaner = cleaner
    }

    public static let supportedExtensions: Set<String> = [
        "pdf", "txt", "text", "md", "rtf", "rtfd", "doc", "docx", "odt", "html", "htm",
        "png", "jpg", "jpeg", "heic", "tif", "tiff",
    ]

    // MARK: Öffentliche API

    public func importDocument(at url: URL) async throws -> TextDocument {
        try await importDetailed(at: url, languageHint: nil).document
    }

    /// Eingefügter Text: Absätze an Leerzeilen; einzelne Zeilenumbrüche werden Leerzeichen.
    public func importText(_ string: String) -> TextDocument {
        TextDocument(title: nil, blocks: Self.paragraphs(fromPlainText: string, checker: cleaner.wordChecker))
    }

    public func importDetailed(at url: URL, languageHint: String?) async throws -> ImportResult {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf":
            return try await importPDF(at: url, languageHint: languageHint)
        case "png", "jpg", "jpeg", "heic", "tif", "tiff":
            return try await importImage(at: url, languageHint: languageHint)
        case "txt", "text", "md":
            let data = try readData(url)
            let text = try Self.decodeText(data)
            let doc = importText(text)
            guard !doc.blocks.isEmpty else { throw DocumentImportError.empty }
            return ImportResult(document: doc, report: nil, pageCount: 1, ocrPages: [], language: TextHelpers.detectLanguage(text))
        case "rtf", "rtfd", "doc", "docx", "odt", "html", "htm":
            return try await importRichText(at: url, ext: ext)
        default:
            throw DocumentImportError.unsupportedType(ext)
        }
    }

    // MARK: PDF

    private func importPDF(at url: URL, languageHint: String?) async throws -> ImportResult {
        guard let pdf = PDFDocument(url: url) else { throw DocumentImportError.unreadable(url.lastPathComponent) }
        if pdf.isLocked, !pdf.unlock(withPassword: "") { throw DocumentImportError.passwordProtected }
        var pages: [PageLayout] = []
        var ocrIndices: [Int] = []
        var ocrPending: [(index: Int, page: PDFPage)] = []
        for i in 0..<pdf.pageCount {
            try Task.checkCancellation()
            guard let page = pdf.page(at: i) else { continue }
            let size = page.bounds(for: .cropBox).size
            let lines = PDFLineExtractor.lines(of: page, index: i)
            if hasUsableText(lines) {
                pages.append(PageLayout(index: i, size: size, lines: lines))
            } else {
                ocrPending.append((i, page))
            }
        }
        // Sprache aus den Textseiten; für reine Scans nach einem ersten OCR-Durchgang.
        var language = languageHint ?? TextHelpers.detectLanguage(pages.flatMap(\.lines).map(\.text).joined(separator: " "))
        for (i, page) in ocrPending {
            try Task.checkCancellation()
            guard let image = OCR.render(page: page) else { continue }
            let size = page.bounds(for: .cropBox).size
            let lines = try await OCR.recognize(image: image, pageSize: size, pageIndex: i, language: language, engine: ocrEngine)
            if language == nil {
                language = TextHelpers.detectLanguage(lines.map(\.text).joined(separator: " "))
                if language != nil, !OCR.visionLanguages(for: language).isEmpty {
                    // Zweiter Durchgang mit bekannter Sprache (bessere Sprachkorrektur).
                    let again = try await OCR.recognize(image: image, pageSize: size, pageIndex: i, language: language, engine: ocrEngine)
                    pages.append(PageLayout(index: i, size: size, lines: again, fromOCR: true))
                    ocrIndices.append(i)
                    continue
                }
            }
            pages.append(PageLayout(index: i, size: size, lines: lines, fromOCR: true))
            ocrIndices.append(i)
        }
        pages.sort { $0.index < $1.index }
        let (doc, report) = cleaner.clean(pages: pages, language: language)
        guard !doc.blocks.isEmpty else { throw DocumentImportError.empty }
        return ImportResult(document: doc, report: report, pageCount: pdf.pageCount, ocrPages: ocrIndices.sorted(), language: report.language)
    }

    func hasUsableText(_ lines: [PageLine]) -> Bool {
        let text = lines.map(\.text).joined(separator: " ")
        let letters = TextHelpers.letterCount(text)
        let nonSpace = text.filter { !$0.isWhitespace }.count
        guard letters >= minLettersPerTextPage, nonSpace > 0 else { return false }
        return Double(letters) / Double(nonSpace) >= minLetterRatio
    }

    // MARK: Bilder (Handy-Foto, Scan als Bilddatei)

    private func importImage(at url: URL, languageHint: String?) async throws -> ImportResult {
        guard let image = OCR.loadImage(at: url) else { throw DocumentImportError.unreadable(url.lastPathComponent) }
        let size = CGSize(width: image.width, height: image.height)
        var lines = try await OCR.recognize(image: image, pageSize: size, pageIndex: 0, language: languageHint, engine: ocrEngine)
        var language = languageHint ?? TextHelpers.detectLanguage(lines.map(\.text).joined(separator: " "))
        if languageHint == nil, language != nil, !OCR.visionLanguages(for: language).isEmpty {
            lines = try await OCR.recognize(image: image, pageSize: size, pageIndex: 0, language: language, engine: ocrEngine)
        }
        let (doc, report) = cleaner.clean(pages: [PageLayout(index: 0, size: size, lines: lines, fromOCR: true)], language: language)
        language = report.language
        guard !doc.blocks.isEmpty else { throw DocumentImportError.empty }
        return ImportResult(document: doc, report: report, pageCount: 1, ocrPages: [0], language: language)
    }

    // MARK: Word, ODT, RTF, HTML

    @MainActor
    private static func loadAttributed(url: URL, ext: String) throws -> NSAttributedString {
        let type: NSAttributedString.DocumentType
        switch ext {
        case "rtf": type = .rtf
        case "rtfd": type = .rtfd
        case "doc": type = .docFormat
        case "docx": type = .officeOpenXML
        case "odt": type = .openDocument
        default: type = .html
        }
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        if type == .html { options[.characterEncoding] = String.Encoding.utf8.rawValue }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            throw DocumentImportError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func loadDocument(url: URL, ext: String, checker: WordChecker) throws -> TextDocument {
        document(from: try loadAttributed(url: url, ext: ext), checker: checker)
    }

    private func importRichText(at url: URL, ext: String) async throws -> ImportResult {
        // NSAttributedString (vor allem HTML/WebKit) muss auf dem Hauptthread laufen.
        let checker = cleaner.wordChecker
        let doc = try await Self.loadDocument(url: url, ext: ext, checker: checker)
        guard !doc.blocks.isEmpty else { throw DocumentImportError.empty }
        let text = doc.blocks.map { if case .paragraph(let p) = $0 { return p } else if case .heading(_, let t) = $0 { return t } else { return "" } }.joined(separator: " ")
        return ImportResult(document: doc, report: nil, pageCount: 1, ocrPages: [], language: TextHelpers.detectLanguage(text))
    }

    /// Absätze eines formatierten Textes; Überschriften an Größe/Fettdruck/Absatzstil erkannt.
    static func document(from attributed: NSAttributedString, checker: WordChecker) -> TextDocument {
        struct Para { var text: String; var size: CGFloat; var bold: Bool }
        var paras: [Para] = []
        let ns = attributed.string as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            let sub = attributed.attributedSubstring(from: range)
            let (text, size, bold) = PDFLineExtractor.analyze(sub, fallbackSize: 12)
            let clean = TextHelpers.normalize(text)
            if !clean.isEmpty { paras.append(Para(text: clean, size: size, bold: bold)) }
        }
        var weights: [CGFloat: Int] = [:]
        for p in paras { weights[(p.size * 2).rounded() / 2, default: 0] += p.text.count }
        let body = weights.max { $0.value < $1.value }?.key ?? 12
        let boldChars = paras.filter(\.bold).reduce(0) { $0 + $1.text.count }
        let totalChars = max(paras.reduce(0) { $0 + $1.text.count }, 1)
        let bodyIsBold = Double(boldChars) / Double(totalChars) > 0.5

        var headingSizes: [CGFloat] = []
        func isHeading(_ p: Para) -> Bool {
            guard p.text.count <= 120, TextHelpers.letterCount(p.text) >= 2 else { return false }
            if let c = p.text.last, [".", ",", ";", ":"].contains(c) { return false }
            if p.size >= body * 1.15 { return true }
            return !bodyIsBold && p.bold && p.text.count <= 90
        }
        for p in paras where isHeading(p) && p.size >= body * 1.15 { headingSizes.append((p.size * 2).rounded() / 2) }
        var clusters: [CGFloat] = []
        for s in Array(Set(headingSizes)).sorted(by: >) where clusters.last.map({ $0 - s >= 1 }) ?? true { clusters.append(s) }

        var blocks: [TextBlock] = []
        var title: String?
        for p in paras {
            if isHeading(p) {
                var level = 3
                if p.size >= body * 1.15, let rank = clusters.firstIndex(where: { abs($0 - p.size) < 1 }) { level = min(rank + 1, 3) }
                if level == 1, title == nil { title = p.text }
                blocks.append(.heading(level: level, text: p.text))
            } else if TextHelpers.letterCount(p.text) > 0 {
                blocks.append(.paragraph(p.text))
            }
        }
        return TextDocument(title: title, blocks: blocks)
    }

    // MARK: Reiner Text

    /// Erkennt UTF-8 (mit/ohne BOM), UTF-16 (BOM), sonst Windows-1252, zuletzt ISO-Latin-1.
    static func decodeText(_ data: Data) throws -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        // UTF-16 ohne BOM: viele Nullbytes an jeder zweiten Stelle
        if data.count >= 4 {
            let nulls = stride(from: 1, to: min(data.count, 400), by: 2).filter { data[$0] == 0 }.count
            let nullsLE = stride(from: 0, to: min(data.count, 400), by: 2).filter { data[$0] == 0 }.count
            let probe = min(data.count, 400) / 2
            if nulls * 10 > probe * 7, let s = String(data: data, encoding: .utf16LittleEndian) { return s }
            if nullsLE * 10 > probe * 7, let s = String(data: data, encoding: .utf16BigEndian) { return s }
        }
        // Windows-1252 hat in 0x81, 0x8D, 0x8F, 0x90, 0x9D keine Zeichen; dann ISO-Latin-1.
        if let s = String(data: data, encoding: .windowsCP1252) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        throw DocumentImportError.unreadable("Textkodierung nicht erkannt")
    }

    static func paragraphs(fromPlainText text: String, checker: WordChecker) -> [TextBlock] {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [TextBlock] = []
        var current: [String] = []
        func flush() {
            guard !current.isEmpty else { return }
            var s = ""
            for line in current {
                if s.isEmpty { s = line; continue }
                if s.hasSuffix("\u{00AD}") { s = String(s.dropLast()) + line; continue }
                s += (s.last.map(TextHelpers.isCJK) ?? false) && (line.first.map(TextHelpers.isCJK) ?? false) ? line : " " + line
            }
            if TextHelpers.letterCount(s) > 0 || s.contains(where: \.isNumber) { blocks.append(.paragraph(s)) }
            current = []
        }
        for raw in unified.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = TextHelpers.normalize(String(raw))
            if line.isEmpty { flush() } else { current.append(line) }
        }
        flush()
        return blocks
    }

    private func readData(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch { throw DocumentImportError.unreadable(url.lastPathComponent) }
    }
}
