// Einstellungen für den Helfer (Name/Telefon, Ablageort, Qualität, Tempo, Kapitel-Dateien). Alles wird sofort
// gespeichert. UserDefaults-Schlüssel (für andere Teile der App, z. B. den Modellspeicher):
//   helperName, helperPhone      Text
//   outputDirectory              Pfad, fehlt = Musik › Vorgelesen
//   modelBits                    Int 4 (Standard, „Schneller“) oder 8 („Etwas genauer“); liest auch SetupState
//   defaultTempo                 "slower" | "normal" | "faster" (Tempo-Standard für neue Hörbücher)
//   chaptersAsFiles              Bool, Standard true: Kapitel zusätzlich als einzelne Dateien
//   chunkWords                   Int, 0 = Standard: höchstens so viele Wörter je Abschnitt
//   fixedSeed                    Int, 0 = kein fester Seed (aus der Projekt-ID abgeleitet)
import Foundation
import Observation
import Projects

@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var helperName: String { didSet { defaults.set(helperName, forKey: "helperName") } }
    var helperPhone: String { didSet { defaults.set(helperPhone, forKey: "helperPhone") } }
    /// nil = Standard (Musik › Vorgelesen)
    var outputDirectory: URL? {
        didSet { defaults.set(outputDirectory?.path, forKey: "outputDirectory") }
    }

    /// Schneller (4-bit, empfohlen) oder etwas genauer (8-bit). Die Wahl wirkt beim nächsten Laden der Sprachausgabe;
    /// der Modellspeicher bzw. die Engine liest `quality.bits`.
    var quality: ModelQuality { didSet { defaults.set(quality.bits, forKey: Self.qualityKey) } }
    var defaultTempo: Tempo { didSet { defaults.set(defaultTempo.rawValue, forKey: Self.tempoKey) } }
    var chaptersAsFiles: Bool { didSet { defaults.set(chaptersAsFiles, forKey: Self.chaptersKey) } }
    /// 0 = Standard (200–500 Zeichen je Abschnitt).
    var chunkWords: Int { didSet { defaults.set(chunkWords, forKey: "chunkWords") } }
    /// 0 = kein fester Seed.
    var fixedSeed: Int { didSet { defaults.set(fixedSeed, forKey: "fixedSeed") } }

    /// Gemeinsam mit dem Einrichtungsassistenten (`SetupState.bitsDefaultsKey`): Int 4 oder 8, Standard 4.
    static let qualityKey = "modelBits"
    static let tempoKey = "defaultTempo"
    static let chaptersKey = "chaptersAsFiles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        helperName = defaults.string(forKey: "helperName") ?? ""
        helperPhone = defaults.string(forKey: "helperPhone") ?? ""
        quality = defaults.integer(forKey: Self.qualityKey) == 8 ? .accurate : .fast
        defaultTempo = defaults.string(forKey: Self.tempoKey).flatMap(Tempo.init(rawValue:)) ?? .normal
        chaptersAsFiles = defaults.object(forKey: Self.chaptersKey) as? Bool ?? true
        chunkWords = defaults.integer(forKey: "chunkWords")
        fixedSeed = defaults.integer(forKey: "fixedSeed")
        outputDirectory = defaults.string(forKey: "outputDirectory").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    var effectiveOutputDirectory: URL { outputDirectory ?? ProjectStore.defaultOutputDirectory }
    var usesDefaultOutputDirectory: Bool {
        outputDirectory == nil || outputDirectory?.standardizedFileURL == ProjectStore.defaultOutputDirectory.standardizedFileURL
    }
    var hasHelper: Bool {
        !helperName.trimmingCharacters(in: .whitespaces).isEmpty || !helperPhone.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// Genauigkeit der Sprachausgabe. Messwerte (Spike S1, docs/spikes/S1-engine.md): 8-bit ist ca. 12 % langsamer
/// und braucht ca. 0,4 GB mehr Speicher als 4-bit.
enum ModelQuality: String, CaseIterable, Identifiable {
    case fast, accurate
    var id: String { rawValue }
    var titleKey: String { "helper.quality.\(rawValue)" }
    /// Quantisierung in Bit.
    var bits: Int { self == .fast ? 4 : 8 }
}
