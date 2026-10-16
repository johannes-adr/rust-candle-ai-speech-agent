// Anzeige-Hilfen: Dauer, Datum, übersetzte Texte mit Platzhaltern.
import Foundation
import SwiftUI
import TextPrep

/// Übersetzter Text zu einem Schlüssel aus Localizable.xcstrings.
func L(_ key: String) -> String {
    String(localized: String.LocalizationValue(key))
}

/// Übersetzter Text mit Platzhaltern (%@, %lld).
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

enum Fmt {
    /// „3 Min.“ bzw. „unter 1 Min.“
    static func minutes(_ seconds: Double) -> String {
        let m = Int((seconds / 60).rounded())
        return m < 1 ? L("books.lessThanMinute") : L("books.minutes", m)
    }

    /// „gestern“, „vor 2 Tagen“ – in der Sprache der Oberfläche.
    static func relative(_ date: Date, now: Date = Date()) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// „2:05“ für den Player.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Restzeit in ganzen Minuten (aufgerundet), nil wenn unbekannt.
    static func remainingMinutes(_ seconds: Double?) -> Int? {
        seconds.map { Int(($0 / 60).rounded(.up)) }
    }
}

extension Language {
    var nameKey: String { "lang.\(rawValue)" }
}
