// Vergleich von Spracherkennungs-Ergebnis und festem Lesetext: WER (Wörter) bzw. CER (Zeichen
// bei Chinesisch, Japanisch, Koreanisch). Normalisiert: Kleinbuchstaben, Satzzeichen weg,
// bei Alphabetsprachen auch Akzente egal (Erkennung setzt sie nicht immer gleich).
import Foundation
import TextPrep

public enum TranscriptScoring {
    /// Ab dieser Fehlerrate gilt der Text als schwer verständlich (PLAN §3: > 30 %).
    public static let maxErrorRate = 0.30

    /// Kleinbuchstaben, Satzzeichen und Symbole weg, Leerraum vereinheitlicht.
    public static func normalize(_ text: String, language: Language) -> String {
        var s = text.lowercased()
        if !language.isCJK { s = s.folding(options: [.diacriticInsensitive], locale: nil) }
        // Apostrophe und Bindestriche verbinden Wörter („l'ami“, „Rück-Seite“): Leerzeichen daraus machen.
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            let cat = u.properties.generalCategory
            switch cat {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                 .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol,
                 .control, .format:
                out.append(" ")
            default:
                out.append(u)
            }
        }
        return String(out).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Wörter (Alphabetsprachen) bzw. Zeichen ohne Leerraum (zh, ja, ko).
    public static func tokens(_ text: String, language: Language) -> [String] {
        let n = normalize(text, language: language)
        if language.isCJK { return n.filter { !$0.isWhitespace }.map { String($0) } }
        return n.split(separator: " ").map(String.init)
    }

    /// Fehlerrate = Editierabstand ÷ Länge des Lesetexts (kann über 1 liegen).
    public static func errorRate(reference: String, hypothesis: String, language: Language) -> Double {
        let r = tokens(reference, language: language)
        let h = tokens(hypothesis, language: language)
        guard !r.isEmpty else { return h.isEmpty ? 0 : 1 }
        return Double(editDistance(r, h)) / Double(r.count)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

/// Ergebnis des Lese-Checks.
public enum ReadingCheckResult: Sendable, Equatable {
    /// Der Lesetext wurde (fast) vorgelesen.
    case ok(errorRate: Double)
    /// Zu viele Abweichungen: „Bitte nochmal, der Text war schwer zu verstehen“.
    case mismatch(errorRate: Double)
    /// Keine Spracherkennung möglich (Sprache nicht unterstützt, Daten nicht installiert, keine Erlaubnis):
    /// es bleibt bei der Dauer- und Pegelprüfung.
    case unchecked(TranscriptionUnavailable)

    public var hintKey: String? {
        if case .mismatch = self { "ownVoice.hint.mismatch" } else { nil }
    }
}

public enum ReadingChecker {
    /// Erkennt die Aufnahme und vergleicht mit dem festen Lesetext. Das Transkript für das
    /// Klonen bleibt immer der Lesetext, nie das Erkennungsergebnis.
    public static func check(
        samples: [Float], sampleRate: Double, expectedText: String, language: Language,
        transcriber: any SpeechTranscribing, maxErrorRate: Double = TranscriptScoring.maxErrorRate
    ) async -> ReadingCheckResult {
        let tmp = FileManager.default.temporaryDirectory.appending(path: "vorleser-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do { try AudioFiles.writeWAV(samples, sampleRate: sampleRate, to: tmp) } catch { return .unchecked(.failed) }
        switch await transcriber.transcribe(fileURL: tmp, language: language) {
        case .unavailable(let why):
            return .unchecked(why)
        case .text(let heard, _):
            let rate = TranscriptScoring.errorRate(reference: expectedText, hypothesis: heard, language: language)
            return rate > maxErrorRate ? .mismatch(errorRate: rate) : .ok(errorRate: rate)
        }
    }
}
