// Prüft die Oma-Regeln aus PLAN.md §3 gegen die zentralen Stilkonstanten, die
// Farbpaare (hell und dunkel), die Übersetzungen und die mitgelieferten Daten.
import AppKit
import Foundation
import TextPrep
import XCTest

@testable import Vorleser

final class OmaRulesTests: XCTestCase {
    /// Wurzel des Repos, abgeleitet aus dem Pfad dieser Datei.
    private var repo: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    // MARK: Größen

    func testFontSizesFollowRules() {
        XCTAssertGreaterThanOrEqual(OmaStyle.minTextSize, 20)
        XCTAssertGreaterThanOrEqual(OmaStyle.bodySize, 20)
        XCTAssertGreaterThanOrEqual(OmaStyle.buttonTextSize, 20)
        XCTAssertGreaterThanOrEqual(OmaStyle.minHeadingSize, 30)
        XCTAssertGreaterThanOrEqual(OmaStyle.headingSize, 30)
        XCTAssertGreaterThanOrEqual(OmaStyle.titleSize, OmaStyle.headingSize)
    }

    func testButtonsAreAtLeast60High() {
        XCTAssertGreaterThanOrEqual(OmaStyle.minButtonHeight, 60)
        XCTAssertGreaterThanOrEqual(OmaStyle.buttonHeight, 60)
    }

    // MARK: Kontrast

    func testTextContrastAtLeast7To1() {
        for (name, scheme) in [("hell", OmaPalette.light), ("dunkel", OmaPalette.dark)] {
            for (pair, fg, bg) in OmaPalette.textPairs(scheme) {
                XCTAssertGreaterThanOrEqual(
                    fg.contrast(with: bg), OmaStyle.minContrast, "\(pair) (\(name))")
            }
        }
    }

    func testNonTextContrastAtLeast3To1() {
        for (name, scheme) in [("hell", OmaPalette.light), ("dunkel", OmaPalette.dark)] {
            for (pair, fg, bg) in OmaPalette.nonTextPairs(scheme) {
                XCTAssertGreaterThanOrEqual(
                    fg.contrast(with: bg), OmaStyle.minNonTextContrast, "\(pair) (\(name))")
            }
        }
    }

    func testContrastFormulaKnownValues() {
        XCTAssertEqual(RGB(0x000000).contrast(with: RGB(0xFFFFFF)), 21, accuracy: 0.01)
    }

    // MARK: Übersetzungen

    private func catalog() throws -> [String: Any] {
        let data = try Data(contentsOf: repo.appending(path: "App/Localizable.xcstrings"))
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return try XCTUnwrap(json?["strings"] as? [String: Any])
    }

    /// Text einer Übersetzung; bei Plural-Varianten alle Formen.
    private func values(_ entry: [String: Any], _ lang: String) -> [String] {
        guard let loc = (entry["localizations"] as? [String: Any])?[lang] as? [String: Any] else { return [] }
        if let u = (loc["stringUnit"] as? [String: Any])?["value"] as? String { return [u] }
        if let plural = (loc["variations"] as? [String: Any])?["plural"] as? [String: Any] {
            return plural.values.compactMap { ($0 as? [String: Any])?["stringUnit"] as? [String: Any] }
                .compactMap { $0["value"] as? String }
        }
        return []
    }

    func testEveryKeyHasGermanAndPortuguese() throws {
        let strings = try catalog()
        XCTAssertGreaterThan(strings.count, 50)
        for (key, raw) in strings {
            let entry = try XCTUnwrap(raw as? [String: Any])
            for lang in ["de", "pt-PT"] {
                let v = values(entry, lang)
                XCTAssertFalse(v.isEmpty, "\(key) fehlt auf \(lang)")
                XCTAssertTrue(v.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "\(key) leer auf \(lang)")
            }
            // Gleiche Platzhalter in beiden Sprachen
            func placeholders(_ s: [String]) -> [String] {
                s.flatMap { $0.matches(of: /%(?:lld|@|d)|%%/).map { String($0.output) } }.sorted()
            }
            let de = placeholders(values(entry, "de")).filter { $0 != "%%" }
            let pt = placeholders(values(entry, "pt-PT")).filter { $0 != "%%" }
            XCTAssertEqual(Set(de), Set(pt), "Platzhalter von \(key) unterscheiden sich")
        }
    }

    func testNoTechnicalTermsInGermanUI() throws {
        let banned = ["TTS", "Modell", "Klonen", "MP3", "Bitrate", "KI-Stimme"]
        for (key, raw) in try catalog() {
            let entry = try XCTUnwrap(raw as? [String: Any])
            for text in values(entry, "de") + values(entry, "pt-PT") {
                for word in banned {
                    XCTAssertFalse(text.contains(word), "Fachwort „\(word)“ in \(key)")
                }
            }
        }
    }

    /// Alle im Code fest geschriebenen Schlüssel (`"a.b"`) müssen im Katalog stehen.
    func testKeysUsedInCodeExist() throws {
        let strings = try catalog()
        let dir = repo.appending(path: "App")
        let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty)
        let pattern = /"((?:[a-z]+)(?:\.[a-zA-Z]+)+)"/
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for m in text.matches(of: pattern) {
                let key = String(m.output.1)
                // Dateinamen und Bundle-IDs sind keine Schlüssel.
                if key.hasPrefix("de.vorleser") { continue }
                // SF-Symbole sehen genauso aus wie Schlüssel.
                if NSImage(systemSymbolName: key, accessibilityDescription: nil) != nil { continue }
                XCTAssertNotNil(strings[key], "Schlüssel \(key) in \(file.lastPathComponent) fehlt im Katalog")
            }
        }
        // Dynamisch gebaute Schlüssel
        for tempo in Tempo.allCases { XCTAssertNotNil(strings[tempo.titleKey], tempo.titleKey) }
        for lang in Language.allCases { XCTAssertNotNil(strings[lang.nameKey], lang.nameKey) }
    }

    // MARK: Mitgelieferte Daten

    func testReadAloudTextsExistForAllLanguages() throws {
        for lang in Language.allCases {
            let url = repo.appending(path: "Resources/ReadAloud/\(lang.rawValue).txt")
            let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertFalse(text.isEmpty, "\(lang)")
            if lang.isCJK {
                XCTAssertTrue((40...90).contains(text.count), "\(lang): \(text.count) Zeichen")
            } else {
                let words = text.split(whereSeparator: \.isWhitespace).count
                XCTAssertTrue((20...40).contains(words), "\(lang): \(words) Wörter")
            }
        }
    }

    // MARK: Modell

    func testTitleFromText() {
        XCTAssertEqual(AppModel.title(fromText: "Liebe Frau Meier, vielen Dank für Ihren Brief."), "Liebe Frau Meier, vielen Dank für")
        XCTAssertFalse(AppModel.title(fromText: "   ").isEmpty)
    }

    func testClockFormat() {
        XCTAssertEqual(Fmt.clock(125), "2:05")
        XCTAssertEqual(Fmt.remainingMinutes(61), 2)
    }
}
