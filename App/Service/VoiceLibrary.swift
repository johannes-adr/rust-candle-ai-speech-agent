// Eigene Stimmen (aufgenommen, importiert, beschrieben), gelesen vom VoiceStore im Package.
// Es gibt keine fertigen Stimmen: jede Stimme hat ihre Aufnahme und den Text, mit dem sie
// aufgenommen wurde.
import Foundation
import VorleserSpeech
import TextPrep

/// Eine Stimme für die Anzeige (Karten, Auswahl).
struct StoredVoice: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
}

/// Dünne Hülle um `VoiceStore` (Package `Speech`): dieselbe Quelle für Oberfläche und Engine.
struct VoiceLibrary: Sendable {
    let store: VoiceStore

    init(customDirectory: URL = VoiceLibrary.defaultCustomDirectory) {
        self.store = VoiceStore(customDirectory: customDirectory)
    }

    /// Eigene Stimmen liegen in Application Support (nicht im Paket). Debug: unter `VORLESER_DATA_DIR/Voices`.
    static var defaultCustomDirectory: URL {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if let dir = env["VORLESER_DATA_DIR"], env["VORLESER_CUSTOM_VOICES_DIR"] == nil {
            return URL(fileURLWithPath: dir, isDirectory: true).appending(path: "Voices", directoryHint: .isDirectory)
        }
        #endif
        return RecordedVoiceStore.defaultDirectory
    }

    /// Aufgenommene und importierte Stimmen der Sprache.
    func recordedVoices(for language: Language) -> [StoredVoice] {
        store.recordedVoices(for: language).map(Self.convert)
    }

    /// Alle Stimmen der Sprache (aufgenommen, importiert, beschrieben), für Schritt ②.
    func voices(for language: Language) -> [StoredVoice] {
        store.voices(for: language).map(Self.convert)
    }

    func voice(id: String) -> StoredVoice? {
        store.custom.info(id: id).map(Self.convert)
    }

    /// Pfad der Aufnahme, nur wenn die Stimme vollständig da ist.
    func referenceURL(voiceID: String) -> URL? {
        store.custom.info(id: voiceID).map { store.custom.audioURL(id: $0.id) }
    }

    private static func convert(_ r: RecordedVoiceInfo) -> StoredVoice {
        StoredVoice(id: r.id, name: r.name)
    }
}

/// Fester Lesetext für die eigene Aufnahme (Phase 3), je Sprache.
enum ReadAloudText {
    static func text(for language: Language, in bundle: Bundle = .main) -> String? {
        guard let url = bundle.resourceURL?.appending(path: "ReadAloud/\(language.rawValue).txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
