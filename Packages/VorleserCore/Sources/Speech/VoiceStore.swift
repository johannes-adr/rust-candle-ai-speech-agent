// Stimmen: nur eigene (aufgenommen, importiert, beschrieben). Jede Stimme besteht aus Audio und
// dem Text, mit dem sie aufgenommen wurde (`<id>.caf` + `<id>.txt`, siehe `RecordedVoiceStore`).
// Beim Vorlesen dient immer dieser gespeicherte Text als `referenceText`.
import Foundation
import TextPrep

public struct VoiceStore: Sendable {
    /// Ordner mit den eigenen Stimmen.
    public let custom: RecordedVoiceStore

    public init(customDirectory: URL = RecordedVoiceStore.defaultDirectory) {
        self.custom = RecordedVoiceStore(directory: customDirectory)
    }

    /// Die Stimme für die Engine (Audio plus gespeicherter Text), `nil` wenn es sie nicht gibt.
    public func voice(id: String) -> Voice? { custom.voice(id: id) }

    /// Alle eigenen Stimmen einer Sprache (aufgenommen, importiert, beschrieben).
    public func voices(for language: Language) -> [RecordedVoiceInfo] { custom.list(language: language) }

    /// Aufgenommene oder importierte Stimmen einer Sprache.
    public func recordedVoices(for language: Language) -> [RecordedVoiceInfo] {
        voices(for: language).filter { $0.kind != .designed }
    }

    /// Beschriebene Stimmen einer Sprache (Phase 4, „Design → Klon“).
    public func designedVoices(for language: Language) -> [RecordedVoiceInfo] {
        voices(for: language).filter { $0.kind == .designed }
    }
}
