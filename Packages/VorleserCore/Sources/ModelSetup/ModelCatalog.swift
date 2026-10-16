import Foundation

/// Welche Modelle die App benutzt. Steht in `Manifests/models.json`, Schlüssel `<art>-<bits>bit`
/// (z. B. `base-4bit`, `voiceDesign-4bit`). Ändern: `vorleser-cli models use …` (schreibt
/// models.json und das passende Manifest), dann neu bauen.
public enum ModelCatalog {
    public static func key(kind: String, bits: Int) -> String { "\(kind)-\(bits)bit" }

    /// Alle Einträge aus der mitgelieferten models.json.
    public static var bundled: [String: ModelRef] {
        guard let url = Bundle.module.url(forResource: "models", withExtension: "json", subdirectory: "Manifests"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([String: ModelRef].self, from: data)
        else { return [:] }
        return entries
    }

    public static func ref(kind: String, bits: Int) -> ModelRef? { bundled[key(kind: kind, bits: bits)] }
}
