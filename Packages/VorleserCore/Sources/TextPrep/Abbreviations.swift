import Foundation

/// Eine Abkürzung mit ihrer gesprochenen Form.
struct Abbreviation: Sendable {
    /// Schreibweise mit Leerzeichen zwischen den Teilen, z. B. „z. B.“.
    /// Beim Suchen sind Leerzeichen zwischen den Teilen optional („z.B.“).
    let written: String
    let spoken: String
    /// Kann einen Satz beenden („usw.“, „etc.“): trennt, wenn ein Großbuchstabe folgt.
    var mayEndSentence = false
}

/// Abkürzungslisten je Sprache. Dient dem SentenceSplitter (nicht trennen)
/// und den Normalizern (ausschreiben).
enum Abbreviations {
    static func list(for language: Language) -> [Abbreviation] {
        let items = table[language] ?? []
        // Längste zuerst, damit „und so weiter“-Varianten vor ihren Teilen greifen.
        return items.sorted { $0.written.count > $1.written.count }
    }

    /// Regulärer Ausdruck für eine Abkürzung (Leerzeichen optional, Punkte maskiert).
    static func pattern(for abbreviation: Abbreviation) -> String {
        abbreviation.written
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s*"#)
    }

    private static let table: [Language: [Abbreviation]] = [
        .de: [
            .init(written: "z. B.", spoken: "zum Beispiel"),
            .init(written: "d. h.", spoken: "das heißt"),
            .init(written: "u. a.", spoken: "unter anderem"),
            .init(written: "z. T.", spoken: "zum Teil"),
            .init(written: "o. ä.", spoken: "oder ähnliches"),
            .init(written: "u. v. m.", spoken: "und vieles mehr"),
            .init(written: "usw.", spoken: "und so weiter", mayEndSentence: true),
            .init(written: "etc.", spoken: "et cetera", mayEndSentence: true),
            .init(written: "bzw.", spoken: "beziehungsweise"),
            .init(written: "ca.", spoken: "circa"),
            .init(written: "Dr.", spoken: "Doktor"),
            .init(written: "Prof.", spoken: "Professor"),
            .init(written: "Nr.", spoken: "Nummer"),
            .init(written: "vgl.", spoken: "vergleiche"),
            .init(written: "evtl.", spoken: "eventuell"),
            .init(written: "ggf.", spoken: "gegebenenfalls"),
            .init(written: "bzgl.", spoken: "bezüglich"),
            .init(written: "inkl.", spoken: "inklusive"),
            .init(written: "Hr.", spoken: "Herr"),
            .init(written: "Str.", spoken: "Straße"),
            .init(written: "Mio.", spoken: "Millionen"),
            .init(written: "Mrd.", spoken: "Milliarden"),
            .init(written: "sog.", spoken: "sogenannte"),
            .init(written: "Abb.", spoken: "Abbildung"),
            .init(written: "Kap.", spoken: "Kapitel"),
        ],
        .pt: [
            .init(written: "p. ex.", spoken: "por exemplo"),
            .init(written: "i. e.", spoken: "isto é"),
            .init(written: "a. C.", spoken: "antes de Cristo"),
            .init(written: "d. C.", spoken: "depois de Cristo"),
            .init(written: "etc.", spoken: "etcétera", mayEndSentence: true),
            .init(written: "Dr.", spoken: "Doutor"),
            .init(written: "Dra.", spoken: "Doutora"),
            .init(written: "Sr.", spoken: "Senhor"),
            .init(written: "Sra.", spoken: "Senhora"),
            .init(written: "Prof.", spoken: "Professor"),
            .init(written: "Profa.", spoken: "Professora"),
            .init(written: "Eng.", spoken: "Engenheiro"),
            .init(written: "n.º", spoken: "número"),
            .init(written: "nº", spoken: "número"),
            .init(written: "pág.", spoken: "página"),
            .init(written: "págs.", spoken: "páginas"),
            .init(written: "Av.", spoken: "Avenida"),
            .init(written: "cf.", spoken: "confira"),
            .init(written: "aprox.", spoken: "aproximadamente"),
            .init(written: "tel.", spoken: "telefone"),
            .init(written: "Lda.", spoken: "Limitada"),
        ],
        .en: [
            .init(written: "e. g.", spoken: "for example"),
            .init(written: "i. e.", spoken: "that is"),
            .init(written: "etc.", spoken: "et cetera", mayEndSentence: true),
            .init(written: "Dr.", spoken: "Doctor"),
            .init(written: "Mr.", spoken: "Mister"),
            .init(written: "Mrs.", spoken: "Missus"),
            .init(written: "Ms.", spoken: "Miss"),
            .init(written: "Prof.", spoken: "Professor"),
            .init(written: "vs.", spoken: "versus"),
            .init(written: "approx.", spoken: "approximately"),
            .init(written: "Fig.", spoken: "Figure"),
        ],
        .es: [
            .init(written: "p. ej.", spoken: "por ejemplo"),
            .init(written: "EE. UU.", spoken: "Estados Unidos"),
            .init(written: "etc.", spoken: "etcétera", mayEndSentence: true),
            .init(written: "Sr.", spoken: "señor"),
            .init(written: "Sra.", spoken: "señora"),
            .init(written: "Dr.", spoken: "doctor"),
            .init(written: "Dra.", spoken: "doctora"),
            .init(written: "Ud.", spoken: "usted"),
            .init(written: "aprox.", spoken: "aproximadamente"),
            .init(written: "pág.", spoken: "página"),
        ],
        .fr: [
            .init(written: "p. ex.", spoken: "par exemple"),
            .init(written: "c.-à-d.", spoken: "c'est-à-dire"),
            .init(written: "etc.", spoken: "et cetera", mayEndSentence: true),
            .init(written: "Mme", spoken: "madame"),
            .init(written: "Mlle", spoken: "mademoiselle"),
            .init(written: "Dr", spoken: "docteur"),
            .init(written: "M.", spoken: "monsieur"),
            .init(written: "env.", spoken: "environ"),
            .init(written: "n°", spoken: "numéro"),
        ],
        .it: [
            .init(written: "ecc.", spoken: "eccetera", mayEndSentence: true),
            .init(written: "ad es.", spoken: "ad esempio"),
            .init(written: "Sig.ra", spoken: "signora"),
            .init(written: "Sig.", spoken: "signor"),
            .init(written: "Dott.ssa", spoken: "dottoressa"),
            .init(written: "Dott.", spoken: "dottor"),
            .init(written: "Prof.", spoken: "professor"),
            .init(written: "pag.", spoken: "pagina"),
        ],
        .ru: [
            .init(written: "и т. д.", spoken: "и так далее", mayEndSentence: true),
            .init(written: "и т. п.", spoken: "и тому подобное", mayEndSentence: true),
            .init(written: "т. е.", spoken: "то есть"),
            .init(written: "т. д.", spoken: "так далее", mayEndSentence: true),
            .init(written: "напр.", spoken: "например"),
            .init(written: "см.", spoken: "смотри"),
            .init(written: "руб.", spoken: "рублей"),
            .init(written: "тыс.", spoken: "тысяч"),
            .init(written: "млн", spoken: "миллионов"),
            .init(written: "млрд", spoken: "миллиардов"),
        ],
        .zh: [],
        .ja: [],
        .ko: [],
    ]
}
