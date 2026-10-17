import Testing
@testable import TextPrep

@Suite struct SentenceSplitterTests {
    let splitter = SentenceSplitter()

    @Test func germanAbbreviationsDoNotSplit() {
        let s = splitter.split("Das ist z. B. ein Beispiel. Dr. Müller kam am 3. Mai an. Dann ging er.", language: .de)
        #expect(!s.contains("Das ist z. B."))
        #expect(!s.contains("Dr."))
        #expect(s.last == "Dann ging er.")
        #expect(s.contains { $0.contains("am 3. Mai an.") })
    }

    @Test func portugueseAbbreviationsDoNotSplit() {
        let s = splitter.split("O Sr. Silva chegou, p. ex. ontem. Ele foi embora. Depois voltou.", language: .pt)
        #expect(s == ["O Sr. Silva chegou, p. ex. ontem.", "Ele foi embora.", "Depois voltou."])
    }

    @Test func terminalAbbreviationSplitsBeforeCapital() {
        let s = splitter.split("Er kaufte Äpfel, Birnen usw. Dann ging er heim.", language: .de)
        #expect(s.count == 2)
    }

    @Test func decimalNumbersDoNotSplit() {
        let s = splitter.split("Es kostet 19.99 Euro. Das ist günstig.", language: .de)
        #expect(s == ["Es kostet 19.99 Euro.", "Das ist günstig."])
    }

    @Test func cjkSplitsAtFullStops() {
        #expect(splitter.split("今天天气很好。我们去公园吧!你觉得呢?", language: .zh).count == 3)
        #expect(splitter.split("今日は晴れです。公園に行きましょう。", language: .ja).count == 2)
        #expect(splitter.split("오늘은 날씨가 좋습니다. 공원에 갑시다.", language: .ko).count == 2)
    }

    @Test func englishAbbreviations() {
        let s = splitter.split("Dr. Smith arrived, e.g. yesterday. He left.", language: .en)
        #expect(s.count == 2)
    }
}
