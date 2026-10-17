import Foundation

/// Portugiesische Variante. Die Entscheidung PT vs. BR ist offen; Standard ist Portugal.
public enum PortugueseVariant: String, Sendable, Codable, CaseIterable {
    case portugal
    case brazil
}

public struct NormalizerOptions: Sendable, Equatable {
    public var portugueseVariant: PortugueseVariant
    public init(portugueseVariant: PortugueseVariant = .portugal) {
        self.portugueseVariant = portugueseVariant
    }
}

struct UnitDef {
    let symbol: String
    let singular: String
    let plural: String
    var feminine = false
}

struct CurrencyDef {
    let singular: String
    let plural: String
    let cent: String
    let cents: String
}

struct UrlWords {
    let dot, slash, at, dash, underscore: String
}

/// Sprachdaten für den regelbasierten Normalizer.
struct Lexicon {
    var language: Language
    var localeID: String
    /// Tausendertrenner als Zeichen, `nil` wenn es keinen Punkt/Komma gibt (fr, ru).
    var groupChar: Character?
    var decimalWord: String
    var minusWord: String
    var percent: String
    var percentIsPrefix = false
    var plusWord: String
    var urlWords: UrlWords
    /// Nur de und pt (ausgebaut).
    var months: [String] = []
    var units: [UnitDef] = []
    /// Schlüssel: kleingeschriebenes Symbol bzw. Name.
    var currencies: [String: CurrencyDef] = [:]
    var rich: Bool { !months.isEmpty }

    static func make(for language: Language, options: NormalizerOptions) -> Lexicon {
        switch language {
        case .de: return german
        case .pt: return portuguese(options.portugueseVariant)
        case .en:
            return base(.en, "en_US", ",", "point", "minus", "percent", "plus", .init(dot: "dot", slash: "slash", at: "at", dash: "dash", underscore: "underscore"))
        case .es:
            return base(.es, "es_ES", ".", "coma", "menos", "por ciento", "más", .init(dot: "punto", slash: "barra", at: "arroba", dash: "guion", underscore: "guion bajo"))
        case .fr:
            return base(.fr, "fr_FR", nil, "virgule", "moins", "pour cent", "plus", .init(dot: "point", slash: "barre", at: "arobase", dash: "tiret", underscore: "tiret bas"))
        case .it:
            return base(.it, "it_IT", ".", "virgola", "meno", "per cento", "più", .init(dot: "punto", slash: "barra", at: "chiocciola", dash: "trattino", underscore: "trattino basso"))
        case .ru:
            return base(.ru, "ru_RU", nil, "запятая", "минус", "процентов", "плюс", .init(dot: "точка", slash: "слеш", at: "собака", dash: "дефис", underscore: "подчёркивание"))
        case .zh:
            var l = base(.zh, "zh_CN", ",", "点", "负", "百分之", "加", .init(dot: "点", slash: "斜杠", at: "艾特", dash: "横线", underscore: "下划线"))
            l.percentIsPrefix = true
            return l
        case .ja:
            return base(.ja, "ja_JP", ",", "点", "マイナス", "パーセント", "プラス", .init(dot: "ドット", slash: "スラッシュ", at: "アットマーク", dash: "ハイフン", underscore: "アンダースコア"))
        case .ko:
            return base(.ko, "ko_KR", ",", "점", "마이너스", "퍼센트", "플러스", .init(dot: "점", slash: "슬래시", at: "골뱅이", dash: "하이픈", underscore: "밑줄"))
        }
    }

    private static func base(
        _ l: Language, _ id: String, _ group: Character?, _ dec: String, _ minus: String,
        _ percent: String, _ plus: String, _ url: UrlWords
    ) -> Lexicon {
        Lexicon(language: l, localeID: id, groupChar: group, decimalWord: dec, minusWord: minus,
                percent: percent, plusWord: plus, urlWords: url)
    }

    // MARK: Deutsch

    static let german: Lexicon = {
        var l = base(.de, "de_DE", ".", "Komma", "minus", "Prozent", "plus",
                     .init(dot: "Punkt", slash: "Schrägstrich", at: "ät", dash: "Bindestrich", underscore: "Unterstrich"))
        l.months = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August",
                    "September", "Oktober", "November", "Dezember"]
        l.units = [
            .init(symbol: "km/h", singular: "Kilometer pro Stunde", plural: "Kilometer pro Stunde"),
            .init(symbol: "km²", singular: "Quadratkilometer", plural: "Quadratkilometer"),
            .init(symbol: "m²", singular: "Quadratmeter", plural: "Quadratmeter"),
            .init(symbol: "m³", singular: "Kubikmeter", plural: "Kubikmeter"),
            .init(symbol: "°C", singular: "Grad Celsius", plural: "Grad Celsius"),
            .init(symbol: "°F", singular: "Grad Fahrenheit", plural: "Grad Fahrenheit"),
            .init(symbol: "‰", singular: "Promille", plural: "Promille"),
            .init(symbol: "km", singular: "Kilometer", plural: "Kilometer"),
            .init(symbol: "cm", singular: "Zentimeter", plural: "Zentimeter"),
            .init(symbol: "mm", singular: "Millimeter", plural: "Millimeter"),
            .init(symbol: "kg", singular: "Kilogramm", plural: "Kilogramm"),
            .init(symbol: "mg", singular: "Milligramm", plural: "Milligramm"),
            .init(symbol: "ml", singular: "Milliliter", plural: "Milliliter"),
            .init(symbol: "kWh", singular: "Kilowattstunde", plural: "Kilowattstunden", feminine: true),
            .init(symbol: "kW", singular: "Kilowatt", plural: "Kilowatt"),
            .init(symbol: "GB", singular: "Gigabyte", plural: "Gigabyte"),
            .init(symbol: "MB", singular: "Megabyte", plural: "Megabyte"),
            .init(symbol: "min", singular: "Minute", plural: "Minuten", feminine: true),
            .init(symbol: "h", singular: "Stunde", plural: "Stunden", feminine: true),
            .init(symbol: "m", singular: "Meter", plural: "Meter"),
            .init(symbol: "g", singular: "Gramm", plural: "Gramm"),
            .init(symbol: "l", singular: "Liter", plural: "Liter"),
            .init(symbol: "°", singular: "Grad", plural: "Grad"),
        ]
        let euro = CurrencyDef(singular: "Euro", plural: "Euro", cent: "Cent", cents: "Cent")
        let dollar = CurrencyDef(singular: "Dollar", plural: "Dollar", cent: "Cent", cents: "Cent")
        l.currencies = [
            "€": euro, "eur": euro, "euro": euro, "euros": euro,
            "$": dollar, "usd": dollar, "dollar": dollar, "dollars": dollar,
            "£": .init(singular: "Pfund", plural: "Pfund", cent: "Penny", cents: "Pence"),
            "gbp": .init(singular: "Pfund", plural: "Pfund", cent: "Penny", cents: "Pence"),
            "chf": .init(singular: "Franken", plural: "Franken", cent: "Rappen", cents: "Rappen"),
        ]
        return l
    }()

    // MARK: Portugiesisch

    static func portuguese(_ variant: PortugueseVariant) -> Lexicon {
        let br = variant == .brazil
        var l = base(.pt, br ? "pt_BR" : "pt_PT", ".", "vírgula", "menos", "por cento", "mais",
                     .init(dot: "ponto", slash: "barra", at: "arroba", dash: "hífen", underscore: "sublinhado"))
        l.months = ["janeiro", "fevereiro", "março", "abril", "maio", "junho", "julho", "agosto",
                    "setembro", "outubro", "novembro", "dezembro"]
        let q = br ? "quilômetro" : "quilómetro"
        let cent = br ? "centavo" : "cêntimo"
        l.units = [
            .init(symbol: "km/h", singular: "\(q) por hora", plural: "\(q)s por hora"),
            .init(symbol: "km²", singular: "\(q) quadrado", plural: "\(q)s quadrados"),
            .init(symbol: "m²", singular: "metro quadrado", plural: "metros quadrados"),
            .init(symbol: "m³", singular: "metro cúbico", plural: "metros cúbicos"),
            .init(symbol: "°C", singular: "grau Celsius", plural: "graus Celsius"),
            .init(symbol: "°F", singular: "grau Fahrenheit", plural: "graus Fahrenheit"),
            .init(symbol: "‰", singular: "por mil", plural: "por mil"),
            .init(symbol: "km", singular: q, plural: q + "s"),
            .init(symbol: "cm", singular: "centímetro", plural: "centímetros"),
            .init(symbol: "mm", singular: "milímetro", plural: "milímetros"),
            .init(symbol: "kg", singular: "quilograma", plural: "quilogramas"),
            .init(symbol: "mg", singular: "miligrama", plural: "miligramas"),
            .init(symbol: "ml", singular: "mililitro", plural: "mililitros"),
            .init(symbol: "kWh", singular: "quilowatt-hora", plural: "quilowatts-hora"),
            .init(symbol: "kW", singular: "quilowatt", plural: "quilowatts"),
            .init(symbol: "GB", singular: "gigabyte", plural: "gigabytes"),
            .init(symbol: "MB", singular: "megabyte", plural: "megabytes"),
            .init(symbol: "min", singular: "minuto", plural: "minutos"),
            .init(symbol: "h", singular: "hora", plural: "horas", feminine: true),
            .init(symbol: "m", singular: "metro", plural: "metros"),
            .init(symbol: "g", singular: "grama", plural: "gramas"),
            .init(symbol: "l", singular: "litro", plural: "litros"),
            .init(symbol: "°", singular: "grau", plural: "graus"),
        ]
        let euro = CurrencyDef(singular: "euro", plural: "euros", cent: cent, cents: cent + "s")
        let dollar = CurrencyDef(singular: "dólar", plural: "dólares", cent: cent, cents: cent + "s")
        let real = CurrencyDef(singular: "real", plural: "reais", cent: "centavo", cents: "centavos")
        let pound = CurrencyDef(singular: "libra", plural: "libras", cent: "péni", cents: "pences")
        l.currencies = [
            "€": euro, "eur": euro, "euro": euro, "euros": euro,
            "$": dollar, "usd": dollar, "dólar": dollar, "dólares": dollar,
            "r$": real,
            "£": pound, "gbp": pound,
        ]
        return l
    }
}
