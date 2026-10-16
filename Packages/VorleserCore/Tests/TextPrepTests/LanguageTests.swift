import Testing
@testable import TextPrep

@Test func allTenLanguages() {
    #expect(Language.allCases.count == 10)
    #expect(Language.ja.isCJK)
    #expect(!Language.de.isCJK)
}
