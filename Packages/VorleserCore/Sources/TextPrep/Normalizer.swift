import Foundation

/// Macht aus Schreibweise eine Aussprache: Zahlen, Daten, Geld, Abkürzungen
/// werden ausgeschrieben. Der Text danach enthält keine Ziffern mehr.
public protocol Normalizer: Sendable {
    var language: Language { get }
    func normalize(_ text: String) -> String
}

public enum Normalizers {
    /// Liefert den Normalizer der Sprache. Alle zehn Sprachen können Zahlen,
    /// Prozent und Abkürzungen; Deutsch und Portugiesisch zusätzlich Datum,
    /// Uhrzeit, Geld, Jahreszahlen, Ordnungszahlen, Einheiten, Telefon, URLs.
    public static func make(for language: Language, options: NormalizerOptions = .init()) -> any Normalizer {
        RuleNormalizer(language: language, options: options)
    }
}

/// Regelbasierter Normalizer, gesteuert von einem `Lexicon` je Sprache.
final class RuleNormalizer: Normalizer, @unchecked Sendable {
    let language: Language
    private let lex: Lexicon
    private let formatter: NumberFormatter
    private let lock = NSLock()

    /// Zahl in drei Schreibweisen: „1 000“ (fr), „1.000“/„1,000“, einfach/Dezimal.
    private let num: String
    private static let before = #"(?<!\d[.,])(?<![\p{N}])"#

    init(language: Language, options: NormalizerOptions) {
        self.language = language
        self.lex = Lexicon.make(for: language, options: options)
        let f = NumberFormatter()
        f.numberStyle = .spellOut
        f.locale = Locale(identifier: lex.localeID)
        self.formatter = f
        let space = lex.groupChar == nil ? #"[\u00A0\u202F ]"# : #"[\u00A0\u202F]"#
        self.num = #"(?:\d{1,3}(?:"# + space + #"\d{3})+(?:[.,]\d+)?|\d{1,3}(?:[.,]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)"#
    }

    // MARK: Einstieg

    func normalize(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\u{00AD}", with: "")
        if lex.rich {
            s = urlsAndEmails(s)
        }
        s = abbreviations(s)
        if lex.rich {
            s = dates(s)
            s = times(s)
            s = money(s)
            s = phones(s)
            s = units(s)
            s = ordinals(s)
        }
        s = percent(s)
        s = numbers(s)
        return s.replacingMatches(of: #"\s+"#) { _ in " " }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Zahlen als Wörter

    /// Ganze Zahl ausgeschrieben, Weicheinfügungen entfernt.
    func cardinal(_ n: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        let raw = formatter.string(from: NSNumber(value: n)) ?? String(n)
        return raw.replacingOccurrences(of: "\u{00AD}", with: "")
    }

    /// Deutsch „eins“ → „ein“ vor einem Hauptwort.
    func attributive(_ n: Int) -> String {
        let c = cardinal(n)
        if language == .de, c.hasSuffix("eins") { return String(c.dropLast()) }
        return c
    }

    /// Portugiesisch weiblich: „um“ → „uma“, „dois“ → „duas“ (letztes Wort).
    func feminine(_ n: Int) -> String {
        let c = cardinal(n)
        guard language == .pt else {
            return language == .de && c.hasSuffix("eins") ? String(c.dropLast()) + "e" : c
        }
        var words = c.split(separator: " ").map(String.init)
        if let last = words.last {
            if last == "um" { words[words.count - 1] = "uma" }
            else if last == "dois" { words[words.count - 1] = "duas" }
        }
        return words.joined(separator: " ")
    }

    private var sep: String { language.isCJK ? "" : " " }

    /// Trennt „1.000,50“ je nach Locale in Ganzzahl und Nachkomma.
    /// Gleichmäßig für „1.000“ (de = tausend) und „19,99“ / „19.99“ (Dezimal).
    func parse(_ token: String) -> (int: String, frac: String?) {
        let t = token.filter { $0 != "\u{00A0}" && $0 != "\u{202F}" && $0 != " " }
        let dots = t.filter { $0 == "." }.count
        let commas = t.filter { $0 == "," }.count
        func strip(_ c: Character) -> String { t.filter { $0 != c }.description }
        if dots > 0 && commas > 0 {
            let lastIsDot = (t.lastIndex(of: ".")!) > (t.lastIndex(of: ",")!)
            let dec: Character = lastIsDot ? "." : ","
            let grp: Character = lastIsDot ? "," : "."
            let cleaned = t.filter { $0 != grp }
            let parts = cleaned.split(separator: dec, omittingEmptySubsequences: false)
            return (String(parts[0]), parts.count > 1 ? String(parts[1]) : nil)
        }
        if dots + commas == 0 { return (t, nil) }
        let c: Character = dots > 0 ? "." : ","
        let count = dots + commas
        if count > 1 { return (strip(c), nil) }
        let parts = t.split(separator: c, omittingEmptySubsequences: false)
        let head = String(parts[0]), tail = String(parts[1])
        if lex.groupChar == c, tail.count == 3, head.count <= 3, !head.hasPrefix("0") {
            return (head + tail, nil)
        }
        return (head, tail)
    }

    private func integerWords(_ digits: String, attributive att: Bool = false, feminine fem: Bool = false) -> String {
        let leadingZero = digits.count > 1 && digits.hasPrefix("0")
        guard digits.count <= 15, !leadingZero, let n = Int(digits) else {
            return digits.compactMap { $0.wholeNumberValue }.map { cardinal($0) }.joined(separator: sep)
        }
        if fem { return feminine(n) }
        return att ? attributive(n) : cardinal(n)
    }

    /// Zahl samt Nachkommastellen („neunzehn Komma neun neun“).
    func speak(_ token: String, attributive att: Bool = false, feminine fem: Bool = false) -> String {
        let (i, f) = parse(token)
        var out = integerWords(i, attributive: att && f == nil, feminine: fem && f == nil)
        if let f, !f.isEmpty {
            let digits = f.compactMap { $0.wholeNumberValue }.map { cardinal($0) }.joined(separator: sep)
            out += sep + lex.decimalWord + sep + digits
        }
        return out
    }

    private func isOne(_ token: String) -> Bool {
        let (i, f) = parse(token)
        return f == nil && Int(i) == 1
    }

    /// Jahreszahl: de 1984 → „neunzehnhundertvierundachtzig“, en → „nineteen eighty-four“.
    func year(_ n: Int) -> String {
        switch language {
        case .de where (1100...1999).contains(n):
            let r = n % 100
            return cardinal(n / 100) + "hundert" + (r > 0 ? cardinal(r) : "")
        case .en where (1100...1999).contains(n):
            let (h, r) = (n / 100, n % 100)
            if r == 0 { return cardinal(h) + " hundred" }
            if r < 10 { return cardinal(h) + " oh " + cardinal(r) }
            return cardinal(h) + " " + cardinal(r)
        default:
            return cardinal(n)
        }
    }

    // MARK: Abkürzungen

    private func abbreviations(_ text: String) -> String {
        var s = text
        for abbr in Abbreviations.list(for: language) {
            let core = Abbreviations.pattern(for: abbr)
            let guardPattern = #"(?<![\p{L}\p{N}])"# + core + #"(?![\p{L}\p{N}])"#
            let lowerFirst = abbr.written.first.map { $0.isLowercase } ?? false
            // Satzende behalten: „… usw.“ → „… und so weiter.“
            if abbr.mayEndSentence {
                s = s.replacingMatches(of: guardPattern + #"(?=\s*$)"#, options: .caseInsensitive) { m in
                    self.spokenAbbreviation(abbr, matched: m.whole, lowerFirst: lowerFirst) + "."
                }
            }
            s = s.replacingMatches(of: guardPattern, options: .caseInsensitive) { m in
                self.spokenAbbreviation(abbr, matched: m.whole, lowerFirst: lowerFirst)
            }
        }
        return s
    }

    private func spokenAbbreviation(_ abbr: Abbreviation, matched: String, lowerFirst: Bool) -> String {
        if lowerFirst, let f = matched.first, f.isUppercase { return abbr.spoken.capitalizedFirst }
        return abbr.spoken
    }

    // MARK: Prozent

    private func percent(_ text: String) -> String {
        let p = Self.before + #"([-−])?("# + num + #")\s?%"#
        return text.replacingMatches(of: p) { m in
            let n = self.speak(m[2]!)
            let signed = (m[1] != nil ? self.lex.minusWord + self.sep : "") + n
            return self.lex.percentIsPrefix ? self.lex.percent + signed
                : signed + self.sep + self.lex.percent
        }
    }

    // MARK: Zahlen allgemein

    private func numbers(_ text: String) -> String {
        let p = #"(\p{L})?(?:(?<![\p{L}\p{N}])([-−]))?"# + Self.before + #"("# + num + #")(?![\p{N}])(\p{L})?"#
        let cjk = language.isCJK
        return text.replacingMatches(of: p) { m in
            var body: String
            let token = m[3]!
            if token.count == 4, let y = Int(token), m[2] == nil, self.language == .de || self.language == .en,
               (1100...1999).contains(y) {
                body = self.year(y)
            } else {
                body = self.speak(token)
            }
            if m[2] != nil { body = self.lex.minusWord + self.sep + body }
            var out = ""
            if let a = m[1] { out += a + (cjk ? "" : " ") }
            out += body
            if let b = m[4] { out += (cjk ? "" : " ") + b }
            return out
        }
    }

    // MARK: Ausgebaut (de, pt)

    private func urlsAndEmails(_ text: String) -> String {
        func spell(_ raw: String) -> String {
            var core = raw
            var tail = ""
            while let l = core.last, ".,;:!?)".contains(l) { tail = String(l) + tail; core.removeLast() }
            core = core.replacingOccurrences(of: #"^https?://"#, with: "", options: .regularExpression)
            let w = lex.urlWords
            var out = ""
            for ch in core {
                switch ch {
                case ".": out += " \(w.dot) "
                case "/": out += " \(w.slash) "
                case "@": out += " \(w.at) "
                case "-": out += " \(w.dash) "
                case "_": out += " \(w.underscore) "
                case ":", "?", "&", "=", "#", "%", "+", "~": out += " "
                default: out.append(ch)
                }
            }
            return out.split(separator: " ").joined(separator: " ") + tail
        }
        var s = text.replacingMatches(of: #"(?:https?://|www\.)[^\s<>"']+"#) { spell($0.whole) }
        s = s.replacingMatches(of: #"[\p{L}\p{N}._%+-]+@[\p{L}\p{N}-]+(?:\.[\p{L}\p{N}-]+)+"#) { spell($0.whole) }
        return s
    }

    private func validDate(_ d: Int, _ m: Int) -> Bool { (1...31).contains(d) && (1...12).contains(m) }

    private func dateSpeech(day: Int, month: Int, year y: Int?, oblique: Bool = false) -> String {
        let monthName = lex.months[month - 1]
        switch language {
        case .de:
            var out = ordinalDe(day) + (oblique ? "n " : "r ") + monthName
            if let y { out += " " + year(y) }
            return out
        default:
            var out = (day == 1 ? "primeiro" : cardinal(day)) + " de " + monthName
            if let y { out += " de " + cardinal(y) }
            return out
        }
    }

    private func dates(_ text: String) -> String {
        var s = text
        // ISO 2024-05-03
        s = s.replacingMatches(of: #"(?<![\p{N}-])(\d{4})-(\d{2})-(\d{2})(?![\p{N}])"#) { m in
            guard let y = Int(m[1]!), let mo = Int(m[2]!), let d = Int(m[3]!), self.validDate(d, mo) else { return nil }
            return self.dateSpeech(day: d, month: mo, year: y)
        }
        let monthAlt = lex.months.joined(separator: "|")
        if language == .de {
            // Nach „am/vom/zum/dem/den“ steht der Tag im Dativ/Akkusativ: „am dritten Mai“.
            let prep = #"(?<![\p{L}])((?i:am|vom|zum|dem|den)\s+)?"#
            s = s.replacingMatches(of: prep + #"(?<![\p{N}.])(\d{1,2})\.\s?(\d{1,2})\.(?:\s?(\d{4}))?(?![\p{N}])"#) { m in
                guard let d = Int(m[2]!), let mo = Int(m[3]!), self.validDate(d, mo) else { return nil }
                return (m[1] ?? "") + self.dateSpeech(day: d, month: mo, year: m[4].flatMap { Int($0) }, oblique: m[1] != nil)
            }
            s = s.replacingMatches(of: prep + #"(?<![\p{N}.])(\d{1,2})\.\s?("# + monthAlt + #")(?![\p{L}])(?:\s(\d{4})(?![\p{N}]))?"#) { m in
                guard let d = Int(m[2]!), let mo = self.lex.months.firstIndex(of: m[3]!), (1...31).contains(d) else { return nil }
                return (m[1] ?? "") + self.dateSpeech(day: d, month: mo + 1, year: m[4].flatMap { Int($0) }, oblique: m[1] != nil)
            }
        } else {
            s = s.replacingMatches(of: #"(?<![\p{N}/.-])(\d{1,2})[/.-](\d{1,2})[/.-](\d{4})(?![\p{N}])"#) { m in
                guard let d = Int(m[1]!), let mo = Int(m[2]!), let y = Int(m[3]!), self.validDate(d, mo) else { return nil }
                return self.dateSpeech(day: d, month: mo, year: y)
            }
            s = s.replacingMatches(
                of: #"(?<![\p{N}])(\d{1,2})\s+de\s+("# + monthAlt + #")(?![\p{L}])(?:\s+de\s+(\d{4})(?![\p{N}]))?"#,
                options: .caseInsensitive
            ) { m in
                guard let d = Int(m[1]!), let mo = self.lex.months.firstIndex(of: m[2]!.lowercased()), (1...31).contains(d) else { return nil }
                return self.dateSpeech(day: d, month: mo + 1, year: m[3].flatMap { Int($0) })
            }
        }
        return s
    }

    private func times(_ text: String) -> String {
        var s = text
        let b = #"(?<![\p{N}:.])"#
        if language == .de {
            func say(_ h: Int, _ m: Int) -> String? {
                guard (0...24).contains(h), (0...59).contains(m) else { return nil }
                return self.attributive(h) + " Uhr" + (m > 0 ? " " + self.cardinal(m) : "")
            }
            s = s.replacingMatches(of: b + #"(\d{1,2})[:.](\d{2})\s?Uhr(?![\p{L}])"#) { m in
                say(Int(m[1]!)!, Int(m[2]!)!)
            }
            s = s.replacingMatches(of: b + #"(\d{1,2})\s?Uhr(?![\p{L}])"#) { m in
                say(Int(m[1]!)!, 0)
            }
            s = s.replacingMatches(of: b + #"(\d{1,2}):(\d{2})(?![\p{N}:])"#) { m in
                say(Int(m[1]!)!, Int(m[2]!)!)
            }
        } else {
            func say(_ h: Int, _ m: Int) -> String? {
                guard (0...24).contains(h), (0...59).contains(m) else { return nil }
                return self.feminine(h) + (h == 1 ? " hora" : " horas") + (m > 0 ? " e " + self.cardinal(m) : "")
            }
            s = s.replacingMatches(of: b + #"(\d{1,2}):(\d{2})(?![\p{N}:])"#) { m in
                say(Int(m[1]!)!, Int(m[2]!)!)
            }
            s = s.replacingMatches(of: b + #"(\d{1,2})h(\d{2})?(?![\p{L}\p{N}])"#) { m in
                say(Int(m[1]!)!, m[2].flatMap { Int($0) } ?? 0)
            }
        }
        return s
    }

    private func money(_ text: String) -> String {
        let keys = lex.currencies.keys.sorted { $0.count > $1.count }
        let alt = keys.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let symbols = keys.filter { !($0.first?.isLetter ?? false) || $0 == "r$" }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")

        func say(_ token: String, _ key: String) -> String? {
            guard let cur = lex.currencies[key.lowercased()] else { return nil }
            let (i, f) = parse(token)
            guard i.count <= 12, let whole = Int(i) else { return nil }
            var cents = 0
            if let f {
                guard f.count <= 2, let c = Int(f) else { return nil }
                cents = f.count == 1 ? c * 10 : c
            }
            let isPt = language == .pt
            if whole == 0 && cents > 0 {
                return cardinal(cents) + " " + (cents == 1 ? cur.cent : cur.cents)
            }
            var out = (isPt ? cardinal(whole) : attributive(whole)) + " "
            if isPt, whole >= 1_000_000, whole % 1_000_000 == 0 { out += "de " }
            out += whole == 1 ? cur.singular : cur.plural
            if cents > 0 { out += (isPt ? " e " : " ") + cardinal(cents) }
            return out
        }
        var s = text.replacingMatches(
            of: Self.before + "(" + num + #")\s?("# + alt + #")(?![\p{L}])"#,
            options: .caseInsensitive
        ) { m in say(m[1]!, m[2]!) }
        s = s.replacingMatches(of: "(" + symbols + #")\s?("# + num + ")(?![\\p{N}])", options: .caseInsensitive) { m in
            say(m[2]!, m[1]!)
        }
        return s
    }

    private func phones(_ text: String) -> String {
        text.replacingMatches(of: #"(?<![\p{L}\p{N}])[+(]?\d[\d  ()/-]{5,}\d(?![\p{N}])"#) { m in
            let raw = m.whole
            let digitCount = raw.filter { $0.isNumber }.count
            guard (7...15).contains(digitCount) else { return nil }
            let hasPlus = raw.hasPrefix("+")
            let groups = raw.split(whereSeparator: { " \u{00A0}()/-".contains($0) }).map(String.init)
                .map { $0.filter { $0.isNumber } }.filter { !$0.isEmpty }
            let looksLikePhone = hasPlus || raw.hasPrefix("0") || raw.contains("(") || raw.contains("/") || groups.count >= 3
            guard looksLikePhone else { return nil }
            let spoken = groups.map { g in g.compactMap { $0.wholeNumberValue }.map { self.cardinal($0) }.joined(separator: " ") }
                .joined(separator: ", ")
            return (hasPlus ? self.lex.plusWord + " " : "") + spoken
        }
    }

    private func units(_ text: String) -> String {
        let defs = lex.units.sorted { $0.symbol.count > $1.symbol.count }
        let alt = defs.map { NSRegularExpression.escapedPattern(for: $0.symbol) }.joined(separator: "|")
        let p = Self.before + #"([-−])?("# + num + #")\s?("# + alt + #")(?![\p{L}\p{N}²³/])"#
        return text.replacingMatches(of: p) { m in
            guard let def = defs.first(where: { $0.symbol == m[3] }) else { return nil }
            let token = m[2]!
            let one = self.isOne(token)
            let n = self.speak(token, attributive: !def.feminine, feminine: def.feminine)
            let signed = (m[1] != nil ? self.lex.minusWord + " " : "") + n
            return signed + " " + (one ? def.singular : def.plural)
        }
    }

    // MARK: Ordnungszahlen

    /// „dritte“, „zwanzigste“ (ohne Fallendung; Datum hängt „r“ an).
    func ordinalDe(_ n: Int) -> String {
        let special = [1: "ers", 3: "drit", 7: "sieb", 8: "ach"]
        if n < 20 { return (special[n] ?? cardinal(n)) + "te" }
        return cardinal(n) + "ste"
    }

    private static let ptUnits = ["", "primeiro", "segundo", "terceiro", "quarto", "quinto", "sexto", "sétimo", "oitavo", "nono"]
    private static let ptTens = ["", "décimo", "vigésimo", "trigésimo", "quadragésimo", "quinquagésimo",
                                 "sexagésimo", "septuagésimo", "octogésimo", "nonagésimo"]

    func ordinalPt(_ n: Int, feminine fem: Bool) -> String? {
        var words: [String]
        switch n {
        case 1...9: words = [Self.ptUnits[n]]
        case 10...99:
            words = [Self.ptTens[n / 10]]
            if n % 10 > 0 { words.append(Self.ptUnits[n % 10]) }
        case 100: words = ["centésimo"]
        default: return nil
        }
        if fem { words = words.map { $0.hasSuffix("o") ? String($0.dropLast()) + "a" : $0 } }
        return words.joined(separator: " ")
    }

    private func ordinals(_ text: String) -> String {
        if language == .de {
            // „der 2. Weltkrieg“ → „der zweite Weltkrieg“ (Fallendung bleibt offen)
            return text.replacingMatches(of: #"(?<!\d[.,])(?<![\p{N}])(\d{1,2})\.(?=\s+\p{L})"#) { m in
                guard let n = Int(m[1]!), n >= 1 else { return nil }
                return self.ordinalDe(n)
            }
        }
        return text.replacingMatches(of: #"(?<![\p{N}])(\d{1,3})\s?\.?([ºª])"#) { m in
            guard let n = Int(m[1]!) else { return nil }
            return self.ordinalPt(n, feminine: m[2] == "ª")
        }
    }
}
