// Beschriebene Stimmen (Phase 4, „Design → Klon“): VoiceDesign erzeugt einmal eine Referenz,
// Base klont sie danach für jeden Abschnitt. Gespeichert wird im selben Format und Ordner wie die
// eigenen Aufnahmen (`RecordedVoiceStore`, IDs `own-…`), aber mit `kind == .designed`.
import Foundation
import TextPrep

public extension RecordedVoiceStore {
    /// Speichert die gewählte Referenz als beschriebene Stimme. Es gibt keine fremde Stimme, daher
    /// zählt der Wunsch der Nutzerin als Zustimmung (`consent`).
    @discardableResult
    func saveDesigned(
        samples: [Float], sampleRate: Double, referenceText: String, name: String, language: Language,
        wish: String, prompt: String?, seed: UInt64?, now: Date = Date()
    ) throws -> Voice {
        let voice = try save(
            samples: samples, sampleRate: sampleRate, transcript: referenceText, name: name, language: language,
            consent: true, source: "design", transcriptSource: "reading", now: now)
        // Art und Wunsch nachtragen (die Metadaten wurden eben geschrieben).
        guard var info = info(id: voice.id) else { throw RecordedVoiceError.notFound(voice.id) }
        info.kind = .designed
        info.wish = wish
        info.prompt = prompt
        info.seed = seed
        try write(info)
        return Voice(
            id: voice.id, name: voice.name, language: language, kind: .designed,
            referenceAudio: voice.referenceAudio, referenceText: voice.referenceText, description: wish)
    }

    func isDesigned(id: String) -> Bool { info(id: id)?.kind == .designed }

    func designedList(language: Language) -> [RecordedVoiceInfo] {
        list(language: language).filter { $0.kind == .designed }
    }
}
