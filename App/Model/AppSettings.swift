// Einstellungen für den Helfer (Name/Telefon, Ablageort, Qualität, Tempo, Kapitel-Dateien). Alles wird sofort
// gespeichert. UserDefaults-Schlüssel (für andere Teile der App, z. B. den Modellspeicher):
//   helperName, helperPhone      Text
//   outputDirectory              Pfad, fehlt = Musik › Vorgelesen
//   modelQuality                 "fast" (4-bit, Standard) oder "accurate" (8-bit); lesen: AppSettings.quality
//   defaultTempo                 "slower" | "normal" | "faster" (Tempo-Standard für neue Hörbücher)
//   chaptersAsFiles              Bool, Standard true: Kapitel zusätzlich als einzelne Dateien
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
    var quality: ModelQuality { didSet { defaults.set(quality.rawValue, forKey: Self.qualityKey) } }
    var defaultTempo: Tempo { didSet { defaults.set(defaultTempo.rawValue, forKey: Self.tempoKey) } }
    var chaptersAsFiles: Bool { didSet { defaults.set(chaptersAsFiles, forKey: Self.chaptersKey) } }

    static let qualityKey = "modelQuality"
    static let tempoKey = "defaultTempo"
    static let chaptersKey = "chaptersAsFiles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        helperName = defaults.string(forKey: "helperName") ?? ""
        helperPhone = defaults.string(forKey: "helperPhone") ?? ""
        quality = defaults.string(forKey: Self.qualityKey).flatMap(ModelQuality.init(rawValue:)) ?? .fast
        defaultTempo = defaults.string(forKey: Self.tempoKey).flatMap(Tempo.init(rawValue:)) ?? .normal
        chaptersAsFiles = defaults.object(forKey: Self.chaptersKey) as? Bool ?? true
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
