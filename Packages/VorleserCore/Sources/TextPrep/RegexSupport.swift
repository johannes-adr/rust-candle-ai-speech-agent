import Foundation

/// Ein Treffer mit Gruppen (Gruppe 0 = ganzer Treffer).
struct RegexMatch {
    let groups: [String?]
    subscript(_ i: Int) -> String? { i < groups.count ? groups[i] : nil }
    var whole: String { groups[0] ?? "" }
}

/// Kleiner Cache, damit Muster nicht je Abschnitt neu übersetzt werden.
private final class RegexCache: @unchecked Sendable {
    private var cache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    func regex(_ pattern: String, _ options: NSRegularExpression.Options) -> NSRegularExpression {
        let key = "\(options.rawValue)|\(pattern)"
        lock.lock()
        defer { lock.unlock() }
        if let r = cache[key] { return r }
        // Muster sind im Code festgelegt; ein Fehler ist ein Programmierfehler.
        let r = try! NSRegularExpression(pattern: pattern, options: options)
        cache[key] = r
        return r
    }
}

private let regexCache = RegexCache()

extension String {
    func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        regexCache.regex(pattern, options)
    }

    /// Ersetzt jeden Treffer; `nil` aus der Closure lässt den Treffer unverändert.
    func replacingMatches(
        of pattern: String,
        options: NSRegularExpression.Options = [],
        _ transform: (RegexMatch) -> String?
    ) -> String {
        let re = regex(pattern, options)
        let ns = self as NSString
        let matches = re.matches(in: self, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return self }
        var result = ""
        var last = 0
        for m in matches {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var groups: [String?] = []
            for g in 0..<m.numberOfRanges {
                let r = m.range(at: g)
                groups.append(r.location == NSNotFound ? nil : ns.substring(with: r))
            }
            result += transform(RegexMatch(groups: groups)) ?? groups[0] ?? ""
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }

    func matches(_ pattern: String, _ options: NSRegularExpression.Options = []) -> Bool {
        let re = regex(pattern, options)
        return re.firstMatch(in: self, range: NSRange(location: 0, length: (self as NSString).length)) != nil
    }

    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
