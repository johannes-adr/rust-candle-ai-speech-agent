import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Texterkennung per Vision.
///
/// Hinweis: Die Umgebung (Xcode 16.3, SDK 15.4) kennt `RecognizeDocumentsRequest`
/// (macOS 26, liefert Absätze) zur Compile-Zeit nicht. Deshalb `VNRecognizeTextRequest`
/// (genau, mit Sprachkorrektur). Die Absätze baut dann dieselbe Bereinigung wie bei PDF-Text.
enum OCR {
    /// Zeilen unterhalb dieser Sicherheit werden verworfen (Rauschen).
    static let minConfidence: Float = 0.3
    /// Lange Seite des Bildes beim Rendern (Pixel). ≈ 250 dpi bei A4.
    static let renderLongSide: CGFloat = 2900

    /// Vision-Sprachkennungen für unsere Kürzel; nur, was Vision wirklich kann.
    static func visionLanguages(for code: String?) -> [String] {
        guard let code else { return [] }
        let candidates: [String: [String]] = [
            "de": ["de-DE"], "pt": ["pt-BR", "pt-PT"], "en": ["en-US"], "es": ["es-ES"], "fr": ["fr-FR"],
            "it": ["it-IT"], "ru": ["ru-RU"], "zh": ["zh-Hans", "zh-Hant"], "ja": ["ja-JP"], "ko": ["ko-KR"],
        ]
        let supported = (try? VNRecognizeTextRequest.supportedRecognitionLanguages(for: .accurate, revision: VNRecognizeTextRequestRevision3)) ?? []
        return (candidates[code] ?? []).filter { supported.contains($0) }
    }

    /// Rendert eine PDF-Seite weiß hinterlegt als Bild.
    static func render(page: PDFPage) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = min(max(renderLongSide / max(box.width, box.height), 1), 6)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        return ctx.makeImage()
    }

    enum Engine: Sendable { case documents, text }

    /// Rohzeile aus der Texterkennung: Zeilenhöhe/-breite aus den gedrehten Ecken, linker Mittelpunkt, Winkel.
    /// (Das achsenparallele `boundingBox` ist bei schief fotografierten Seiten zu hoch.)
    struct Raw { var text: String; var left: CGPoint; var w: CGFloat; var h: CGFloat; var angle: CGFloat; var paragraph: Int }

    /// Liest ein Bild und liefert Zeilen in „Seitenkoordinaten“ der Größe `pageSize`.
    /// Hauptweg ist `RecognizeDocumentsRequest` (macOS 26, liefert Absätze); fällt auf
    /// `VNRecognizeTextRequest` zurück, wenn er fehlschlägt oder nichts findet.
    /// - Parameter language: Kürzel des Dokuments, falls bekannt. Sonst automatische Erkennung.
    /// - Parameter edgeMargin: > 0 für Fotos: Zeilen, die vom Bildrand angeschnitten sind (Nachbarseite, Tisch,
    ///   halbe Seitenzahl), werden verworfen (`dropEdgeLines`). 0 = nichts verwerfen (PDF-Seiten, Scans).
    static func recognize(
        image: CGImage, pageSize: CGSize, pageIndex: Int, language: String?, engine: Engine = .documents,
        edgeMargin: CGFloat = 0
    ) async throws -> [PageLine] {
        if engine == .documents, let raws = try? await recognizeDocumentRaws(image: image, pageSize: pageSize, language: language), !raws.isEmpty {
            return finish(dropEdgeLines(raws, pageSize: pageSize, margin: edgeMargin), pageSize: pageSize, pageIndex: pageIndex)
        }
        let raws = try recognizeTextRaws(image: image, pageSize: pageSize, language: language)
        return finish(dropEdgeLines(raws, pageSize: pageSize, margin: edgeMargin), pageSize: pageSize, pageIndex: pageIndex)
    }

    /// Verwirft Zeilen, die den Bildrand (innerhalb `margin` der Bildgröße) berühren: Sie sind angeschnitten.
    /// Berührt mehr als ein Viertel der Zeilen den Rand, ist das Foto sehr eng aufgenommen; dann bleibt alles.
    static func dropEdgeLines(_ raws: [Raw], pageSize: CGSize, margin: CGFloat) -> [Raw] {
        guard margin > 0, raws.count >= 4 else { return raws }
        let mx = pageSize.width * margin, my = pageSize.height * margin
        func touches(_ r: Raw) -> Bool {
            let x0 = min(r.left.x, r.left.x + r.w * cos(r.angle))
            let x1 = max(r.left.x, r.left.x + r.w * cos(r.angle))
            let ymid = r.left.y + r.w * sin(r.angle) / 2
            return x0 < mx || x1 > pageSize.width - mx || ymid - r.h / 2 < my || ymid + r.h / 2 > pageSize.height - my
        }
        let kept = raws.filter { !touches($0) }
        return raws.count - kept.count > raws.count / 4 ? raws : kept
    }

    static func recognizeDocumentRaws(image: CGImage, pageSize: CGSize, language: String?) async throws -> [Raw] {
        var request = RecognizeDocumentsRequest()
        request.barcodeDetectionOptions.enabled = false
        request.textRecognitionOptions.useLanguageCorrection = true
        let wanted = documentLanguages(for: language, supported: request.supportedRecognitionLanguages)
        if wanted.isEmpty {
            request.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
            request.textRecognitionOptions.recognitionLanguages = wanted
            request.textRecognitionOptions.automaticallyDetectLanguage = false
        }
        let results = try await request.perform(on: image)
        guard let document = results.first?.document else { return [] }
        func pt(_ p: NormalizedPoint) -> CGPoint { CGPoint(x: p.x * pageSize.width, y: p.y * pageSize.height) }
        var raws: [Raw] = []
        for (pi, para) in document.paragraphs.enumerated() {
            for line in para.lines where line.confidence >= minConfidence {
                let text = TextHelpers.normalize(line.transcript)
                guard !text.isEmpty else { continue }
                let tl = pt(line.topLeft), tr = pt(line.topRight), bl = pt(line.bottomLeft)
                raws.append(Raw(
                    text: text, left: CGPoint(x: (tl.x + bl.x) / 2, y: (tl.y + bl.y) / 2),
                    w: hypot(tr.x - tl.x, tr.y - tl.y), h: hypot(tl.x - bl.x, tl.y - bl.y),
                    angle: atan2(tr.y - tl.y, tr.x - tl.x), paragraph: pi
                ))
            }
        }
        return raws
    }

    static func documentLanguages(for code: String?, supported: [Locale.Language]) -> [Locale.Language] {
        guard let code else { return [] }
        return supported.filter { ($0.languageCode?.identifier ?? "") == (code == "zh" ? "zh" : code) }
    }

    static func recognizeTextRaws(image: CGImage, pageSize: CGSize, language: String?) throws -> [Raw] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let langs = visionLanguages(for: language)
        if langs.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = langs
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        var raws: [Raw] = []
        for obs in request.results ?? [] {
            guard let cand = obs.topCandidates(1).first, cand.confidence >= minConfidence else { continue }
            let text = TextHelpers.normalize(cand.string)
            guard !text.isEmpty else { continue }
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * pageSize.width, y: p.y * pageSize.height) }
            if let quad = try? cand.boundingBox(for: cand.string.startIndex..<cand.string.endIndex) {
                let tl = pt(quad.topLeft), tr = pt(quad.topRight), bl = pt(quad.bottomLeft)
                raws.append(Raw(
                    text: text, left: CGPoint(x: (tl.x + bl.x) / 2, y: (tl.y + bl.y) / 2),
                    w: hypot(tr.x - tl.x, tr.y - tl.y), h: hypot(tl.x - bl.x, tl.y - bl.y),
                    angle: atan2(tr.y - tl.y, tr.x - tl.x), paragraph: -1
                ))
            } else {
                let bb = obs.boundingBox
                raws.append(Raw(
                    text: text, left: CGPoint(x: bb.minX * pageSize.width, y: bb.midY * pageSize.height),
                    w: bb.width * pageSize.width, h: bb.height * pageSize.height, angle: 0, paragraph: -1
                ))
            }
        }
        return raws
    }

    /// Schiefstand der Seite = Median der Zeilenwinkel; Zeilen werden zurückgedreht.
    static func finish(_ raws: [Raw], pageSize: CGSize, pageIndex: Int) -> [PageLine] {
        let angles = raws.filter { $0.w > pageSize.width * 0.15 }.map(\.angle).sorted()
        let skew = angles.isEmpty ? 0 : angles[angles.count / 2]
        let cs = cos(skew), sn = sin(skew)
        var lines: [PageLine] = []
        for r in raws {
            let x = r.left.x * cs + r.left.y * sn
            let y = -r.left.x * sn + r.left.y * cs
            let rect = CGRect(x: x, y: y - r.h / 2, width: r.w, height: r.h)
            // Zeilenhöhe ≈ 1,2–1,3 Schriftgrößen (Ober- und Unterlängen).
            var l = PageLine(r.text, rect: rect, fontSize: r.h / 1.25, isBold: false, page: pageIndex)
            l.paragraph = r.paragraph
            lines.append(l)
        }
        return lines
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,  // EXIF-Drehung (Handy-Fotos)
                                     kCGImageSourceThumbnailMaxPixelSize: 4000]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}
