/// Die zehn Sprachen, die Qwen3-TTS vorlesen kann.
public enum Language: String, CaseIterable, Codable, Sendable {
    case de, pt, en, es, fr, it, ru, zh, ja, ko

    /// Chinesisch, Japanisch und Koreanisch brauchen kürzere Abschnitte (ca. ⅓).
    public var isCJK: Bool { self == .zh || self == .ja || self == .ko }
}
