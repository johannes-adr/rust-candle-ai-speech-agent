// Einstellungen für den Helfer (Name/Telefon, Ablageort). Alles wird sofort gespeichert.
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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        helperName = defaults.string(forKey: "helperName") ?? ""
        helperPhone = defaults.string(forKey: "helperPhone") ?? ""
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
