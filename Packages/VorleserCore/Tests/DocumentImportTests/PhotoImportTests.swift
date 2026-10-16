import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import DocumentImport
import TextPrep

/// Synthetische „Fotos“ (CoreText auf weißem Grund), damit Mehrseiten-Import, Drehung und Ränder ohne
/// echte Handyfotos geprüft werden können. Echte Fotos (Licht, Perspektive, Biegung) deckt das nicht ab.
enum PhotoFixtures {
    static let paragraphsDE: [[String]] = [
        [
            "Sehr geehrte Frau Meier, vielen Dank für Ihr Schreiben vom letzten Monat. Wir haben Ihren Antrag sorgfältig geprüft und freuen uns, Ihnen mitzuteilen, dass die Kosten übernommen werden.",
            "Bitte melden Sie sich bei Rückfragen jederzeit bei uns. Unsere Sprechzeiten finden Sie auf der Rückseite dieses Briefes.",
        ],
        [
            "Im zweiten Teil unseres Schreibens erklären wir Ihnen, wie es weitergeht. Zunächst erhalten Sie in den nächsten Tagen eine Bestätigung per Post, danach können Sie den Bescheid bei Ihrer Hausärztin vorlegen.",
            "Sollten sich Ihre Angaben ändern, teilen Sie uns dies bitte schriftlich mit. Wir wünschen Ihnen alles Gute und verbleiben mit freundlichen Grüßen.",
        ],
        [
            "Zum Schluss möchten wir Sie noch auf unser Beratungsangebot hinweisen. Dort helfen Ihnen geschulte Mitarbeiter bei allen Fragen rund um Ihre Versicherung, auch am Telefon und ohne Termin.",
        ],
    ]

    static func page(
        _ paragraphs: [String], pageNumber: Int?, edgeJunk: Bool = false, size: CGSize = CGSize(width: 1500, height: 2000),
        fontSize: CGFloat = 40, skewDegrees: CGFloat = 0
    ) -> CGImage {
        let ctx = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        if skewDegrees != 0 {
            ctx.translateBy(x: size.width / 2, y: size.height / 2)
            ctx.rotate(by: skewDegrees * .pi / 180)
            ctx.translateBy(x: -size.width / 2, y: -size.height / 2)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        func draw(_ text: String, in rect: CGRect) {
            let attr = NSAttributedString(string: text, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true,
            ])
            let framesetter = CTFramesetterCreateWithAttributedString(attr)
            let path = CGPath(rect: rect, transform: nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), ctx)
        }
        var y = size.height - 160
        for p in paragraphs {
            let lines = ceil(CGFloat(p.count) * fontSize * 0.5 / (size.width - 300))
            let h = lines * fontSize * 1.5 + 20
            draw(p, in: CGRect(x: 150, y: y - h, width: size.width - 300, height: h))
            y -= h + fontSize * 1.2
        }
        if let n = pageNumber { draw("- \(n) -", in: CGRect(x: size.width / 2 - 60, y: 50, width: 160, height: 60)) }
        if edgeJunk {
            // Eine Zeile der Nachbarseite, vom linken Bildrand abgeschnitten.
            draw("Nachbarseite Randnotiz abgeschnitten hier", in: CGRect(x: -330, y: 500, width: 900, height: 60))
        }
        return ctx.makeImage()!
    }

    /// Schreibt Bilder als JPEG in einen frischen Ordner; `turns` dreht das Bild im Uhrzeigersinn (Handy auf der Seite).
    static func write(_ images: [CGImage], turns: [Int] = []) throws -> (urls: [URL], cleanup: () -> Void) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "vorleser-photos-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var urls: [URL] = []
        for (i, image) in images.enumerated() {
            let rotated = PhotoOrientation.rotate(image, clockwiseQuarterTurns: i < turns.count ? turns[i] : 0)!
            let url = dir.appending(path: String(format: "IMG_%04d.jpg", i + 1))
            let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(dest, rotated, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            #expect(CGImageDestinationFinalize(dest))
            urls.append(url)
        }
        return (urls, { try? FileManager.default.removeItem(at: dir) })
    }

    static func texts(_ d: TextDocument) -> [String] {
        d.blocks.map { switch $0 { case .heading(_, let t): t; case .paragraph(let p): p } }
    }
}

@Suite struct PhotoImportTests {
    let importer = DocumentImporter()

    @Test func threePagesBecomeOneDocumentInOrder() async throws {
        let images = PhotoFixtures.paragraphsDE.enumerated().map { PhotoFixtures.page($1, pageNumber: $0 + 1) }
        let (urls, cleanup) = try PhotoFixtures.write(images)
        defer { cleanup() }
        var seen: [Int] = []
        let box = Box()
        let r = try await importer.importPhotos(at: urls, languageHint: nil, progress: { n, total in
            box.add(n); #expect(total == 3)
        })
        seen = box.values
        #expect(seen == [1, 2, 3])
        #expect(r.pageCount == 3)
        #expect(r.ocrPages == [0, 1, 2])
        #expect(r.language == "de")
        #expect(r.unreadablePages.isEmpty)
        let all = PhotoFixtures.texts(r.document).joined(separator: "\n")
        let i1 = try #require(all.range(of: "Antrag sorgfältig")?.lowerBound)
        let i2 = try #require(all.range(of: "zweiten Teil")?.lowerBound)
        let i3 = try #require(all.range(of: "Beratungsangebot")?.lowerBound)
        #expect(i1 < i2 && i2 < i3, "Reihenfolge der Aufnahme bleibt")
        // Seitenzahlen der Fotos sind weg.
        #expect(!PhotoFixtures.texts(r.document).contains { $0.contains("- 1 -") || $0.contains("- 2 -") || $0.contains("- 3 -") })
        #expect(!all.contains("- 2 -"))
    }

    @Test func reversedOrderOfFilesGivesReversedText() async throws {
        let images = PhotoFixtures.paragraphsDE.prefix(2).enumerated().map { PhotoFixtures.page($1, pageNumber: $0 + 1) }
        let (urls, cleanup) = try PhotoFixtures.write(images)
        defer { cleanup() }
        let r = try await importer.importPhotos(at: urls.reversed(), languageHint: "de")
        let all = PhotoFixtures.texts(r.document).joined(separator: "\n")
        #expect(try #require(all.range(of: "zweiten Teil")).lowerBound < (try #require(all.range(of: "Antrag sorgfältig")).lowerBound))
    }

    @Test(arguments: [1, 2, 3]) func rotatedPhotosAreTurnedUpright(clockwiseTurns: Int) async throws {
        let image = PhotoFixtures.page(PhotoFixtures.paragraphsDE[0], pageNumber: 1)
        let (urls, cleanup) = try PhotoFixtures.write([image], turns: [clockwiseTurns])
        defer { cleanup() }
        let r = try await importer.importPhotos(at: urls, languageHint: nil)
        let all = PhotoFixtures.texts(r.document).joined(separator: "\n")
        #expect(all.contains("Antrag sorgfältig geprüft"), "Drehung \(clockwiseTurns): \(all.prefix(120))")
        // Seitlich gedrehte Fotos müssen als gedreht erkannt werden. Kopfstehende liest Vision auch ohne Drehung
        // (gemessen); dann ist keine Drehung nötig.
        if clockwiseTurns == 2 {
            #expect(r.rotatedPages[0] == nil || r.rotatedPages[0] == 2)
        } else {
            #expect(r.rotatedPages[0] == (4 - clockwiseTurns) % 4)
        }
    }

    @Test func uprightPhotoIsNotRotated() async throws {
        let (urls, cleanup) = try PhotoFixtures.write([PhotoFixtures.page(PhotoFixtures.paragraphsDE[1], pageNumber: 2)])
        defer { cleanup() }
        let r = try await importer.importPhotos(at: urls, languageHint: nil)
        #expect(r.rotatedPages.isEmpty)
    }

    @Test func rotatingExistingFixtureStillReads() async throws {
        let url = try ImporterTests.fixture("foto.jpg")
        let image = try #require(OCR.loadImage(at: url))
        for turns in [1, 2] {
            let (urls, cleanup) = try PhotoFixtures.write([image], turns: [turns])
            defer { cleanup() }
            let r = try await importer.importPhotos(at: urls, languageHint: nil)
            let all = PhotoFixtures.texts(r.document).joined(separator: "\n")
            #expect(all.contains("Mietvertrag") && all.contains("Kaution"), "Drehung \(turns)")
        }
    }

    @Test func skewedPhotoKeepsParagraphs() async throws {
        let straight = PhotoFixtures.page(PhotoFixtures.paragraphsDE[0], pageNumber: 1)
        let tilted = PhotoFixtures.page(PhotoFixtures.paragraphsDE[0], pageNumber: 1, skewDegrees: 3)
        let (urls, cleanup) = try PhotoFixtures.write([straight, tilted])
        defer { cleanup() }
        let a = try await importer.importPhotos(at: [urls[0]], languageHint: "de")
        let b = try await importer.importPhotos(at: [urls[1]], languageHint: "de")
        #expect(PhotoFixtures.texts(a.document).count == 2)
        #expect(PhotoFixtures.texts(b.document).count == 2, "\(PhotoFixtures.texts(b.document))")
        #expect(PhotoFixtures.texts(b.document).joined().contains("Antrag sorgfältig"))
    }

    @Test func textCutOffByTheEdgeIsDropped() async throws {
        let image = PhotoFixtures.page(PhotoFixtures.paragraphsDE[0], pageNumber: 1, edgeJunk: true)
        let (urls, cleanup) = try PhotoFixtures.write([image])
        defer { cleanup() }
        let r = try await importer.importPhotos(at: urls, languageHint: "de")
        let all = PhotoFixtures.texts(r.document).joined(separator: "\n")
        #expect(!all.contains("Randnotiz"), "\(all)")
        #expect(all.contains("Antrag sorgfältig"))
    }

    @Test func blankOrBrokenFilesAreReported() async throws {
        let blank = PhotoFixtures.page([], pageNumber: nil)
        let (urls, cleanup) = try PhotoFixtures.write([blank])
        defer { cleanup() }
        await #expect(throws: DocumentImportError.empty) { try await importer.importPhotos(at: urls, languageHint: nil) }
        await #expect(throws: DocumentImportError.empty) { try await importer.importPhotos(at: [], languageHint: nil) }
        // Eine leere Seite zwischen guten wird gemeldet, der Rest bleibt.
        let good = PhotoFixtures.page(PhotoFixtures.paragraphsDE[0], pageNumber: 1)
        let (urls2, cleanup2) = try PhotoFixtures.write([good, blank])
        defer { cleanup2() }
        let r = try await importer.importPhotos(at: urls2, languageHint: "de")
        #expect(r.unreadablePages == [1])
        #expect(PhotoFixtures.texts(r.document).joined().contains("Antrag"))
    }

    // MARK: Randfilter ohne OCR

    @Test func edgeFilterDropsOnlyTouchingLines() {
        func raw(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat) -> OCR.Raw {
            OCR.Raw(text: "x", left: CGPoint(x: x, y: y), w: w, h: 30, angle: 0, paragraph: 0)
        }
        let size = CGSize(width: 1000, height: 1400)
        let lines = [raw(100, 1200, 700), raw(100, 1100, 700), raw(100, 1000, 700), raw(100, 900, 700), raw(-200, 800, 500)]
        let kept = OCR.dropEdgeLines(lines, pageSize: size, margin: 0.012)
        #expect(kept.count == 4)
        #expect(OCR.dropEdgeLines(lines, pageSize: size, margin: 0).count == 5, "0 = aus")
        // Enges Foto: mehr als ein Viertel berührt den Rand -> nichts verwerfen.
        let tight = (0..<6).map { raw(2, CGFloat(1300 - $0 * 100), 996) }
        #expect(OCR.dropEdgeLines(tight, pageSize: size, margin: 0.012).count == 6)
    }

    @Test func rotationHelperTurnsPixelsClockwise() throws {
        // 2×1-Bild: links schwarz, rechts weiß. Eine Vierteldrehung im Uhrzeigersinn: oben schwarz, unten weiß.
        let ctx = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let turned = try #require(PhotoOrientation.rotate(ctx.makeImage()!, clockwiseQuarterTurns: 1))
        #expect(turned.width == 1 && turned.height == 2)
        let data = try #require(turned.dataProvider?.data) as Data
        // Zeile 0 = oben
        #expect(data[0] < 10, "oben schwarz")
        #expect(data[Int(turned.bytesPerRow)] > 245, "unten weiß")
    }
}

final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    func add(_ v: Int) { lock.lock(); _values.append(v); lock.unlock() }
    var values: [Int] { lock.lock(); defer { lock.unlock() }; return _values }
}
