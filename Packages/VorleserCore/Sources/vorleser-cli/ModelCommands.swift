// Phase 5: Modellordner verwalten.
//   vorleser-cli models status                 Zustand der gepinnten Modelle
//   vorleser-cli models install [--bits 4] [--voice-design] [--no-cache-import]
//   vorleser-cli models verify                 volle SHA-256-Prüfung
//   vorleser-cli models manifest <repo> <rev>  Manifest aus der HF-API erzeugen (Entwickler)
import ArgumentParser
import Foundation
import ModelSetup
import VorleserSpeech

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "models",
        abstract: "Modellordner (Application Support/Vorleser/Models) prüfen, einrichten, Manifeste erzeugen.",
        subcommands: [ModelsStatus.self, ModelsInstall.self, ModelsVerify.self, ModelsManifest.self])
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
        for (kind, bits) in [(ModelKind.base, ModelBits.four), (.base, .eight), (.voiceDesign, .four)] {
            guard let spec = ModelSpec.pinned(kind, bits: bits), let m = ModelManifest.bundled(for: spec) else { continue }
            print("  \(kind) \(bits.rawValue)-bit  \(gb(m.totalBytes))  \(store.status(of: m))")
        }
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
        for (kind, bits) in [(ModelKind.base, ModelBits.four), (.base, .eight), (.voiceDesign, .four)] {
            guard let spec = ModelSpec.pinned(kind, bits: bits), let m = ModelManifest.bundled(for: spec) else { continue }
            guard store.status(of: m) == .ready else { print("\(kind) \(bits.rawValue)-bit: \(store.status(of: m))"); continue }
            let started = Date()
            let result = try store.verify(m)
            print("\(kind) \(bits.rawValue)-bit: \(result) (\(String(format: "%.1f", Date().timeIntervalSince(started))) s)")
        }
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
