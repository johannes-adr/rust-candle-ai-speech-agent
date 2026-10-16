// Phase 5: Modellordner verwalten.
//   vorleser-cli models status                 Zustand der gepinnten Modelle
//   vorleser-cli models install [--bits 4] [--voice-design] [--no-cache-import]
//   vorleser-cli models verify                 volle SHA-256-Prüfung
//   vorleser-cli models manifest <repo> <rev>  Manifest aus der HF-API erzeugen (Entwickler)
//   vorleser-cli models use <base|voiceDesign> <repo> [--bits 4] [--revision main]
//                                              Modell wechseln: models.json + Manifest schreiben
import ArgumentParser
import Foundation
import ModelSetup
import VorleserSpeech

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Modellordner (Application Support/Vorleser/Models) prüfen, einrichten, Manifeste erzeugen.",
        subcommands: [ModelsStatus.self, ModelsInstall.self, ModelsVerify.self, ModelsManifest.self, ModelsUse.self])
}

private func wantedModels(bits: Int, voiceDesign: Bool) throws -> [ModelManifest] {
    guard let b = ModelBits(rawValue: bits) else { throw ValidationError("--bits muss 4 oder 8 sein") }
    var kinds: [ModelKind] = [.base]
    if voiceDesign { kinds.append(.voiceDesign) }
    return try kinds.map { kind in
        guard let spec = ModelSpec.pinned(kind, bits: kind == .voiceDesign ? .four : b),
              let manifest = ModelManifest.bundled(for: spec)
        else { throw CLIError("Kein Manifest für \(kind) \(b.rawValue)-bit.") }
        return manifest
    }
}

private func gb(_ bytes: Int64) -> String { String(format: "%.2f GB", Double(bytes) / 1e9) }

struct ModelsStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Zustand der gepinnten Modelle.")
    @Option(name: .customLong("models-dir"), help: "Modellordner (Standard: Application Support/Vorleser/Models).")
    var modelsDir: String?

    func run() async throws {
        let store = modelsDir.map { ModelStore(root: URL(fileURLWithPath: $0)) } ?? .standard
        print("Modellordner: \(store.root.path)")
        for kind in ModelKind.allCases { for bits in ModelBits.allCases {
            guard let spec = ModelSpec.pinned(kind, bits: bits), let m = ModelManifest.bundled(for: spec) else { continue }
            print("  \(kind) \(bits.rawValue)-bit  \(m.ref.repo)@\(m.ref.revision.prefix(8))  \(gb(m.totalBytes))  \(store.status(of: m))")
        } }
    }
}

struct ModelsInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install", abstract: "Modelle in den Modellordner bringen (HF-Cache, sonst Download).")
    @Option(help: "Quantisierung des Hauptmodells: 4 oder 8.") var bits = 4
    @Flag(name: .customLong("voice-design"), help: "Auch das Modell für „Stimme beschreiben“.") var voiceDesign = false
    @Flag(name: .customLong("no-cache-import"), help: "Den Hugging-Face-Cache nicht benutzen.") var noCacheImport = false
    @Option(name: .customLong("cache-dir"), help: "Hugging-Face-Cache (Standard: ~/.cache/huggingface/hub).") var cacheDir: String?
    @Option(name: .customLong("models-dir"), help: "Modellordner.") var modelsDir: String?
    @Flag(help: "Vorhandene Dateien neu mit SHA-256 prüfen.") var repair = false

    func run() async throws {
        let manifests = try wantedModels(bits: bits, voiceDesign: voiceDesign)
        let store = modelsDir.map { ModelStore(root: URL(fileURLWithPath: $0)) } ?? .standard
        let cache: HFCacheImporter? = noCacheImport ? nil : HFCacheImporter(
            cacheRoot: cacheDir.map { URL(fileURLWithPath: $0) } ?? ModelRef.defaultHuggingFaceCacheRoot)
        let installer = ModelInstaller(store: store, cache: cache)
        let plan = installer.plan(manifests)
        print("Gesamt \(gb(plan.totalBytes)), vorhanden \(gb(plan.presentBytes)), aus HF-Cache \(gb(plan.importBytes)), Download \(gb(plan.downloadBytes))")
        print("Platz: neu nötig \(gb(plan.space.needed)) + Puffer \(gb(plan.space.buffer)), frei \(gb(plan.space.available))")
        var lastPercent = -1
        for try await event in installer.install(manifests, repair: repair) {
            switch event {
            case let .progress(p):
                if p.percent != lastPercent {
                    lastPercent = p.percent
                    let eta = p.remainingSeconds.map { " Rest \(Int($0)) s" } ?? ""
                    FileHandle.standardError.write(Data("\r\(p.percent) %  \(p.phase)  \(p.currentFile ?? "")\(eta)        ".utf8))
                }
            case let .modelReady(ref):
                FileHandle.standardError.write(Data("\n".utf8))
                print("Bereit: \(ref.repo)@\(ref.revision.prefix(8))")
            }
        }
    }
}

struct ModelsVerify: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Volle SHA-256-Prüfung der fertigen Modelle.")
    @Option(name: .customLong("models-dir"), help: "Modellordner.") var modelsDir: String?

    func run() async throws {
        let store = modelsDir.map { ModelStore(root: URL(fileURLWithPath: $0)) } ?? .standard
        for kind in ModelKind.allCases { for bits in ModelBits.allCases {
            guard let spec = ModelSpec.pinned(kind, bits: bits), let m = ModelManifest.bundled(for: spec) else { continue }
            guard store.status(of: m) == .ready else { print("\(kind) \(bits.rawValue)-bit: \(store.status(of: m))"); continue }
            let started = Date()
            let result = try store.verify(m)
            print("\(kind) \(bits.rawValue)-bit: \(result) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        } }
    }
}

struct ModelsManifest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "manifest", abstract: "Manifest (Dateien, Größen, SHA-256) aus der Hugging-Face-API erzeugen.")
    @Argument var repo: String
    @Argument var revision: String
    @Option(name: [.short, .customLong("output")], help: "Zieldatei (Standard: Standardausgabe).") var output: String?

    func run() async throws {
        let manifest = try await ManifestFetcher.fetch(ref: ModelRef(repo: repo, revision: revision))
        let data = try manifest.encoded()
        if let output { try data.write(to: URL(fileURLWithPath: output)) } else { print(String(decoding: data, as: UTF8.self)) }
        FileHandle.standardError.write(Data("\(manifest.files.count) Dateien, \(gb(manifest.totalBytes))\n".utf8))
    }
}

struct ModelsUse: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "use",
        abstract: "Modell wechseln: trägt Repo + Commit in models.json ein und legt das Manifest daneben. Danach neu bauen.")
    @Argument(help: "base oder voiceDesign") var kind: String
    @Argument(help: "Hugging-Face-Repo, z. B. mlx-community/Qwen3-TTS-12Hz-1.7B-Base-6bit") var repo: String
    @Option(help: "Platz in der App: 4 oder 8 (Einstellung „Qualität“).") var bits = 4
    @Option(help: "Branch, Tag oder Commit; wird auf den vollen Commit-Hash festgelegt.") var revision = "main"

    func run() async throws {
        guard let k = ModelKind(rawValue: kind) else { throw ValidationError("Art muss base oder voiceDesign sein") }
        guard let b = ModelBits(rawValue: bits) else { throw ValidationError("--bits muss 4 oder 8 sein") }
        let sha = try await resolveCommit(repo: repo, revision: revision)
        let ref = ModelRef(repo: repo, revision: sha)
        let manifest = try await ManifestFetcher.fetch(ref: ref)

        // Quellordner der mitgelieferten Manifeste (Entwicklerwerkzeug, läuft im Repo).
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("ModelSetup/Manifests")
        try manifest.encoded().write(to: dir.appendingPathComponent(ref.manifestName + ".json"))

        let catalogURL = dir.appendingPathComponent("models.json")
        var catalog = (try? JSONDecoder().decode([String: ModelRef].self, from: Data(contentsOf: catalogURL))) ?? [:]
        let key = ModelCatalog.key(kind: k.rawValue, bits: b.rawValue)
        let old = catalog[key]
        catalog[key] = ref
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(catalog).write(to: catalogURL)

        // Altes Manifest löschen, wenn kein Eintrag es mehr braucht.
        if let old, old.manifestName != ref.manifestName, !catalog.values.contains(where: { $0.manifestName == old.manifestName }) {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(old.manifestName + ".json"))
        }
        print("\(key): \(repo)@\(sha.prefix(8)), \(manifest.files.count) Dateien, \(gb(manifest.totalBytes))")
        print("Jetzt neu bauen; danach `vorleser-cli models install --bits \(bits)\(k == .voiceDesign ? " --voice-design" : "")`.")
    }

    private func resolveCommit(repo: String, revision: String) async throws -> String {
        if revision.count == 40, revision.allSatisfy(\.isHexDigit) { return revision }
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/revision/\(revision)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sha = json["sha"] as? String
        else { throw CLIError("Repo oder Revision nicht gefunden: \(repo)@\(revision)") }
        return sha
    }
}
