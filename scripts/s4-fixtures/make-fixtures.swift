// Erzeugt die synthetischen Test-PDFs für Spike S4 (nur Testdaten-Generator, nicht Teil der App).
//
//   swiftc -O scripts/s4-fixtures/make-fixtures.swift -o /tmp/make-fixtures
//   /tmp/make-fixtures Packages/VorleserCore/Tests/DocumentImportTests/Fixtures
//
// Alle Texte sind erfunden. Die Dokumente bilden typische Fälle nach:
//   behoerdenbrief.pdf   2 Seiten, Kopf-/Fußzeile, Adressblock, Betreff (fett), Tabelle
//   zeitung.pdf          2 Seiten, Schlagzeile über zwei Spalten, Blocksatz, Zwischentitel, Bildunterschrift
//   buch.pdf             4 Seiten, Silbentrennung, Kapitelüberschriften, Einzug, Fußnote, Seitenzahlen, Kolumnentitel
//   portugiesisch.pdf    2 Seiten wie der Brief, aber Portugiesisch (Akzente, Silbentrennung)
//   scan.pdf             1 Seite, nur ein Bild (kein Text) -> OCR
//   foto.jpg             leicht gedrehtes, verrauschtes „Handy-Foto“ einer Seite -> OCR
import CoreGraphics
import CoreText
import Foundation
import ImageIO

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let W: CGFloat = 595, H: CGFloat = 842

// MARK: Werkzeuge

func font(_ name: String, _ size: CGFloat) -> CTFont { CTFontCreateWithName(name as CFString, size, nil) }

func pstyle(align: CTTextAlignment, first: CGFloat, after: CGFloat) -> CTParagraphStyle {
    var a = align, f = first, s = after
    return withUnsafePointer(to: &a) { pa in
        withUnsafePointer(to: &f) { pf in
            withUnsafePointer(to: &s) { ps in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pa),
                    CTParagraphStyleSetting(spec: .firstLineHeadIndent, valueSize: MemoryLayout<CGFloat>.size, value: pf),
                    CTParagraphStyleSetting(spec: .paragraphSpacing, valueSize: MemoryLayout<CGFloat>.size, value: ps),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }
}

/// Fügt weiche Trennstriche an echten Silbengrenzen ein (Wörter ab 8 Buchstaben).
func hyphenated(_ text: String, locale: String) -> String {
    let loc = Locale(identifier: locale) as CFLocale
    var out = ""
    for (i, word) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
        if i > 0 { out += " " }
        let w = String(word)
        let letters = w.filter { $0.isLetter }.count
        guard letters >= 8, !w.contains("\u{00AD}") else { out += w; continue }
        let cf = w as NSString
        var result = ""
        var last = 0
        for idx in 1..<cf.length {
            let loc2 = CFStringGetHyphenationLocationBeforeIndex(cf, idx, CFRange(location: 0, length: cf.length), 0, loc, nil)
            if loc2 != kCFNotFound, loc2 > last, loc2 < cf.length {
                result += cf.substring(with: NSRange(location: last, length: loc2 - last)) + "\u{00AD}"
                last = loc2
            }
        }
        result += cf.substring(from: last)
        out += result
    }
    return out
}

struct Para {
    var text: String
    var fontName = "Helvetica"
    var size: CGFloat = 11
    var align: CTTextAlignment = .left
    var first: CGFloat = 0
    var after: CGFloat = 8
    var superscriptAt: [String] = []  // Teilstrings, die hochgestellt werden
}

func attributed(_ paras: [Para], locale: String?) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for p in paras {
        let t = (locale != nil ? hyphenated(p.text, locale: locale!) : p.text) + "\n"
        let a = NSMutableAttributedString(string: t, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font(p.fontName, p.size),
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): pstyle(align: p.align, first: p.first, after: p.after),
        ])
        for s in p.superscriptAt {
            let r = (a.string as NSString).range(of: s)
            if r.location != NSNotFound { a.addAttribute(NSAttributedString.Key(kCTSuperscriptAttributeName as String), value: 1, range: r) }
        }
        result.append(a)
    }
    return result
}

func drawText(_ ctx: CGContext, _ s: String, font name: String = "Helvetica", size: CGFloat, x: CGFloat, y: CGFloat, center: Bool = false, right: Bool = false) {
    let a = NSAttributedString(string: s, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font(name, size)])
    let line = CTLineCreateWithAttributedString(a)
    var px = x
    let w = CTLineGetTypographicBounds(line, nil, nil, nil)
    if center { px = x - CGFloat(w) / 2 } else if right { px = x - CGFloat(w) }
    ctx.textPosition = CGPoint(x: px, y: y)
    CTLineDraw(line, ctx)
}

/// Setzt die Absätze selbst Zeile für Zeile (greedy), damit an weichen Trennstrichen
/// ein echter Bindestrich erscheint (CoreText zeichnet ihn nicht). Läuft durch die Bereiche
/// (Spalten) Seite für Seite.
@discardableResult
func flow(_ ctx: CGContext, _ paras: [Para], locale: String?, regions: (Int) -> [CGRect], decorate: (CGContext, Int) -> Void) -> Int {
    var page = -1, regionIdx = 0
    var y: CGFloat = 0
    var region = CGRect.zero
    func newRegion() {
        let rs = regions(max(page, 0))
        if page >= 0, regionIdx + 1 < rs.count {
            regionIdx += 1
        } else {
            if page >= 0 { ctx.endPDFPage() }
            page += 1
            regionIdx = 0
            ctx.beginPDFPage(nil)
            ctx.textMatrix = .identity
            decorate(ctx, page)
        }
        region = regions(page)[regionIdx]
        y = region.maxY
    }
    newRegion()
    for p in paras {
        let text = locale != nil ? hyphenated(p.text, locale: locale!) : p.text
        let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font(p.fontName, p.size)]
        let full = NSMutableAttributedString(string: text, attributes: attrs)
        for sub in p.superscriptAt {
            let r = (text as NSString).range(of: sub)
            if r.location != NSNotFound { full.addAttribute(NSAttributedString.Key(kCTSuperscriptAttributeName as String), value: 1, range: r) }
        }
        let ts = CTTypesetterCreateWithAttributedString(full)
        var start = 0
        var first = true
        let lh = p.size * 1.22
        while start < full.length {
            let indent = first ? p.first : 0
            let width = region.width - indent
            var count = CTTypesetterSuggestLineBreak(ts, start, Double(width - 4))
            if count <= 0 { count = full.length - start }
            let isLast = start + count >= full.length
            let sub = full.attributedSubstring(from: NSRange(location: start, length: count)).mutableCopy() as! NSMutableAttributedString
            // weiche Trennstriche: nur am Zeilenende sichtbar als „-“
            var endsSoft = false
            var i = sub.length - 1
            while i >= 0 {
                if (sub.string as NSString).character(at: i) == 0x00AD {
                    if i == sub.length - 1 { sub.replaceCharacters(in: NSRange(location: i, length: 1), with: "-"); endsSoft = true } else { sub.deleteCharacters(in: NSRange(location: i, length: 1)) }
                }
                i -= 1
            }
            // Leerzeichen am Zeilenende abschneiden
            while sub.length > 0, (sub.string as NSString).character(at: sub.length - 1) == 0x20 { sub.deleteCharacters(in: NSRange(location: sub.length - 1, length: 1)) }
            _ = endsSoft
            if y - lh < region.minY { newRegion() }
            var line = CTLineCreateWithAttributedString(sub)
            if p.align == .justified, !isLast, let j = CTLineCreateJustifiedLine(line, 1.0, Double(width)) { line = j }
            let flush: CGFloat = p.align == .center ? 0.5 : (p.align == .right ? 1 : 0)
            let off = CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(width)))
            y -= p.size * 0.95
            ctx.textPosition = CGPoint(x: region.minX + indent + off, y: y)
            CTLineDraw(line, ctx)
            y -= lh - p.size * 0.95
            start += count
            first = false
        }
        y -= p.after
    }
    ctx.endPDFPage()
    return page + 1
}

func makePDF(_ name: String, _ body: (CGContext) -> Void) {
    var box = CGRect(x: 0, y: 0, width: W, height: H)
    let url = outDir.appendingPathComponent(name)
    guard let ctx = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle as String: name] as CFDictionary) else { fatalError("PDF") }
    body(ctx)
    ctx.closePDF()
    print("geschrieben:", name)
}

// MARK: Texte

let briefParas: [Para] = [
    Para(text: "Betreff: Ihr Antrag auf Wohngeld vom 3. Februar 2025, Aktenzeichen 123/45-6", fontName: "Helvetica-Bold", size: 11, after: 14),
    Para(text: "Sehr geehrte Frau Mustermann,", after: 8),
    Para(text: "vielen Dank für Ihren Antrag auf Wohngeld, der am 3. Februar 2025 bei uns eingegangen ist. Wir haben Ihre Unterlagen geprüft und möchten Sie über den Stand des Verfahrens informieren. Leider fehlen für die abschließende Bearbeitung noch einige Nachweise, die wir Ihnen im Folgenden aufführen."),
    Para(text: "Bitte reichen Sie bis spätestens zum 31. März 2025 eine aktuelle Mietbescheinigung Ihres Vermieters sowie die Einkommensnachweise der letzten drei Monate ein. Sollten Sie die Unterlagen nicht fristgerecht vorlegen, müssen wir Ihren Antrag nach der geltenden Rechtslage ablehnen. Das möchten wir nach Möglichkeit vermeiden."),
    Para(text: "Nach den bisher vorliegenden Angaben ergibt sich die folgende vorläufige Berechnung. Alle Beträge sind in Euro angegeben und werden nach Eingang der Nachweise noch einmal überprüft."),
    Para(text: "Für die Vorlage der Unterlagen stehen Ihnen folgende Möglichkeiten zur Verfügung: persönlich im Bürgerbüro während der Öffnungszeiten, per Post an die oben genannte Adresse oder über das Online-Portal der Stadt. Bei Fragen erreichen Sie Ihren Sachbearbeiter, Herrn Beispiel, unter der angegebenen Telefonnummer. Bitte halten Sie dazu das Aktenzeichen bereit."),
    Para(text: "Wir weisen darauf hin, dass für die Bearbeitung Ihres Antrags keine Kosten anfallen. Gegen diesen Bescheid können Sie innerhalb eines Monats nach Bekanntgabe schriftlich Widerspruch einlegen. Der Widerspruch ist bei der oben genannten Stelle einzureichen."),
    Para(text: "Mit freundlichen Grüßen", after: 24),
    Para(text: "Im Auftrag", after: 2),
    Para(text: "Hans Beispiel", after: 2),
]

let briefTable: [[String]] = [
    ["Position", "Monatlich", "Jährlich"],
    ["Grundmiete", "450,00 €", "5.400,00 €"],
    ["Nebenkosten", "120,50 €", "1.446,00 €"],
    ["Heizkosten", "75,00 €", "900,00 €"],
    ["Summe", "645,50 €", "7.746,00 €"],
]

let ptParas: [Para] = [
    Para(text: "Assunto: Pedido de apoio à habitação de 3 de fevereiro de 2025, processo n.º 123/45-6", fontName: "Helvetica-Bold", size: 11, after: 14),
    Para(text: "Exma. Senhora Maria Mustermann,", after: 8),
    Para(text: "Agradecemos o seu pedido de apoio à habitação, que deu entrada nos nossos serviços a 3 de fevereiro de 2025. Analisámos a documentação apresentada e gostaríamos de informá-la sobre o estado do processo. Infelizmente, faltam ainda alguns documentos necessários para a decisão final, que indicamos de seguida."),
    Para(text: "Solicitamos que entregue, até ao dia 31 de março de 2025, uma declaração atualizada do senhorio e os comprovativos de rendimentos dos últimos três meses. Caso os documentos não sejam apresentados dentro do prazo, seremos obrigados a indeferir o pedido de acordo com a legislação em vigor. Queremos evitar essa situação sempre que possível."),
    Para(text: "A entrega pode ser feita presencialmente no balcão de atendimento durante o horário de funcionamento, por correio para a morada acima indicada ou através do portal eletrónico do município. Para esclarecimentos, pode contactar o técnico responsável, o senhor Beispiel, através do número de telefone indicado. O custo do serviço é de 19,99 euros por certidão adicional."),
    Para(text: "Informamos ainda que a apreciação do pedido não implica quaisquer custos. Da decisão pode apresentar reclamação, por escrito, no prazo de um mês após a notificação. A reclamação deve ser dirigida ao serviço acima identificado, acompanhada de todos os elementos que considere relevantes."),
    Para(text: "Com os melhores cumprimentos,", after: 24),
    Para(text: "Pela Câmara Municipal", after: 2),
    Para(text: "Hans Beispiel", after: 2),
]

let zeitungParas: [Para] = {
    let body = "Der Gemeinderat hat am Montagabend mit großer Mehrheit den Bau eines neuen Radwegs entlang der Hauptstraße beschlossen. Die Strecke soll rund drei Kilometer lang werden und die Innenstadt mit dem Schulzentrum im Norden verbinden. Die Kosten werden auf etwa 1,2 Millionen Euro geschätzt, von denen das Land zwei Drittel übernimmt."
    let body2 = "Bürgermeisterin Clara Beispiel sprach von einem wichtigen Schritt für die Verkehrswende vor Ort. Besonders für Schülerinnen und Schüler werde der Schulweg deutlich sicherer. Die Opposition kritisierte dagegen, dass dafür Parkplätze wegfallen müssten und die Anwohner zu spät informiert worden seien."
    let body3 = "Nach Angaben der Verwaltung beginnen die Bauarbeiten frühestens im Herbst. Zuvor müssen noch Leitungen verlegt und mehrere Bäume umgepflanzt werden. Während der Bauzeit wird die Hauptstraße abschnittsweise halbseitig gesperrt, der Busverkehr soll jedoch weitgehend aufrechterhalten werden."
    var p: [Para] = []
    let st: (String) -> Para = { Para(text: $0, fontName: "Times-Roman", size: 10, align: .justified, first: 0, after: 6) }
    p.append(st(body))
    p.append(Para(text: "Streit um die Parkplätze", fontName: "Times-Bold", size: 12, after: 4))
    p.append(st(body2))
    p.append(Para(text: "Abbildung 1: Der geplante Verlauf des Radwegs entlang der Hauptstraße.", fontName: "Times-Italic", size: 8, after: 8))
    p.append(st(body3))
    p.append(st(body))
    p.append(Para(text: "Was die Bürger sagen", fontName: "Times-Bold", size: 12, after: 4))
    p.append(st(body2))
    p.append(st(body3))
    p.append(st(body2))
    p.append(st(body3))
    p.append(st(body))
    return p + Array(p.dropFirst())
}()

let bookBank: [String] = [
    "Als der Zug den Bahnhof verließ, lag über der Stadt noch der Nebel des frühen Morgens. Anna presste die Stirn gegen das kalte Fenster und sah zu, wie die Häuser kleiner wurden. Sie hatte lange gezögert, bevor sie sich zu dieser Reise entschlossen hatte, und nun, da es kein Zurück mehr gab, fühlte sie eine merkwürdige Ruhe.",
    "Ihr Großvater hatte oft von dem Haus am Meer erzählt, von den weißen Mauern und dem alten Feigenbaum im Garten. Nie hatte sie geglaubt, dass sie es eines Tages selbst sehen würde. Nun trug sie den Schlüssel in ihrer Manteltasche, schwer und kühl, und bei jedem Halt tastete sie danach, als könnte er unterwegs verschwinden.",
    "Am Nachmittag erreichten sie die Berge. Die Landschaft veränderte sich, die Wiesen wurden steiler, und zwischen den Tannen blitzten Wasserfälle auf. Ein älterer Herr im Abteil erklärte ihr, dass die Strecke im neunzehnten Jahrhundert gebaut worden sei und dass damals viele Arbeiter beim Tunnelbau ihr Leben verloren hätten.",
    "In der Dämmerung hielt der Zug in einem kleinen Ort, dessen Namen sie nicht kannte. Reisende stiegen aus, andere stiegen ein, und auf dem Bahnsteig verkaufte eine Frau warme Kastanien. Anna kaufte eine Tüte und genoss die Wärme in ihren Händen, während der Zug langsam wieder anfuhr.",
    "Spät in der Nacht, als fast alle Fahrgäste schliefen, holte sie den Brief hervor, den ihr Großvater hinterlassen hatte. Sie kannte jedes Wort auswendig, und dennoch las sie ihn noch einmal, Zeile für Zeile, als würde sich ihr der Sinn erst auf dieser Fahrt vollständig erschließen.",
    "Am nächsten Morgen empfing sie das Meer. Es lag glatt und silbern vor dem Fenster, und die Luft roch nach Salz und Tang. Anna öffnete das Fenster und atmete tief ein. Zum ersten Mal seit Wochen hatte sie das Gefühl, am richtigen Ort zu sein.",
]

func bookParas() -> [Para] {
    func body(_ s: String, footnote: Bool = false) -> Para {
        Para(text: s, fontName: "Times-Roman", size: 11, align: .justified, first: 16, after: 0, superscriptAt: footnote ? ["1"] : [])
    }
    var p: [Para] = []
    p.append(Para(text: "Die Reise nach Süden", fontName: "Times-Bold", size: 24, align: .center, after: 18))
    p.append(Para(text: "Der Aufbruch", fontName: "Times-Bold", size: 15, after: 8))
    p.append(body(bookBank[0]))
    p.append(body(bookBank[1] + "1", footnote: true))
    p.append(body(bookBank[2]))
    p.append(Para(text: "Die Nacht im Zug", fontName: "Times-Bold", size: 15, after: 8))
    p.append(body(bookBank[3]))
    p.append(body(bookBank[4]))
    p.append(body(bookBank[5]))
    p.append(body(bookBank[0]))
    p.append(body(bookBank[2]))
    p.append(body(bookBank[1]))
    p.append(body(bookBank[4]))
    p.append(body(bookBank[3]))
    p.append(body(bookBank[5]))
    return p + Array(p.dropFirst(2)) + Array(p.dropFirst(2))
}

let scanParas: [Para] = [
    Para(text: "Mietvertrag über Wohnraum", fontName: "Times-Bold", size: 16, after: 12),
    Para(text: "Zwischen Herrn Karl Beispiel als Vermieter und Frau Maria Mustermann als Mieterin wird folgender Vertrag geschlossen.", fontName: "Times-Roman", size: 12, after: 8),
    Para(text: "Der Vermieter vermietet der Mieterin die Wohnung im zweiten Obergeschoss des Hauses Beispielweg 7 in Musterstadt. Die Wohnung besteht aus drei Zimmern, Küche, Bad und einem Balkon. Das Mietverhältnis beginnt am 1. April 2025 und läuft auf unbestimmte Zeit.", fontName: "Times-Roman", size: 12, after: 8),
    Para(text: "Die monatliche Miete beträgt 450,00 Euro zuzüglich 120,50 Euro Nebenkosten. Die Miete ist jeweils bis zum dritten Werktag eines Monats im Voraus zu zahlen. Die Mieterin hinterlegt eine Kaution in Höhe von drei Monatsmieten.", fontName: "Times-Roman", size: 12, after: 8),
    Para(text: "Beide Seiten können das Mietverhältnis mit einer Frist von drei Monaten zum Monatsende schriftlich kündigen. Änderungen und Ergänzungen dieses Vertrages bedürfen der Schriftform.", fontName: "Times-Roman", size: 12, after: 8),
]

// MARK: Dokumente bauen

func briefLike(_ name: String, paras: [Para], locale: String, header: String, footer: (Int, Int) -> String, address: [String], date: String, sender: String, table: [[String]]?) {
    let total = 2
    makePDF(name) { ctx in
        let pages = flow(ctx, paras, locale: locale, regions: { page in
            page == 0 ? [CGRect(x: 70, y: 250, width: 455, height: 350)] : [CGRect(x: 70, y: table != nil ? 330 : 110, width: 455, height: table != nil ? 400 : 620)]
        }, decorate: { c, page in
            drawText(c, header, size: 9, x: 70, y: H - 40)
            drawText(c, footer(page + 1, total), size: 8, x: W / 2, y: 36, center: true)
            if page == 0 {
                drawText(c, sender, size: 7, x: 70, y: 700)
                var y: CGFloat = 680
                for l in address { drawText(c, l, size: 11, x: 70, y: y); y -= 14 }
                drawText(c, date, size: 11, x: 525, y: 612, right: true)
            } else if let table {
                var y: CGFloat = 300
                for (r, row) in table.enumerated() {
                    let f = (r == 0 || r == table.count - 1) ? "Helvetica-Bold" : "Helvetica"
                    drawText(c, row[0], font: f, size: 11, x: 70, y: y)
                    drawText(c, row[1], font: f, size: 11, x: 330, y: y, right: true)
                    drawText(c, row[2], font: f, size: 11, x: 460, y: y, right: true)
                    y -= 16
                }
            }
        })
        precondition(pages == total, "\(name): \(pages) statt \(total) Seiten")
    }
}

briefLike("behoerdenbrief.pdf", paras: briefParas, locale: "de",
          header: "Stadtverwaltung Musterstadt · Amt für Soziales und Wohnen",
          footer: { "Seite \($0) von \($1) · Telefon 01234 567890 · www.musterstadt.example" },
          address: ["Frau", "Maria Mustermann", "Beispielweg 7", "12345 Musterstadt"],
          date: "Musterstadt, den 14. März 2025",
          sender: "Stadtverwaltung Musterstadt, Postfach 1234, 12345 Musterstadt", table: briefTable)

briefLike("portugiesisch.pdf", paras: ptParas, locale: "pt",
          header: "Câmara Municipal de Exemplo · Serviço de Ação Social e Habitação",
          footer: { "Página \($0) de \($1) · Telefone 912 345 678 · www.exemplo.example" },
          address: ["Exma. Senhora", "Maria Mustermann", "Rua do Exemplo, 7", "1000-001 Exemplo"],
          date: "Exemplo, 14 de março de 2025",
          sender: "Câmara Municipal de Exemplo, Apartado 1234, 1000-001 Exemplo", table: nil)

makePDF("zeitung.pdf") { ctx in
    let n = flow(ctx, zeitungParas, locale: "de", regions: { page in
        let top: CGFloat = page == 0 ? 640 : 740
        return [CGRect(x: 50, y: 70, width: 240, height: top - 70), CGRect(x: 305, y: 70, width: 240, height: top - 70)]
    }, decorate: { c, page in
        drawText(c, "Musterstädter Tageblatt · Dienstag, 18. März 2025", font: "Times-Italic", size: 9, x: 50, y: H - 36)
        drawText(c, "\(page + 1)", size: 9, x: W / 2, y: 36, center: true)
        if page == 0 {
            drawText(c, "Gemeinderat beschließt neuen Radweg", font: "Times-Bold", size: 28, x: W / 2, y: 745, center: true)
            drawText(c, "Mehrheit stimmt für drei Kilometer lange Strecke an der Hauptstraße", font: "Times-Italic", size: 12, x: W / 2, y: 715, center: true)
            drawText(c, "Von Anna Beispiel", font: "Times-Roman", size: 9, x: W / 2, y: 690, center: true)
        }
    })
    precondition(n == 2, "zeitung: \(n) Seiten")
}

makePDF("buch.pdf") { ctx in
    let n = flow(ctx, bookParas(), locale: "de", regions: { _ in [CGRect(x: 85, y: 110, width: 425, height: 620)] }, decorate: { c, page in
        drawText(c, page % 2 == 0 ? "Anna Beispiel · Die Reise nach Süden" : "Der Aufbruch", font: "Times-Italic", size: 9, x: W / 2, y: H - 50, center: true)
        drawText(c, "\(page + 1)", font: "Times-Roman", size: 10, x: W / 2, y: 60, center: true)
        if page == 0 {
            drawText(c, "1 Vgl. Meyer, Reisen im 19. Jahrhundert, Berlin 1987, S. 42.", font: "Times-Roman", size: 8, x: 85, y: 92)
        }
    })
    precondition(n >= 3, "buch: \(n) Seiten")
    print("buch: \(n) Seiten")
}

// MARK: Scan und Foto (nur Bild, kein Text)

func renderBitmapPage(dpi: CGFloat) -> CGImage {
    let s = dpi / 72
    let w = Int(W * s), h = Int(H * s)
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(CGColor(gray: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.scaleBy(x: s, y: s)
    ctx.textMatrix = .identity
    let fs = CTFramesetterCreateWithAttributedString(attributed(scanParas, locale: nil))
    let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: CGRect(x: 70, y: 400, width: 455, height: 330), transform: nil), nil)
    CTFrameDraw(frame, ctx)
    return ctx.makeImage()!
}

func jpegData(_ image: CGImage, quality: Double) -> Data {
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    CGImageDestinationFinalize(dest)
    return data as Data
}

let scanImage = renderBitmapPage(dpi: 150)
let scanJPEG = jpegData(scanImage, quality: 0.5)
let scanCG = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(scanJPEG as CFData, nil)!, 0, nil)!
makePDF("scan.pdf") { ctx in
    ctx.beginPDFPage(nil)
    ctx.draw(scanCG, in: CGRect(x: 0, y: 0, width: W, height: H))
    ctx.endPDFPage()
}

// Foto: gedreht, mit Schatten und Rauschen, kleiner aufgelöst
do {
    let src = renderBitmapPage(dpi: 130)
    let w = 1100, h = 1500
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
    ctx.setFillColor(CGColor(gray: 0.35, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
    ctx.rotate(by: 2.5 * .pi / 180)
    let pw = CGFloat(w) * 0.96, ph = pw * H / W
    ctx.draw(src, in: CGRect(x: -pw / 2, y: -ph / 2 + 40, width: pw, height: ph))
    ctx.rotate(by: -2.5 * .pi / 180)
    ctx.translateBy(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2)
    // Schattenverlauf von links
    let grad = CGGradient(colorSpace: CGColorSpaceCreateDeviceGray(), colorComponents: [0, 0.45, 0, 0], locations: [0, 1], count: 2)!
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: CGFloat(w), y: 0), options: [])
    // Rauschen
    var rng = SystemRandomNumberGenerator()
    ctx.setBlendMode(.normal)
    for _ in 0..<6000 {
        ctx.setFillColor(CGColor(gray: CGFloat.random(in: 0.2...0.9, using: &rng), alpha: 0.25))
        ctx.fill(CGRect(x: Int.random(in: 0..<w, using: &rng), y: Int.random(in: 0..<h, using: &rng), width: 2, height: 2))
    }
    let data = jpegData(ctx.makeImage()!, quality: 0.4)
    try! data.write(to: outDir.appendingPathComponent("foto.jpg"))
    print("geschrieben: foto.jpg")
}
