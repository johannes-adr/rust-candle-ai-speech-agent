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

    /// Liest ein Bild und liefert Zeilen in „Seitenkoordinaten“ der Größe `pageSize`.
    /// - Parameter language: Kürzel des Dokuments, falls bekannt. Sonst automatische Erkennung.
    static func recognize(image: CGImage, pageSize: CGSize, pageIndex: Int, language: String?) throws -> [PageLine] {
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
        // Rohdaten: Text, Zeilenhöhe/-breite aus den gedrehten Ecken, linker Mittelpunkt, Winkel.
        // (Das achsenparallele `boundingBox` ist bei schief fotografierten Seiten zu hoch.)
        struct Raw { var text: String; var left: CGPoint; var w: CGFloat; var h: CGFloat; var angle: CGFloat }
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
                    angle: atan2(tr.y - tl.y, tr.x - tl.x)
                ))
            } else {
                let bb = obs.boundingBox
                raws.append(Raw(
                    text: text, left: CGPoint(x: bb.minX * pageSize.width, y: bb.midY * pageSize.height),
                    w: bb.width * pageSize.width, h: bb.height * pageSize.height, angle: 0
                ))
            }
        }
        // Schiefstand der Seite = Mittelwert der Zeilenwinkel; Zeilen werden zurückgedreht.
        let angles = raws.filter { $0.w > pageSize.width * 0.15 }.map(\.angle).sorted()
        let skew = angles.isEmpty ? 0 : angles[angles.count / 2]
        let cs = cos(skew), sn = sin(skew)
        var lines: [PageLine] = []
        for r in raws {
            let x = r.left.x * cs + r.left.y * sn
            let y = -r.left.x * sn + r.left.y * cs
            let rect = CGRect(x: x, y: y - r.h / 2, width: r.w, height: r.h)
            // Zeilenhöhe ≈ 1,2–1,3 Schriftgrößen (Ober- und Unterlängen).
            lines.append(PageLine(r.text, rect: rect, fontSize: r.h / 1.25, isBold: false, page: pageIndex))
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
