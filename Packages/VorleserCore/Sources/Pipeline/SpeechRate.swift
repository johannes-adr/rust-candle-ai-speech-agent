import TextPrep

/// Erwartete Sprechrate in Zeichen (der gesprochenen Form) je Sekunde, Grundlage der
/// Dauerprüfung (`ChunkQC`: unter 0,5× oder über 2× der erwarteten Dauer gilt als verdächtig).
///
/// Gemessen (Spike S1, `spike-output/S1/*.wav`, je 3 Abschnitte à ca. 300 Zeichen, Referenzstimme
/// „ruhig, warm“, 4- und 8-bit gemittelt, Stille am Rand eingerechnet):
/// - Deutsch 15,5 (4-bit) und 16,2 (8-bit) → 15,8
/// - Portugiesisch 14,4 und 15,4 → 14,9
///
/// Die übrigen Sprachen sind **geschätzt** (noch nicht mit dem Modell gemessen, gehört zu S2):
/// - en/es/fr/it ca. 15 (ähnliche Silbendichte wie de/pt), ru 14 (längere Wörter)
/// - zh ca. 4,5 Zeichen/s (ein Zeichen = eine Silbe, ruhiges Sprechen ca. 4–5 Silben/s)
/// - ja ca. 7 Zeichen/s (Mischung aus Kana und Kanji, ca. 8–10 Moren/s)
/// - ko ca. 6,5 Zeichen/s (Silbenblöcke)
/// Das Fenster 0,5×–2× fängt Fehler von ±30 % ab; die Schätzwerte müssen nur grob stimmen.
public enum SpeechRate {
    public static func charsPerSecond(for language: Language) -> Double {
        switch language {
        case .de: 15.8
        case .pt: 14.9
        case .en: 15
        case .es: 15.5
        case .fr: 15
        case .it: 15
        case .ru: 14
        case .zh: 4.5
        case .ja: 7
        case .ko: 6.5
        }
    }
}
