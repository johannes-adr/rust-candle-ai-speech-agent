// Reiter „Modell“ der Helfer-Einstellungen: je Rolle (Vorlesen/Klonen, Stimme beschreiben) ein Modell wählen,
// prüfen und laden. Geladen wird nur auf Knopfdruck. Umgeschaltet wird erst, wenn alles vollständig und
// geprüft im Modellordner liegt; danach wird die Sprachausgabe entladen, das neue Modell lädt beim nächsten Vorlesen.
import Foundation
import ModelSetup
import SwiftUI
import VorleserSpeech

/// Ablauf „Prüfen und laden“ für eine Rolle. Eine Ladung zur Zeit.
@MainActor
@Observable
final class ModelChoiceModel {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(InstallProgress)
        case done
        case resetDone
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    /// Rolle, zu der `phase` gehört (`base` oder `voiceDesign`).
    private(set) var role: String?
    private(set) var sizeBytes: Int64?
    private(set) var freeBytes: Int64?
    private var task: Task<Void, Never>?
    private let store: ModelStore

    init(store: ModelStore = .standard) {
        self.store = store
    }

    var isBusy: Bool { task != nil }

    /// Prüft Repo und Dateiliste, lädt das Modell und stellt danach um.
    func choose(role: String, repo: String) {
        guard task == nil else { return }
        self.role = role
        phase = .checking
        sizeBytes = nil
        freeBytes = nil
        let store = self.store
        task = Task {
            do {
                let manifest = try await ModelChooser.prepare(repo: repo, role: role)
                self.sizeBytes = manifest.totalBytes
                self.freeBytes = SpaceCheck.freeBytes(at: store.root)
                for try await event in ModelInstaller(store: store).install([manifest]) {
                    if case let .progress(p) = event { self.phase = .downloading(p) }
                }
                try ModelSelection.choose(role: role, manifest: manifest, store: store)
                await SharedSpeechEngine.shared.unload()
                SetupState.shared.refresh()
                self.phase = .done
            } catch is CancellationError {
                self.phase = .idle
            } catch {
                self.phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self.task = nil
        }
    }

    /// Bricht eine laufende Ladung ab. Was schon da ist, bleibt für den nächsten Versuch erhalten.
    func cancel() {
        task?.cancel()
    }

    /// Wieder der eingebaute Standard für die Rolle.
    func resetToDefault(role: String) {
        guard task == nil else { return }
        self.role = role
        do {
            try ModelSelection.resetToDefault(role: role, store: store)
            phase = .resetDone
            Task {
                await SharedSpeechEngine.shared.unload()
                SetupState.shared.refresh()
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

struct ModelTab: View {
    @Environment(AppModel.self) private var model
    @State private var choice = ModelChoiceModel()

    var body: some View {
        Form {
            Section {
                Text("helper.model.intro").foregroundStyle(.secondary)
            }
            ModelRoleSection(role: .base, bits: model.settings.quality.bits, choice: choice)
            ModelRoleSection(role: .voiceDesign, bits: model.settings.quality.bits, choice: choice)
            Section {
                Text("helper.model.qualityNote").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelRoleSection: View {
    let role: ModelKind
    /// Qualität (4/8 Bit) gilt nur für den eingebauten Standard.
    let bits: Int
    let choice: ModelChoiceModel

    @State private var repo = ""
    /// Vorschlag aus der Liste; leer = eigenes Repo.
    @State private var picked = ""

    private var suggestions: [ModelSuggestion] { ModelSuggestions.forRole(role.rawValue) }
    private var current: CurrentModel? { ModelSelection.current(role: role.rawValue, bits: bits) }
    private var titleKey: String {
        role == .base ? "helper.model.role.base" : "helper.model.role.voiceDesign"
    }

    var body: some View {
        Section(LocalizedStringKey(titleKey)) {
            if let current {
                LabeledContent("helper.model.current") { Text(current.ref.repo) }
                Text(details(of: current)).foregroundStyle(.secondary)
                Text(current.isChosen ? "helper.model.chosen" : "helper.model.defaultUsed")
                    .foregroundStyle(.secondary)
            }

            Picker("helper.model.pick", selection: $picked) {
                Text("helper.model.customOption").tag("")
                ForEach(suggestions) { s in Text(s.repo).tag(s.repo) }
            }
            .onChange(of: picked) { _, new in
                if !new.isEmpty { repo = new }
            }
            .onChange(of: repo) { _, new in
                picked = suggestions.contains { $0.repo == new } ? new : ""
            }
            if let s = suggestions.first(where: { $0.repo == repo }) {
                Text("\(L("helper.model.size.\(s.size)")) · \(L("helper.model.bits.\(s.precision)"))")
                    .foregroundStyle(.secondary)
            }

            TextField("helper.model.repoLabel", text: $repo)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("helper.model.load") { choice.choose(role: role.rawValue, repo: repo) }
                    .disabled(choice.isBusy || repo.trimmingCharacters(in: .whitespaces).isEmpty)
                if choice.isBusy, choice.role == role.rawValue {
                    Button("helper.model.cancel") { choice.cancel() }
                }
                if current?.isChosen == true {
                    Button("helper.model.reset") { choice.resetToDefault(role: role.rawValue) }
                        .disabled(choice.isBusy)
                }
            }

            progressView
        }
        .onAppear {
            if let current, current.isChosen { repo = current.ref.repo }
        }
    }

    @ViewBuilder private var progressView: some View {
        if choice.role == role.rawValue {
            switch choice.phase {
            case .idle:
                EmptyView()
            case .checking:
                HStack { ProgressView().controlSize(.small); Text("helper.model.checking") }
            case let .downloading(p):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: p.fraction)
                    Text(L("helper.model.progress", p.percent))
                    if let size = choice.sizeBytes, let free = choice.freeBytes {
                        Text(L("helper.model.info", bytes(size), bytes(free))).foregroundStyle(.secondary)
                    }
                }
            case .done:
                Label("helper.model.done", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .resetDone:
                Label("helper.model.resetDone", systemImage: "checkmark.circle").foregroundStyle(.green)
            case let .failed(message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private func details(of current: CurrentModel) -> String {
        let status: String
        switch ModelStore.standard.manifest(for: current.ref).map({ ModelStore.standard.status(of: $0) }) ?? .missing {
        case .ready: status = L("setup.settings.ready")
        case .missing: status = L("setup.settings.missing")
        case .partial: status = L("setup.settings.partial")
        case .corrupt: status = L("setup.settings.corrupt")
        }
        let size = current.manifest.map { bytes($0.totalBytes) } ?? "–"
        return L("helper.model.details", String(current.ref.revision.prefix(8)), size, status)
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}
