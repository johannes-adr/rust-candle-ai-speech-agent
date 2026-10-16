import Foundation
import Testing
@testable import TextPrep

/// Golden-Files: Eingabe → erwartete Aussprache, je Sprache in `Golden/<sprache>.json`.
struct GoldenCase: Decodable, Sendable, CustomTestStringConvertible {
    let `in`: String
    let out: String
    var testDescription: String { `in` }
}

func loadGolden(_ language: Language) throws -> [GoldenCase] {
    let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")
    let data = try Data(contentsOf: dir.appendingPathComponent("\(language.rawValue).json"))
    return try JSONDecoder().decode([GoldenCase].self, from: data)
}

@Test("Golden-File je Sprache", arguments: Language.allCases)
func golden(language: Language) throws {
    let cases = try loadGolden(language)
    #expect(!cases.isEmpty)
    let normalizer = Normalizers.make(for: language)
    for c in cases {
        #expect(normalizer.normalize(c.in) == c.out, "Eingabe: \(c.in)")
    }
}

@Test func goldenDeAndPtAreExtensive() throws {
    #expect(try loadGolden(.de).count >= 15)
    #expect(try loadGolden(.pt).count >= 15)
}

@Test func brazilianVariantChangesWords() {
    let br = Normalizers.make(for: .pt, options: .init(portugueseVariant: .brazil))
    #expect(br.normalize("16 km") == "dezesseis quilômetros")
    #expect(br.normalize("0,50 R$") == "cinquenta centavos")
    let pt = Normalizers.make(for: .pt)
    #expect(pt.normalize("16 km") == "dezasseis quilómetros")
}

@Test func normalizedTextHasNoDigitsLeft() {
    for language in Language.allCases {
        let n = Normalizers.make(for: language)
        let out = n.normalize("Es gibt 12 Dinge, 3,5 Teile und 1.000 Stück im Jahr 2024.")
        #expect(!out.contains(where: { $0.isASCII && $0.isNumber }), "\(language): \(out)")
    }
}
