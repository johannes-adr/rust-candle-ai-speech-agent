// Nur Debug: Dienst ohne Netz und ohne Gigabytes für Bildschirmfotos der Einrichtung.
// VORLESER_DEMO=setup-welcome|setup-plan|setup-loading|setup-problem|setup-space|setup-checking|setup-done|setup-helper|notsetup
#if DEBUG
import Foundation
import ModelSetup
import VorleserSpeech

struct DemoSetupService: SetupServicing {
    let demo: String

    private static let base = ModelManifest(
        repo: "demo/base", revision: String(repeating: "a", count: 40),
        files: [.init(path: "weights", size: 2_340_000_000, sha256: String(repeating: "0", count: 64))])
    private static let design = ModelManifest(
        repo: "demo/design", revision: String(repeating: "b", count: 40),
        files: [.init(path: "weights", size: 2_310_000_000, sha256: String(repeating: "0", count: 64))])

    func manifests(bits: ModelBits, includeVoiceDesign: Bool) -> [ModelManifest]? {
        includeVoiceDesign ? [Self.base, Self.design] : [Self.base]
    }

    func status(of manifest: ModelManifest) -> ModelStatus { .missing }

    func plan(_ manifests: [ModelManifest]) -> InstallPlan {
        let total = manifests.reduce(0) { $0 + $1.totalBytes }
        let free: Int64 = demo == "setup-space" ? 1_200_000_000 : 48_300_000_000
        return InstallPlan(totalBytes: total, presentBytes: 0, importBytes: 0, downloadBytes: total,
                           space: SpaceCheck(needed: total, available: free))
    }

    func install(_ manifests: [ModelManifest]) -> AsyncThrowingStream<InstallEvent, Error> {
        let total = manifests.reduce(0) { $0 + $1.totalBytes }
        let demo = demo
        return AsyncThrowingStream { continuation in
            let task = Task {
                func progress(_ fraction: Double) -> InstallEvent {
                    .progress(InstallProgress(
                        phase: .downloading, bytesDone: Int64(Double(total) * fraction), bytesTotal: total,
                        bytesPerSecond: 7_400_000, remainingSeconds: 11 * 60 * (1 - fraction),
                        currentFile: "weights", currentModel: manifests.first?.ref))
                }
                switch demo {
                case "setup-loading":
                    continuation.yield(progress(0.37))
                    try? await Task.sleep(for: .seconds(3600))
                case "setup-problem":
                    continuation.yield(progress(0.52))
                    continuation.finish(throwing: InstallError.offline)
                case "setup-space":
                    continuation.finish(throwing: InstallError.notEnoughSpace(needed: total + 1_100_000_000, available: 1_200_000_000))
                default:
                    continuation.yield(progress(1))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func verify(_ manifests: [ModelManifest]) async throws -> Bool {
        if demo == "setup-checking" { try await Task.sleep(for: .seconds(3600)) }
        return true
    }
}

extension SetupModel {
    /// Fährt den Assistenten bis zum Bildschirm des Demos.
    func runDemo(_ demo: String) async {
        func wait(_ condition: () -> Bool) async {
            for _ in 0..<100 {
                if condition() { return }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        guard demo != "setup-welcome" else { return }
        next() // Was wird geladen
        if demo == "setup-plan" { return }
        next() // Laden
        switch demo {
        case "setup-done", "setup-helper":
            await wait { step == .done }
            if demo == "setup-helper" { next() }
        case "setup-checking":
            await wait { step == .checking }
        default:
            try? await Task.sleep(for: .milliseconds(300))
        }
    }
}
#endif
