// Brücke zwischen Einrichtungsassistent und Package `ModelSetup`. Als Protokoll, damit die Tests
// und die Bildschirmfotos (Debug) ohne Netz und ohne Gigabytes auskommen.
import Foundation
import ModelSetup
import VorleserSpeech

protocol SetupServicing: Sendable {
    /// Gepinnte Dateilisten. `nil`, wenn für die Auswahl keine mitgeliefert ist.
    func manifests(bits: ModelBits, includeVoiceDesign: Bool) -> [ModelManifest]?
    func status(of manifest: ModelManifest) -> ModelStatus
    func plan(_ manifests: [ModelManifest]) -> InstallPlan
    func install(_ manifests: [ModelManifest]) -> AsyncThrowingStream<InstallEvent, Error>
    /// Volle SHA-256-Prüfung aller Dateien. `true`, wenn alles stimmt.
    func verify(_ manifests: [ModelManifest]) async throws -> Bool
}

struct LiveSetupService: SetupServicing {
    var store: ModelStore = .standard
    /// Entwickler-Mac: liegt derselbe Snapshot im Hugging-Face-Cache, wird er übernommen statt geladen.
    var installer: ModelInstaller

    init(store: ModelStore = .standard, installer: ModelInstaller? = nil) {
        self.store = store
        self.installer = installer ?? ModelInstaller(store: store)
    }

    func manifests(bits: ModelBits, includeVoiceDesign: Bool) -> [ModelManifest]? {
        guard let base = ModelSpec.pinned(.base, bits: bits).flatMap(ModelManifest.bundled(for:)) else { return nil }
        var list = [base]
        if includeVoiceDesign {
            guard let design = ModelSpec.pinned(.voiceDesign, bits: .four).flatMap(ModelManifest.bundled(for:)) else { return nil }
            list.append(design)
        }
        return list
    }

    func status(of manifest: ModelManifest) -> ModelStatus { store.status(of: manifest) }
    func plan(_ manifests: [ModelManifest]) -> InstallPlan { installer.plan(manifests) }
    func install(_ manifests: [ModelManifest]) -> AsyncThrowingStream<InstallEvent, Error> { installer.install(manifests) }

    func verify(_ manifests: [ModelManifest]) async throws -> Bool {
        let store = store
        return try await Task.detached(priority: .userInitiated) {
            for m in manifests where try store.verify(m) != .ready { return false }
            return true
        }.value
    }
}
