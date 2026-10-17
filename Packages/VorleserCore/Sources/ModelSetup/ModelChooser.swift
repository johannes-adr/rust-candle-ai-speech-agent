import Foundation

/// Ein vorgeschlagenes Modell für die Auswahl. Die Revision steht bewusst nicht hier: sie wird beim
/// Wählen auf `main` aufgelöst und als Commit festgehalten (`ModelChooser.prepare`).
/// `size` und `precision` sind Schlüssel für kurze Hinweise in der Oberfläche.
public struct ModelSuggestion: Sendable, Equatable, Identifiable {
    public let role: String
    public let repo: String
    /// `small` (0,6 B) oder `large` (1,7 B).
    public let size: String
    /// `q4`, `q5`, `q6`, `q8` oder `bf16`.
    public let precision: String

    public var id: String { repo }
}

/// Eingebaute Liste passender Modelle (mlx-community). CustomVoice-Modelle fehlen absichtlich:
/// feste Sprecher passen nicht zum Klon-Ablauf.
public enum ModelSuggestions {
    public static func forRole(_ role: String) -> [ModelSuggestion] {
        let precisions = ["4bit": "q4", "5bit": "q5", "6bit": "q6", "8bit": "q8", "bf16": "bf16"]
        let order = ["4bit", "5bit", "6bit", "8bit", "bf16"]
        switch role {
        case ModelRoles.base:
            return order.map { ModelSuggestion(role: role, repo: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-\($0)", size: "small", precision: precisions[$0]!) }
                + order.map { ModelSuggestion(role: role, repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-Base-\($0)", size: "large", precision: precisions[$0]!) }
        case ModelRoles.voiceDesign:
            return order.map { ModelSuggestion(role: role, repo: "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-\($0)", size: "large", precision: precisions[$0]!) }
        default:
            return []
        }
    }
}

/// Gemeinsame Logik für „Modell wählen“ (App und `vorleser-cli models use`): Branch auf Commit
/// auflösen, Dateiliste holen, grob prüfen, ob es ein MLX-Qwen3-TTS-Modell für die Rolle ist.
/// Lädt nur die Dateiliste und `config.json`, keine Gewichte.
public enum ModelChooser {
    /// Hugging-Face-Adresse; in Tests durch einen Testserver ersetzt.
    public static let huggingFace = URL(string: "https://huggingface.co")!

    public enum CheckError: Error, Equatable, LocalizedError {
        case notFound(repo: String, revision: String)
        case notQwen3TTS(String)
        case wrongRole(expected: String, found: String)

        public var errorDescription: String? {
            switch self {
            case let .notFound(repo, revision): "Repo oder Version nicht gefunden: \(repo) (\(revision))."
            case let .notQwen3TTS(why): "Das ist kein passendes Qwen3-TTS-Modell: \(why)"
            case let .wrongRole(expected, found): "Das Modell passt nicht zur Aufgabe (erwartet \(expected), ist \(found))."
            }
        }
    }

    /// Commit-Hash eines Branches oder Tags (Standard `main`); ein voller Hash wird unverändert zurückgegeben.
    public static func resolveCommit(repo: String, revision: String = "main",
                                     baseURL: URL = huggingFace, session: URLSession = .shared) async throws -> String {
        if revision.count == 40, revision.allSatisfy(\.isHexDigit) { return revision }
        let url = baseURL.appendingPathComponent("api/models/\(repo)/revision/\(revision)")
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String
        else { throw CheckError.notFound(repo: repo, revision: revision) }
        return sha
    }

    /// Löst die Revision auf, holt die Dateiliste und prüft sie grob für die Rolle (`base` oder `voiceDesign`).
    public static func prepare(repo: String, revision: String = "main", role: String,
                               baseURL: URL = huggingFace, session: URLSession = .shared) async throws -> ModelManifest {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let sha = try await resolveCommit(repo: repo, revision: revision, baseURL: baseURL, session: session)
            let ref = ModelRef(repo: repo, revision: sha)
            let manifest = try await ManifestFetcher.fetch(ref: ref, baseURL: baseURL, session: session)
            let config = try await fetchSmallFile("config.json", ref: ref, baseURL: baseURL, session: session)
            try check(manifest, configData: config, role: role)
            return manifest
        } catch let error as CheckError {
            throw error
        } catch {
            throw ModelInstaller.map(error)
        }
    }

    /// Grobe Prüfung ohne Gewichte: Pflichtdateien vorhanden, `config.json` sagt `qwen3_tts`, und die
    /// Art passt zur Rolle (Base bzw. VoiceDesign). Fehlt `tts_model_type`, zählt nur `model_type`.
    public static func check(_ manifest: ModelManifest, configData: Data, role: String) throws {
        let paths = Set(manifest.files.map(\.path))
        for required in ["config.json", "tokenizer_config.json"] where !paths.contains(required) {
            throw CheckError.notQwen3TTS("\(required) fehlt")
        }
        guard paths.contains(where: { $0.hasSuffix(".safetensors") }) else {
            throw CheckError.notQwen3TTS("keine Gewichtsdatei (.safetensors)")
        }
        guard paths.contains(where: { $0.hasPrefix("speech_tokenizer/") }) else {
            throw CheckError.notQwen3TTS("kein speech_tokenizer")
        }
        guard let json = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] else {
            throw CheckError.notQwen3TTS("config.json ist nicht lesbar")
        }
        guard (json["model_type"] as? String)?.lowercased() == "qwen3_tts" else {
            throw CheckError.notQwen3TTS("model_type ist nicht qwen3_tts")
        }
        if let found = json["tts_model_type"] as? String {
            let expected = role == ModelRoles.voiceDesign ? "voice_design" : "base"
            if found != expected { throw CheckError.wrongRole(expected: expected, found: found) }
        }
    }

    private static func fetchSmallFile(_ path: String, ref: ModelRef, baseURL: URL, session: URLSession) async throws -> Data {
        let url = baseURL.appendingPathComponent(ref.repo).appendingPathComponent("resolve")
            .appendingPathComponent(ref.revision).appendingPathComponent(path)
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CheckError.notQwen3TTS("\(path) nicht abrufbar")
        }
        return data
    }
}

/// Rollen-Namen, wie sie in `ModelCatalog` und `ModelSelection` stehen.
enum ModelRoles {
    static let base = "base"
    static let voiceDesign = "voiceDesign"
}
