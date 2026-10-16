import AppKit
import Foundation
import TextPrep
import Testing
@testable import DocumentImport

/// Tests auf den synthetischen Test-PDFs (Tests/DocumentImportTests/Fixtures, erzeugt von
/// scripts/s4-fixtures/make-fixtures.swift) und auf den übrigen Dateiformaten.
@Suite struct ImporterTests {
    static func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"), "Fixture \(name) fehlt")
    }

    static func texts(_ d: TextDocument) -> [String] {
        d.blocks.map { switch $0 { case .heading(_, let t): t; case .paragraph(let p): p } }
    }

    static func headings(_ d: TextDocument) -> [(Int, String)] {
        d.blocks.compactMap { if case .heading(let l, let t) = $0 { (l, t) } else { nil } }
    }

    let importer = DocumentImporter()

    // MARK: PDF-Fixtures

    @Test func behoerdenbrief() async throws {
        let r = try await importer.importDetailed(at: Self.fixture("behoerdenbrief.pdf"), languageHint: nil)
        let all = Self.texts(r.document).joined(separator: "\n")
        #expect(r.language == "de")
        #expect(r.ocrPages.isEmpty)
        #expect(!all.contains("Stadtverwaltung Musterstadt · Amt"))  // Kopfzeile
        #expect(!all.contains("Telefon 01234"))  // Fußzeile
        #expect(!all.contains("Grundmiete") && !all.contains("7.746,00"))  // Tabelle
        #expect(all.contains("Sehr geehrte Frau Mustermann,"))
        #expect(all.contains("Verfahrens informieren."))  // Silbentrennung zusammengezogen
        #expect(Self.headings(r.document).contains { $0.1.hasPrefix("Betreff:") })
        #expect(!all.contains("informie ren") && !all.contains("informie-"))
        // Adressblock bleibt zeilenweise getrennt
        #expect(Self.texts(r.document).contains("Maria Mustermann"))
    }

    @Test func zweispaltigeZeitung() async throws {
        let r = try await importer.importDetailed(at: Self.fixture("zeitung.pdf"), languageHint: nil)
        let all = Self.texts(r.document).joined(separator: "\n")
        #expect(r.document.title == "Gemeinderat beschließt neuen Radweg")
        #expect(r.report?.twoColumnPages.contains(0) == true)
        // Lesereihenfolge: der Satz läuft innerhalb der linken Spalte über Zeilen und Silbentrennung
        #expect(all.contains("Der Gemeinderat hat am Montagabend mit großer Mehrheit den Bau eines neuen Radwegs entlang der Hauptstraße beschlossen."))
        #expect(!all.contains("Musterstädter Tageblatt"))
        #expect(!all.contains("Abbildung 1"))
        #expect(Self.headings(r.document).contains { $0.1 == "Streit um die Parkplätze" })
    }

    @Test func buchMitSilbentrennungUndKapiteln() async throws {
        let r = try await importer.importDetailed(at: Self.fixture("buch.pdf"), languageHint: nil)
        let all = Self.texts(r.document).joined(separator: "\n")
        #expect(r.pageCount == 4)
        #expect(r.document.title == "Die Reise nach Süden")
        #expect(Self.headings(r.document).count >= 3)
        #expect(!all.contains("Anna Beispiel · Die Reise"))  // Kolumnentitel
        #expect(!all.contains("Vgl. Meyer"))  // Fußnote
        #expect(!all.contains("verschwinden.1"))  // Fußnotenziffer
        #expect(all.contains("als könnte er unterwegs verschwinden."))
        #expect(all.range(of: #"\p{L}- ?\p{Ll}"#, options: .regularExpression) == nil, "übrig gebliebene Trennstriche")
        #expect(!all.contains("\u{00AD}"))
        // Seitenzahlen sind weg: keine Block besteht nur aus einer Zahl
        #expect(!Self.texts(r.document).contains { Int($0) != nil })
        // Absätze laufen über Seitenumbrüche
        #expect(Self.texts(r.document).allSatisfy { $0.count > 3 })
    }

    @Test func portugiesischesPDF() async throws {
        let r = try await importer.importDetailed(at: Self.fixture("portugiesisch.pdf"), languageHint: nil)
        let all = Self.texts(r.document).joined(separator: "\n")
        #expect(r.language == "pt")
        #expect(!all.contains("Serviço de Ação Social e Habitação"))
        #expect(!all.contains("Página 1 de 2"))
        #expect(all.contains("19,99 euros"))
        #expect(all.contains("Analisámos a documentação apresentada"))
        #expect(Self.headings(r.document).contains { $0.1.hasPrefix("Assunto:") && $0.1.hasSuffix("123/45-6") })
    }

    @Test func scanPerOCR() async throws {
        let r = try await importer.importDetailed(at: Self.fixture("scan.pdf"), languageHint: nil)
        let all = Self.texts(r.document).joined(separator: "\n")
        #expect(r.ocrPages == [0])
        #expect(r.language == "de")
        #expect(r.document.title == "Mietvertrag über Wohnraum")
        #expect(all.contains("Kaution"))
        #expect(all.contains("450,00 Euro"))
        #expect(all.contains("Schriftform."))
    }

    @Test func handyFotoPerOCR() async throws {
        let r = try await importer.importDetailed(at: Self.fixture("foto.jpg"), languageHint: nil)
        let all = Self.texts(r.document).joined(separator: "\n")
        #expect(r.ocrPages == [0])
        #expect(all.contains("Mietvertrag"))
        #expect(all.contains("Vermieter"))
        #expect(all.contains("Kaution"))
        #expect(r.document.blocks.count == 5, "Titel + 4 Absätze dank RecognizeDocumentsRequest")
    }

    @Test func nichtLesbarOderLeer() async throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("kaputt-\(UUID().uuidString).pdf")
        try Data("kein pdf".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        await #expect(throws: DocumentImportError.self) { try await importer.importDocument(at: tmp) }
        let odd = FileManager.default.temporaryDirectory.appendingPathComponent("x-\(UUID().uuidString).xyz")
        try Data("a".utf8).write(to: odd)
        defer { try? FileManager.default.removeItem(at: odd) }
        await #expect(throws: DocumentImportError.unsupportedType("xyz")) { try await importer.importDocument(at: odd) }
    }

    // MARK: Text

    @Test func importTextSplitsAtBlankLines() {
        let d = importer.importText("Erster Absatz,\nzweite Zeile.\r\n\r\nZweiter Absatz.\n\n\n  \nDritter.")
        #expect(d.blocks == [.paragraph("Erster Absatz, zweite Zeile."), .paragraph("Zweiter Absatz."), .paragraph("Dritter.")])
        #expect(importer.importText("  \n ").blocks.isEmpty)
    }

    @Test func decodesCommonEncodings() throws {
        let text = "Grüße aus Köln – schön"
        #expect(try DocumentImporter.decodeText(Data(text.utf8)) == text)
        #expect(try DocumentImporter.decodeText(Data([0xEF, 0xBB, 0xBF]) + Data(text.utf8)) == text)
        #expect(try DocumentImporter.decodeText(text.data(using: .utf16)!) == text)  // mit BOM
        #expect(try DocumentImporter.decodeText(text.data(using: .utf16LittleEndian)!) == text)  // ohne BOM
        let cp = "Grüße aus Köln – schön".data(using: .windowsCP1252)!  // Gedankenstrich 0x96
        #expect(try DocumentImporter.decodeText(cp) == text)
        let latin = "Grüße aus Köln".data(using: .isoLatin1)!
        #expect(try DocumentImporter.decodeText(latin) == "Grüße aus Köln")
    }

    @Test func importsTextFileWithWindowsEncoding() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("t-\(UUID().uuidString).txt")
        try "Über den Wolken\n\nmuss die Freiheit wohl grenzenlos sein.".data(using: .windowsCP1252)!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let d = try await importer.importDocument(at: url)
        #expect(d.blocks == [.paragraph("Über den Wolken"), .paragraph("muss die Freiheit wohl grenzenlos sein.")])
    }

    // MARK: Word, ODT, RTF, HTML

    @MainActor
    static func sample() -> NSAttributedString {
        let m = NSMutableAttributedString()
        func add(_ s: String, size: CGFloat, bold: Bool) {
            let f = bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size)
            m.append(NSAttributedString(string: s + "\n", attributes: [.font: f]))
        }
        add("Das Hauptkapitel", size: 22, bold: true)
        add("Dies ist ein langer Absatz mit mehreren Sätzen. Er dient dem Test des Importers und muss als ein Absatz erscheinen.", size: 12, bold: false)
        add("Noch ein Absatz, ebenfalls ausreichend lang, damit die Fließtextgröße klar die Mehrheit stellt und nichts anderes.", size: 12, bold: false)
        add("Ein Unterkapitel", size: 15, bold: true)
        add("Und ein letzter Absatz, der unter dem Unterkapitel steht und ebenfalls lang genug ist für den Test hier.", size: 12, bold: false)
        return m
    }

    @MainActor
    func roundTrip(_ type: NSAttributedString.DocumentType, ext: String) async throws {
        let attr = Self.sample()
        let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: type])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rt-\(UUID().uuidString).\(ext)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let d = try await importer.importDocument(at: url)
        #expect(d.blocks.count == 5, "\(ext): \(d.blocks)")
        #expect(d.blocks.first == .heading(level: 1, text: "Das Hauptkapitel"), "\(ext)")
        #expect(d.blocks.contains(.heading(level: 2, text: "Ein Unterkapitel")), "\(ext)")
        #expect(d.title == "Das Hauptkapitel")
    }

    @Test @MainActor func importsRTF() async throws { try await roundTrip(.rtf, ext: "rtf") }
    @Test @MainActor func importsDOCX() async throws { try await roundTrip(.officeOpenXML, ext: "docx") }
    @Test @MainActor func importsODT() async throws { try await roundTrip(.openDocument, ext: "odt") }

    @Test @MainActor func importsHTML() async throws {
        let html = """
        <html><body><h1>Titel der Seite</h1><p>Ein Absatz mit genug Text, damit die Mehrheit der Zeichen klar ist und mehr.</p>
        <p>Noch ein Absatz, der ebenfalls ordentlich lang ist, damit er die Fließtextgröße bestimmt.</p><h2>Unterpunkt</h2>
        <p>Schlusstext mit Umlauten: Größe, Fuß, Äpfel und vieles mehr, was zählt.</p></body></html>
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("h-\(UUID().uuidString).html")
        try Data(html.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let d = try await importer.importDocument(at: url)
        #expect(d.blocks.first == .heading(level: 1, text: "Titel der Seite"), "\(d.blocks)")
        #expect(d.blocks.contains { if case .paragraph(let p) = $0 { p.contains("Größe, Fuß, Äpfel") } else { false } })
        #expect(d.blocks.count == 5)
    }
}
