// Spike S4: liest alle PDFs (und Bilder/Word-Dateien) eines Ordners und schreibt je Datei
// die erkannten Blöcke als .txt nach spike-output/S4/ – zum Gegenlesen mit dem Original.
//
// Aufruf:  swift run spike-s4 <ordner> [--out <ausgabeordner>] [--lang de] [--ocr-alt]
import DocumentImport
import Foundation
import TextPrep

var args = Array(CommandLine.arguments.dropFirst())
var outDir = "spike-output/S4"
var lang: String?
var legacyOCR = false
var folder: String?
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--out": outDir = args.isEmpty ? outDir : args.removeFirst()
    case "--ocr-alt": legacyOCR = true  // altes VNRecognizeTextRequest statt RecognizeDocumentsRequest
    case "--lang": lang = args.isEmpty ? nil : args.removeFirst()
    default: folder = a
    }
}
guard let folder else {
    FileHandle.standardError.write(Data("Aufruf: spike-s4 <ordner> [--out <ordner>] [--lang de] [--ocr-alt]\n".utf8))
    exit(2)
}

let fm = FileManager.default
let inURL = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath)
let outURL = URL(fileURLWithPath: outDir)
try fm.createDirectory(at: outURL, withIntermediateDirectories: true)

let files = (try fm.contentsOfDirectory(at: inURL, includingPropertiesForKeys: nil))
    .filter { DocumentImporter.supportedExtensions.contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }

var importer = DocumentImporter()
if legacyOCR { importer.useLegacyOCR() }
var summary = "Datei | Seiten | OCR-Seiten | Sprache | Überschriften | Absätze | Zeichen | Sekunden\n"
for file in files {
    let start = Date()
    var text = ""
    do {
        let r = try await importer.importDetailed(at: file, languageHint: lang)
        let heads = r.document.blocks.filter { if case .heading = $0 { return true } else { return false } }.count
        let paras = r.document.blocks.count - heads
        let chars = r.document.blocks.reduce(0) {
            switch $1 { case .heading(_, let t): return $0 + t.count; case .paragraph(let p): return $0 + p.count }
        }
        let secs = Date().timeIntervalSince(start)
        summary += "\(file.lastPathComponent) | \(r.pageCount) | \(r.ocrPages.map { String($0 + 1) }.joined(separator: ",")) | \(r.language ?? "?") | \(heads) | \(paras) | \(chars) | \(String(format: "%.1f", secs))\n"

        text += "# Datei: \(file.lastPathComponent)\n# Titel: \(r.document.title ?? "-")\n"
        if let rep = r.report {
            text += "# Sprache: \(rep.language ?? "?")  Fließtextgröße: \(String(format: "%.1f", rep.bodyFontSize)) pt\n"
            text += "# Entfernt: Kopf/Fuß \(rep.removedHeaderFooter) | Seitenzahlen \(rep.removedPageNumbers) | Fußnotenzeilen \(rep.removedFootnoteLines) | Bildunterschriften \(rep.removedCaptions.count) | Tabellenzeilen \(rep.removedTableLines)\n"
            text += "# Zweispaltige Seiten: \(rep.twoColumnPages.map { $0 + 1 })  Trennungen zusammengezogen: \(rep.hyphenJoined.count), beibehalten: \(rep.hyphenKept)\n"
        }
        text += "\n"
        for b in r.document.blocks {
            switch b {
            case .heading(let l, let t): text += "\(String(repeating: "#", count: l)) \(t)\n\n"
            case .paragraph(let p): text += "\(p)\n\n"
            }
        }
    } catch {
        text = "FEHLER: \(error)\n"
        summary += "\(file.lastPathComponent) | FEHLER: \(error)\n"
    }
    try text.write(to: outURL.appendingPathComponent(file.deletingPathExtension().lastPathComponent + ".txt"), atomically: true, encoding: .utf8)
}
try summary.write(to: outURL.appendingPathComponent("_Zusammenfassung.txt"), atomically: true, encoding: .utf8)
print(summary)
print("Ausgabe: \(outURL.path)")
