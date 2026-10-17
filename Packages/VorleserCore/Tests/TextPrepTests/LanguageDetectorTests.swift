import Testing
@testable import TextPrep

@Suite struct LanguageDetectorTests {
    let detector = LanguageDetector()

    @Test(arguments: [
        ("Das ist ein deutscher Satz über Katzen und Hunde, die im Garten spielen.", Language.de),
        ("Isto é uma frase em português sobre gatos que brincam no jardim.", .pt),
        ("This is an English sentence about cats playing in the garden.", .en),
        ("Esta es una frase en español sobre gatos que juegan en el jardín.", .es),
        ("Ceci est une phrase en français sur des chats qui jouent dans le jardin.", .fr),
        ("Questa è una frase in italiano sui gatti che giocano in giardino.", .it),
        ("Это предложение на русском языке о кошках, которые играют в саду.", .ru),
        ("今天天气很好,我们一起去公园里散步吧。", .zh),
        ("今日はとても天気がいいので、公園に散歩に行きましょう。", .ja),
        ("오늘은 날씨가 아주 좋아서 공원에 산책하러 갑니다.", .ko),
    ])
    func detectsAllTenLanguages(text: String, expected: Language) throws {
        let d = try #require(detector.detect(text))
        #expect(d.language == expected)
        #expect(!d.isUncertain)
    }

    @Test func shortAmbiguousTextIsUncertain() throws {
        let d = try #require(detector.detect("ok"))
        #expect(d.isUncertain)
    }

    @Test func nothingToDetect() {
        #expect(detector.detect("") == nil)
        #expect(detector.detect("123 456") == nil)
    }

    @Test func onlyConstrainedLanguagesAreReported() throws {
        let d = try #require(detector.detect("Dit is een Nederlandse zin over katten in de tuin."))
        #expect(Language.allCases.contains(d.language))
        #expect(d.candidates.keys.allSatisfy { Language.allCases.contains($0) })
    }
}
