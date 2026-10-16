// Ablauf des Einrichtungsassistenten für den Helfer:
// Willkommen → Was wird geladen → Laden (Pause/Fortsetzen) → Prüfen → Fertig → Helfer eintragen.
// Nur Bedienlogik; die Arbeit macht `ModelSetup` über `SetupServicing`.
import Foundation
import ModelSetup
import Observation
import VorleserSpeech

enum SetupStep: Equatable {
    case welcome
    case plan
    case loading
    case paused
    case checking
    case done
    case helper
    case problem(SetupProblem)
}

/// Was schiefgehen kann, in Worten für den Helfer.
enum SetupProblem: Equatable {
    case offline
    /// Fehlender Platz in Bytes (inkl. Puffer)
    case noSpace(missing: Int64)
    case server(status: Int)
    case damaged
    case other(String)

    var titleKey: String {
        switch self {
        case .offline: "setup.problem.offline.title"
        case .noSpace: "setup.problem.space.title"
        case .server, .other: "setup.problem.other.title"
        case .damaged: "setup.problem.damaged.title"
        }
    }

    var messageKey: String {
        switch self {
        case .offline: "setup.problem.offline.text"
        case .noSpace: "setup.problem.space.text"
        case .server: "setup.problem.server.text"
        case .damaged: "setup.problem.damaged.text"
        case .other: "setup.problem.other.text"
        }
    }
}

@MainActor
@Observable
final class SetupModel {
    private(set) var step: SetupStep = .welcome
    /// „Eigener Wunsch …“ und „Stimme erzeugen“ brauchen ein zweites Paket (VoiceDesign).
    var includeVoiceDesign = true { didSet { if oldValue != includeVoiceDesign { recomputePlan() } } }
    private(set) var plan: InstallPlan?
    private(set) var progress: InstallProgress?
    /// Pakete fehlen (keine Dateiliste mitgeliefert): Programmfehler, nicht Sache des Helfers.
    private(set) var manifestsMissing = false

    let bits: ModelBits
    private let service: any SetupServicing
    private let state: SetupState?
    private var task: Task<Void, Never>?

    init(service: any SetupServicing, bits: ModelBits = .four, state: SetupState? = nil) {
        self.service = service
        self.bits = bits
        self.state = state
        recomputePlan()
    }

    // MARK: Abgeleitetes

    var manifests: [ModelManifest] { service.manifests(bits: bits, includeVoiceDesign: includeVoiceDesign) ?? [] }
    var baseBytes: Int64 { service.manifests(bits: bits, includeVoiceDesign: false)?.first?.totalBytes ?? 0 }
    var designBytes: Int64 { service.manifests(bits: .four, includeVoiceDesign: true).flatMap { $0.count > 1 ? $0[1].totalBytes : nil } ?? 0 }
    var isLoading: Bool { step == .loading }

    /// Grobe Dauer bei 50 MBit/s (6,25 MB/s), in Minuten (mindestens 1). `nil`, wenn nichts zu laden ist.
    var estimatedDownloadMinutes: Int? {
        guard let plan, plan.downloadBytes > 0 else { return nil }
        return max(1, Int((Double(plan.downloadBytes) / 6_250_000 / 60).rounded(.up)))
    }

    // MARK: Schritte

    func recomputePlan() {
        let m = manifests
        manifestsMissing = m.isEmpty
        plan = m.isEmpty ? nil : service.plan(m)
    }

    func next() {
        switch step {
        case .welcome:
            recomputePlan()
            step = .plan
        case .plan: startLoading()
        case .done: step = .helper
        default: break
        }
    }

    func back() {
        switch step {
        case .plan: step = .welcome
        case .paused, .problem: task?.cancel(); recomputePlan(); step = .plan
        case .helper: step = .done
        default: break
        }
    }

    func startLoading() {
        guard !manifestsMissing, step != .loading else { return }
        step = .loading
        progress = nil
        let wanted = manifests
        task?.cancel()
        task = Task { [service] in
            do {
                for try await event in service.install(wanted) {
                    if case let .progress(p) = event { self.progress = p }
                }
                try Task.checkCancellation()
                await self.verifyAll(wanted)
            } catch is CancellationError {
                // Pause: Teildateien bleiben liegen, „Fortsetzen“ macht weiter.
            } catch let e as InstallError {
                self.fail(Self.problem(for: e))
            } catch {
                self.fail(.other(error.localizedDescription))
            }
        }
    }

    /// „Anhalten“: bricht ab, behält Geladenes.
    func pause() {
        guard step == .loading else { return }
        task?.cancel()
        step = .paused
    }

    func resume() { startLoading() }

    private func verifyAll(_ wanted: [ModelManifest]) async {
        step = .checking
        do {
            if try await service.verify(wanted) {
                state?.refresh()
                step = .done
            } else {
                fail(.damaged)
            }
        } catch {
            fail(.other(error.localizedDescription))
        }
    }

    private func fail(_ problem: SetupProblem) {
        guard step != .paused else { return }
        step = .problem(problem)
        recomputePlan()
    }

    /// Letzter Schritt: zurück zur App. Name und Telefon sind schon gespeichert (sofort beim Tippen).
    func finish() {
        task?.cancel()
        state?.refresh()
        state?.showAssistant = false
    }

    /// Schließt den Assistenten ohne Einrichtung (z. B. „Später“).
    func leave() {
        task?.cancel()
        state?.refresh()
        state?.showAssistant = false
    }

    static func problem(for error: InstallError) -> SetupProblem {
        switch error {
        case let .notEnoughSpace(needed, available): .noSpace(missing: max(0, needed - available))
        case .offline: .offline
        case let .server(status): .server(status: status)
        case .checksumMismatch: .damaged
        case let .io(text): .other(text)
        }
    }
}
