// Anbindung des Ablaufs „Eigene Stimme“ an AppModel (Navigation, Auswahl der neuen Stimme).
import Foundation
import VorleserSpeech
import TextPrep

extension AppModel {
    /// Ist gerade eine aufgenommene (eigene) Stimme gewählt? Dann gibt es keine Stil-Knöpfe.
    var isOwnVoiceSelected: Bool {
        draft?.voiceID?.hasPrefix(RecordedVoiceStore.idPrefix) ?? false
    }

    /// Knopf „Meine eigene Stimme“ in Schritt ②.
    func startOwnVoice() {
        guard let language = draft?.language else { return }
        guard let text = ReadAloudText.text(for: language), !text.isEmpty else {
            screen = .problem("problem.unreadable")
            return
        }
        ownVoice = OwnVoiceFlow(
            language: language, readingText: text, defaultName: L("ownVoice.name.default"),
            store: library.store.custom ?? RecordedVoiceStore(),
            onSaved: { [weak self] voice in self?.finishOwnVoice(selecting: voice) },
            onCancel: { [weak self] in self?.leaveOwnVoice() })
        screen = .ownVoice
    }

    /// Fertig: zurück zu ② mit der neuen Stimme ausgewählt.
    func finishOwnVoice(selecting voice: Voice) {
        ownVoice = nil
        draft?.voiceID = voice.id
        screen = .voice
    }

    func leaveOwnVoice() {
        ownVoice = nil
        screen = .voice
    }

    /// Nach Löschen im Helfer-Fenster: Auswahl zurücksetzen, falls die Stimme weg ist.
    func validateSelectedVoice() {
        guard var d = draft, let id = d.voiceID, id.hasPrefix(RecordedVoiceStore.idPrefix) else { return }
        if library.store.custom?.info(id: id) == nil {
            d.voiceID = library.voices(for: d.language).first?.id
            draft = d
        }
    }
}
