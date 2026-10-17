import Foundation

/// Plant aus einem Dokument die Abschnitte, die das Modell einzeln spricht.
///
/// - Absätze werden in Sätze geteilt (`SentenceSplitter`) und innerhalb eines
///   Absatzes zu Abschnitten von `minLength…maxLength` Zeichen gepackt.
/// - Ein Absatz endet immer an einer Abschnittsgrenze.
/// - Zu lange Sätze werden an `;`/`:`, dann an `,`, zuletzt am Leerzeichen
///   geteilt – nie in einer Zahl wie `19,99`, `19.99`, `1.000,50`, `14:30`.
/// - Die Länge wird an der gesprochenen Form gemessen (Zahlen ausgeschrieben).
public struct ChunkPlanner: Sendable {
    public var splitter: SentenceSplitter
    /// Höchstzahl Wörter je Abschnitt (Helfer-Einstellung); `nil` = Standard (200–500 Zeichen).
    public var maxWords: Int?

    public init(splitter: SentenceSplitter = .init(), maxWords: Int? = nil) {
        self.splitter = splitter
        self.maxWords = maxWords
    }

    /// Zielbereich in Zeichen; CJK ca. ein Drittel.
    public static func lengthRange(for language: Language) -> ClosedRange<Int> {
        language.isCJK ? 70...170 : 200...500
    }

    /// Zielbereich aus einer Wortzahl: ca. 6 Zeichen je Wort (mit Leerzeichen), CJK ca. 2 Zeichen;
    /// untere Grenze 40 % der oberen (wie beim Standard 200…500).
    public static func lengthRange(for language: Language, maxWords: Int?) -> ClosedRange<Int> {
        guard let words = maxWords, words > 0 else { return lengthRange(for: language) }
        let upper = max(language.isCJK ? 20 : 40, words * (language.isCJK ? 2 : 6))
        return (upper * 2 / 5)...upper
    }

    private struct Unit {
        var text: String
        var spoken: String
    }

    public func plan(
        document: TextDocument,
        language: Language,
        normalizer: (any Normalizer)? = nil
    ) -> [Chunk] {
        let range = Self.lengthRange(for: language, maxWords: maxWords)
        let join = language.isCJK ? "" : " "
        let spokenOf: @Sendable (String) -> String = { normalizer?.normalize($0) ?? $0 }
        var chunks: [Chunk] = []
        var chapter = 0

        func append(_ text: String, _ spoken: String, _ kind: ChunkKind) {
            chunks.append(Chunk(index: chunks.count, text: text, spokenText: spoken, kind: kind, chapter: chapter))
        }

        for block in document.blocks {
            switch block {
            case .heading(_, let text):
                let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { continue }
                chapter += 1
                append(t, spokenOf(t), .heading)
            case .paragraph(let text):
                let flat = text.replacingMatches(of: #"\s+"#) { _ in " " }
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !flat.isEmpty else { continue }
                let groups = pack(units(of: flat, language: language, range: range, spokenOf: spokenOf), range: range, join: join)
                for (i, g) in groups.enumerated() {
                    append(g.map(\.text).joined(separator: join),
                           g.map(\.spoken).joined(separator: join),
                           i == groups.count - 1 ? .paragraphEnd : .sentence)
                }
            }
        }
        return chunks
    }

    // MARK: Sätze und Teilstücke

    private func units(
        of paragraph: String, language: Language, range: ClosedRange<Int>,
        spokenOf: @Sendable (String) -> String
    ) -> [Unit] {
        var out: [Unit] = []
        for sentence in splitter.split(paragraph, language: language) {
            let spoken = spokenOf(sentence)
            if spoken.count <= range.upperBound {
                out.append(Unit(text: sentence, spoken: spoken))
            } else {
                for piece in splitLong(sentence, language: language, max: range.upperBound, spokenOf: spokenOf) {
                    out.append(Unit(text: piece, spoken: spokenOf(piece)))
                }
            }
        }
        return out
    }

    /// Greedy packen, danach ein zu kurzes Ende mit dem Vorgänger ausgleichen.
    private func pack(_ units: [Unit], range: ClosedRange<Int>, join: String) -> [[Unit]] {
        var groups: [[Unit]] = []
        var current: [Unit] = []
        func len(_ g: [Unit]) -> Int { g.reduce(0) { $0 + $1.spoken.count } + max(0, g.count - 1) * join.count }
        for u in units {
            if !current.isEmpty, len(current + [u]) > range.upperBound {
                groups.append(current)
                current = []
            }
            current.append(u)
        }
        if !current.isEmpty { groups.append(current) }

        // Zu kurzes letztes Stück: erst anhängen, sonst Sätze vom Vorgänger holen.
        while groups.count >= 2, len(groups[groups.count - 1]) < range.lowerBound {
            let last = groups.removeLast()
            var prev = groups.removeLast()
            if len(prev + last) <= range.upperBound {
                groups.append(prev + last)
                break
            }
            var moved = last
            while prev.count > 1, len(moved) < range.lowerBound, let tail = prev.last,
                  len(Array(prev.dropLast())) >= range.lowerBound,
                  len([tail] + moved) <= range.upperBound {
                prev.removeLast()
                moved.insert(tail, at: 0)
            }
            groups.append(prev)
            groups.append(moved)
            break
        }
        return groups
    }

    // MARK: Lange Sätze teilen

    private static let strongMarks: Set<Character> = [";", ":", "；", "："]
    private static let weakMarks: Set<Character> = [",", "，", "、"]

    /// Teilt einen zu langen Satz, bis alle Teile in `max` passen.
    func splitLong(
        _ text: String, language: Language, max: Int,
        spokenOf: @Sendable (String) -> String
    ) -> [String] {
        func measure(_ s: String) -> Int { spokenOf(s).count }
        if measure(text) <= max { return [text] }
        let chars = Array(text)
        let levels: [Set<Character>] = [Self.strongMarks, Self.weakMarks]
        var splitIndex: Int?
        for marks in levels {
            let points = Self.splitPoints(in: chars, marks: marks)
            if let best = Self.bestPoint(points, in: chars, measure: measure) {
                splitIndex = best
                break
            }
        }
        if splitIndex == nil {
            // Kein Zeichen gefunden: Leerzeichen, bei CJK mitten durch.
            if language.isCJK {
                splitIndex = chars.count / 2
            } else {
                let points = chars.indices.filter { i in
                    guard chars[i] == " ", i > 0, i < chars.count - 1 else { return false }
                    // „1 000“ nicht trennen.
                    return !(chars[i - 1].isNumber && chars[i + 1].isNumber)
                }.map { $0 + 1 }
                splitIndex = Self.bestPoint(points, in: chars, measure: measure) ?? chars.count / 2
            }
        }
        guard let cut = splitIndex, cut > 0, cut < chars.count else { return [text] }
        let left = String(chars[..<cut]).trimmingCharacters(in: .whitespaces)
        let right = String(chars[cut...]).trimmingCharacters(in: .whitespaces)
        return splitLong(left, language: language, max: max, spokenOf: spokenOf)
            + splitLong(right, language: language, max: max, spokenOf: spokenOf)
    }

    /// Indizes direkt hinter einem Trennzeichen, das nicht zwischen zwei Ziffern steht.
    static func splitPoints(in chars: [Character], marks: Set<Character>) -> [Int] {
        var out: [Int] = []
        for i in chars.indices where marks.contains(chars[i]) {
            let prevDigit = i > 0 && chars[i - 1].isNumber
            let nextDigit = i + 1 < chars.count && chars[i + 1].isNumber
            if prevDigit && nextDigit { continue }
            if i + 1 >= chars.count { continue }
            out.append(i + 1)
        }
        return out
    }

    /// Wählt den Punkt mit den ausgewogensten Hälften.
    private static func bestPoint(_ points: [Int], in chars: [Character], measure: (String) -> Int) -> Int? {
        var best: (idx: Int, score: Int)?
        for p in points {
            let l = measure(String(chars[..<p])), r = measure(String(chars[p...]))
            guard l > 0, r > 0 else { continue }
            let score = abs(l - r)
            if best == nil || score < best!.score { best = (p, score) }
        }
        return best?.idx
    }
}
