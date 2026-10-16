import Foundation
import Testing
@testable import TextPrep

@Suite struct ChunkPlannerTests {
    let planner = ChunkPlanner()

    private func sentences(_ n: Int) -> String {
        (1...n).map { "Dies ist der Satz Nummer \($0) in einem längeren Absatz, der gelesen wird." }.joined(separator: " ")
    }

    @Test func paragraphsPackIntoRangeAndEndOnBoundary() {
        let doc = TextDocument(blocks: [.paragraph(sentences(30)), .paragraph(sentences(12))])
        let chunks = planner.plan(document: doc, language: .de)
        let range = ChunkPlanner.lengthRange(for: .de)
        #expect(chunks.count > 2)
        for c in chunks { #expect(c.spokenText.count <= range.upperBound, "zu lang: \(c.spokenText.count)") }
        // Alle außer dem letzten je Absatz: mindestens die Untergrenze.
        let ends = chunks.filter { $0.kind == .paragraphEnd }
        #expect(ends.count == 2)
        for (i, c) in chunks.enumerated() where c.kind == .sentence {
            #expect(c.spokenText.count >= range.lowerBound, "Abschnitt \(i) zu kurz")
        }
        #expect(chunks.last?.kind == .paragraphEnd)
        #expect(chunks.map(\.index) == Array(chunks.indices))
    }

    @Test func chunkNeverMixesParagraphs() {
        let doc = TextDocument(blocks: [.paragraph("Kurz."), .paragraph("Auch kurz.")])
        let chunks = planner.plan(document: doc, language: .de)
        #expect(chunks.map(\.text) == ["Kurz.", "Auch kurz."])
        #expect(chunks.allSatisfy { $0.kind == .paragraphEnd })
    }

    @Test func headingsStartChapters() {
        let doc = TextDocument(blocks: [
            .paragraph("Vorwort."),
            .heading(level: 1, text: "Erstes Kapitel"),
            .paragraph("Text eins."),
            .heading(level: 2, text: "Zweites Kapitel"),
            .paragraph("Text zwei."),
        ])
        let chunks = planner.plan(document: doc, language: .de)
        #expect(chunks.map(\.kind) == [.paragraphEnd, .heading, .paragraphEnd, .heading, .paragraphEnd])
        #expect(chunks.map(\.chapter) == [0, 1, 1, 2, 2])
    }

    @Test func longSentenceSplitsAtCommasWithoutTearingNumbers() {
        // Ein einziger Satz von ~900 Zeichen mit Zahlen in der Nähe der Mitte.
        let filler = "wir kaufen viele verschiedene Dinge auf dem großen Markt und kommen danach wieder zurück nach Hause"
        let parts = [
            "Heute", filler, "dazu kostet das Brot 19,99 Euro", filler,
            "die Wurst 1.000,50 Euro", filler, "und der Käse 19.99 Euro", filler, "und zum Schluss gehen wir nach Hause",
        ]
        let sentence = parts.joined(separator: ", ") + "."
        #expect(sentence.count > 500)
        let chunks = planner.plan(document: .init(blocks: [.paragraph(sentence)]), language: .de)
        #expect(chunks.count >= 2)
        for c in chunks { #expect(c.text.count <= 500) }
        let joined = chunks.map(\.text).joined(separator: " ")
        for number in ["19,99", "1.000,50", "19.99"] {
            #expect(joined.contains(number))
            #expect(chunks.contains { $0.text.contains(number) })
        }
        // Kein Abschnitt darf mit „,“ nach einer Ziffer enden und der nächste mit einer Ziffer beginnen.
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            #expect(!(a.text.last?.isNumber == true && b.text.first?.isNumber == true))
        }
    }

    @Test func splitPointsSkipNumbers() {
        let chars = Array("a 19,99 b, c 1.000,50; d 14:30 e")
        let commaPoints = ChunkPlanner.splitPoints(in: chars, marks: [","])
        #expect(commaPoints.count == 1)   // nur „b,“
        #expect(chars[commaPoints[0] - 1] == ",")
        #expect(chars[commaPoints[0] - 2] == "b")
        let strong = ChunkPlanner.splitPoints(in: chars, marks: [";", ":"])
        #expect(strong.count == 1)        // „;“, aber nicht „14:30“
    }

    @Test func prefersSentenceBoundariesOverCommas() {
        // Zwei Sätze, jeder mit Kommas; zusammen zu lang. Schnitt muss am Punkt liegen.
        let s1 = String(repeating: "alpha beta gamma, ", count: 18) + "Ende eins."
        let s2 = "Delta " + String(repeating: "epsilon zeta, ", count: 18) + "Ende zwei."
        let chunks = planner.plan(document: .init(blocks: [.paragraph(s1 + " " + s2)]), language: .de)
        #expect(chunks.count == 2)
        #expect(chunks[0].text.hasSuffix("Ende eins."))
        #expect(chunks[1].text.hasSuffix("Ende zwei."))
    }

    @Test func spokenLengthIsMeasured() {
        // Zahlen werden länger, wenn sie ausgeschrieben sind; der Planer misst die gesprochene Form.
        let text = Array(repeating: "Es kostet 1.234.567,89 Euro heute", count: 20).joined(separator: ". ") + "."
        let chunks = TextPreparer.prepare(document: .init(blocks: [.paragraph(text)]), language: .de)
        for c in chunks { #expect(c.spokenText.count <= 500) }
        #expect(chunks.allSatisfy { !$0.spokenText.contains(where: { $0.isASCII && $0.isNumber }) })
    }

    @Test func cjkUsesShorterChunks() {
        let sentence = "今天的天气非常好,我们决定一起去公园里散步,然后在湖边吃一顿简单的午饭。"
        let text = String(repeating: sentence, count: 15)
        let chunks = planner.plan(document: .init(blocks: [.paragraph(text)]), language: .zh)
        let range = ChunkPlanner.lengthRange(for: .zh)
        #expect(range == 70...170)
        #expect(chunks.count > 2)
        for c in chunks.dropLast() {
            #expect(c.spokenText.count <= range.upperBound)
            #expect(c.spokenText.count >= range.lowerBound)
        }
        #expect(chunks.last!.spokenText.count <= range.upperBound)
    }

    @Test func cjkLongSentenceWithoutPunctuationIsCutAnyway() {
        let text = String(repeating: "天气很好", count: 100) + "。"
        let chunks = planner.plan(document: .init(blocks: [.paragraph(text)]), language: .zh)
        #expect(chunks.count >= 3)
        for c in chunks { #expect(c.text.count <= 170) }
        #expect(chunks.map(\.text).joined() == text)
    }

    @Test func preparerFillsSpokenText() {
        let doc = TextDocument(blocks: [.heading(level: 1, text: "Kapitel 1"), .paragraph("Am 3.5.2024 zahlte er 12,50 €.")])
        let chunks = TextPreparer.prepare(document: doc, language: .de)
        #expect(chunks[0].text == "Kapitel 1")
        #expect(chunks[0].spokenText == "Kapitel eins")
        #expect(chunks[1].text == "Am 3.5.2024 zahlte er 12,50 €.")
        #expect(chunks[1].spokenText == "Am dritten Mai zweitausendvierundzwanzig zahlte er zwölf Euro fünfzig.")
    }

    @Test func chunksAreCodable() throws {
        let chunks = TextPreparer.prepare(document: .init(blocks: [.paragraph("Hallo Welt.")]), language: .de)
        let data = try JSONEncoder().encode(chunks)
        #expect(try JSONDecoder().decode([Chunk].self, from: data) == chunks)
        let doc = TextDocument(title: "T", blocks: [.heading(level: 2, text: "H"), .paragraph("P")])
        #expect(try JSONDecoder().decode(TextDocument.self, from: JSONEncoder().encode(doc)) == doc)
    }

    @Test func emptyAndWhitespaceBlocksAreSkipped() {
        let doc = TextDocument(blocks: [.paragraph("  \n "), .heading(level: 1, text: " "), .paragraph("Text.")])
        #expect(planner.plan(document: doc, language: .de).count == 1)
    }
}
