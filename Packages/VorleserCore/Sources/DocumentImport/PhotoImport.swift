// Fotos von Seiten (Handy, iPhone über Continuity Camera) zu einem Dokument: mehrere Bilder in der
// Reihenfolge der Aufnahme, Drehung (90°/180°) erkennen, angeschnittene Ränder verwerfen, Schiefstand
// herausrechnen (OCR.finish), dann dieselbe Bereinigung wie bei PDF (Seitenzahlen, wiederkehrende Kopfzeilen).
import CoreGraphics
import Foundation
import ImageIO
import TextPrep
import Vision

/// Drehung eines Fotos: wie oft es im Uhrzeigersinn um 90° gedreht werden muss, damit der Text aufrecht steht.
enum PhotoOrientation {
    /// Lange Seite der Bilder, auf der die Drehung geprüft wird (schnell genug für vier Läufe).
    static let probeLongSide: CGFloat = 1400
    /// Eine andere Drehung muss mindestens so viel mehr Text finden als die Ausgangslage.
    static let requiredGain = 1.6
    /// Mindestwert (Summe Sicherheit × Buchstaben), damit überhaupt von „Text gefunden“ die Rede ist.
    static let minScore = 25.0

    static func uprightTurns(for image: CGImage) -> Int {
        var scores: [Double] = []
        for k in 0..<4 {
            guard let probe = rotate(image, clockwiseQuarterTurns: k, longSide: probeLongSide) else { scores.append(0); continue }
            scores.append(score(probe))
            // Schon die Ausgangslage klar gut: keine Zeit für die anderen drei verschwenden.
            if k == 0, scores[0] >= 400 { return 0 }
        }
        guard let best = scores.indices.max(by: { scores[$0] < scores[$1] }), best != 0 else { return 0 }
        return scores[best] >= minScore && scores[best] >= scores[0] * requiredGain ? best : 0
    }

    /// Wie viel lesbarer Text steht im Bild? Summe aus Sicherheit × Buchstaben je Zeile (schneller Durchgang).
    static func score(_ image: CGImage) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.automaticallyDetectsLanguage = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return 0 }
        var total = 0.0
        for obs in request.results ?? [] {
            guard let c = obs.topCandidates(1).first, c.confidence >= 0.4 else { continue }
            total += Double(c.confidence) * Double(TextHelpers.letterCount(c.string))
        }
        return total
    }

    /// Dreht (und verkleinert auf `longSide`, wenn gesetzt) ein Bild um Vierteldrehungen im Uhrzeigersinn.
    static func rotate(_ image: CGImage, clockwiseQuarterTurns k: Int, longSide: CGFloat? = nil) -> CGImage? {
        let turns = ((k % 4) + 4) % 4
        let scale = longSide.map { min(1, $0 / CGFloat(max(image.width, image.height))) } ?? 1
        let w = max(1, (CGFloat(image.width) * scale).rounded()), h = max(1, (CGFloat(image.height) * scale).rounded())
        if turns == 0, scale == 1 { return image }
        let swap = turns % 2 == 1
        let outW = Int(swap ? h : w), outH = Int(swap ? w : h)
        guard let ctx = CGContext(
            data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        // Punkt (x, y) mit y nach oben: 90° im Uhrzeigersinn ergibt (y, w − x).
        let t: CGAffineTransform
        switch turns {
        case 1: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: t = .identity
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: outW, height: outH))
        ctx.concatenate(t)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}

extension DocumentImporter {
    /// Anteil der Bildgröße am Rand, in dem angeschnittene Zeilen verworfen werden.
    static let photoEdgeMargin: CGFloat = 0.012

    /// Liest mehrere Fotos (eine Seite je Bild, in dieser Reihenfolge) als ein Dokument.
    /// - Parameter progress: wird vor jeder Seite mit (Nummer ab 1, Anzahl) aufgerufen.
    public func importPhotos(
        at urls: [URL], languageHint: String?, progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> ImportResult {
        guard !urls.isEmpty else { throw DocumentImportError.empty }
        var pages: [PageLayout] = []
        var turnsByPage: [Int: Int] = [:]
        var unreadable: [Int] = []
        var language = languageHint
        for (i, url) in urls.enumerated() {
            try Task.checkCancellation()
            progress?(i + 1, urls.count)
            guard let loaded = OCR.loadImage(at: url) else { unreadable.append(i); continue }
            let turns = PhotoOrientation.uprightTurns(for: loaded)
            guard let image = PhotoOrientation.rotate(loaded, clockwiseQuarterTurns: turns) else { unreadable.append(i); continue }
            if turns != 0 { turnsByPage[i] = turns }
            let size = CGSize(width: image.width, height: image.height)
            var lines = try await OCR.recognize(
                image: image, pageSize: size, pageIndex: i, language: language, engine: ocrEngine, edgeMargin: Self.photoEdgeMargin)
            if language == nil {
                language = TextHelpers.detectLanguage(lines.map(\.text).joined(separator: " "))
                if language != nil, !OCR.visionLanguages(for: language).isEmpty {
                    // Zweiter Durchgang mit bekannter Sprache (bessere Sprachkorrektur), nur für die erste Seite.
                    lines = try await OCR.recognize(
                        image: image, pageSize: size, pageIndex: i, language: language, engine: ocrEngine, edgeMargin: Self.photoEdgeMargin)
                }
            }
            if lines.isEmpty { unreadable.append(i); continue }
            pages.append(PageLayout(index: i, size: size, lines: lines, fromOCR: true))
        }
        let (doc, report) = cleaner.clean(pages: pages, language: language)
        guard !doc.blocks.isEmpty else { throw DocumentImportError.empty }
        var result = ImportResult(
            document: doc, report: report, pageCount: urls.count, ocrPages: Array(urls.indices), language: report.language ?? language)
        result.rotatedPages = turnsByPage
        result.unreadablePages = unreadable
        return result
    }
}
