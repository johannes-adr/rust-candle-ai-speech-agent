// Einrichtungsassistent für den Helfer. Darf etwas technischer sein als der Rest der App, hält aber
// dieselben Größen (Schrift ≥ 20 pt, Knöpfe ≥ 60 pt mit Symbol und Wort). Keine Hover-Effekte.
import ModelSetup
import SwiftUI

enum SetupFormat {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// Ersetzt beim Einrichten das ganze Fenster (Kopfzeile mit Hilfe-Knopf gehört zur Oma-Ansicht).
struct SetupAssistantView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: SetupModel
    private let state: SetupState

    init(state: SetupState = .shared) {
        self.state = state
        _model = State(initialValue: SetupModel(service: state.service, bits: state.bits, state: state))
    }

    var body: some View {
        ZStack {
            Color.omaBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack {
                    Label("setup.header", systemImage: "wrench.and.screwdriver")
                        .font(OmaStyle.bodyBold)
                        .foregroundStyle(Color.omaSecondaryText)
                    Spacer()
                }
                .padding(.horizontal, 40)
                .padding(.vertical, 16)
                screen.frame(maxWidth: OmaStyle.contentWidth, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 960, minHeight: 760)
        .font(OmaStyle.bodyFont)
        .foregroundStyle(Color.omaText)
        #if DEBUG
        .task {
            if let demo = ProcessInfo.processInfo.environment["VORLESER_DEMO"], demo.hasPrefix("setup-") {
                await model.runDemo(demo)
            }
        }
        #endif
    }

    @ViewBuilder private var screen: some View {
        switch model.step {
        case .welcome: SetupWelcomeView(model: model)
        case .plan: SetupPlanView(model: model)
        case .loading: SetupLoadingView(model: model)
        case .paused: SetupPausedView(model: model)
        case .checking: SetupCheckingView()
        case .done: SetupDoneView(model: model)
        case .helper: SetupHelperView(model: model)
        case .problem(let problem): SetupProblemView(model: model, problem: problem)
        }
    }
}

// MARK: Willkommen

struct SetupWelcomeView: View {
    var model: SetupModel
    var body: some View {
        ScreenScaffold(title: "setup.welcome.title") {
            Text("setup.welcome.text")
            Label("setup.welcome.steps", systemImage: "list.number")
                .foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack {
                OmaButton(title: "setup.later", systemImage: "xmark.circle") { model.leave() }
                Spacer()
                OmaButton(title: "setup.next", systemImage: "arrow.right.circle", kind: .primary) { model.next() }
            }
        }
    }
}

// MARK: Was wird geladen?

struct SetupPlanView: View {
    @Bindable var model: SetupModel

    var body: some View {
        ScreenScaffold(title: "setup.plan.title") {
            if model.manifestsMissing {
                Label("setup.manifestMissing", systemImage: "exclamationmark.triangle")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("setup.plan.base", systemImage: "waveform").font(OmaStyle.bodyBold)
                    Text(L("setup.plan.size", SetupFormat.bytes(model.baseBytes)))
                    Text(model.bits == .four ? "setup.plan.qualityFour" : "setup.plan.qualityEight")
                        .foregroundStyle(Color.omaSecondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .omaCard()

                Button { model.includeVoiceDesign.toggle() } label: {
                    HStack(alignment: .top, spacing: 16) {
                        Image(systemName: model.includeVoiceDesign ? "checkmark.square.fill" : "square")
                            .font(.system(size: 34))
                        VStack(alignment: .leading, spacing: 6) {
                            Text("setup.plan.design").font(OmaStyle.bodyBold)
                            Text(L("setup.plan.size", SetupFormat.bytes(model.designBytes)))
                                .foregroundStyle(Color.omaSecondaryText)
                        }
                        Spacer()
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius)
                        .stroke(Color.omaBorder, lineWidth: model.includeVoiceDesign ? 5 : 1.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.includeVoiceDesign ? .isSelected : [])

                if let plan = model.plan { facts(plan) }
            }
        } footer: {
            HStack {
                OmaButton(title: "setup.back", systemImage: "arrow.left.circle") { model.back() }
                Spacer()
                OmaButton(title: startTitle, systemImage: "arrow.down.circle", kind: .primary) { model.next() }
                    .disabled(model.manifestsMissing || !(model.plan?.space.isEnough ?? false))
            }
        }
    }

    private var startTitle: LocalizedStringKey {
        (model.plan?.isComplete ?? false) ? "setup.plan.check" : "setup.plan.start"
    }

    @ViewBuilder private func facts(_ plan: InstallPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L("setup.plan.total", SetupFormat.bytes(plan.totalBytes)), systemImage: "shippingbox")
            Label(L("setup.plan.free", SetupFormat.bytes(plan.space.available)), systemImage: "internaldrive")
            if plan.isComplete {
                Label("setup.plan.allThere", systemImage: "checkmark.circle")
            } else {
                if plan.importBytes > 0 {
                    Label(L("setup.plan.fromMac", SetupFormat.bytes(plan.importBytes)), systemImage: "arrow.triangle.2.circlepath")
                }
                if let minutes = model.estimatedDownloadMinutes {
                    Label(L("setup.plan.time", SetupFormat.bytes(plan.downloadBytes), minutes), systemImage: "clock")
                }
            }
            if !plan.space.isEnough {
                Label(L("setup.plan.noSpace", SetupFormat.bytes(plan.space.shortfall)), systemImage: "exclamationmark.triangle.fill")
                    .font(OmaStyle.bodyBold)
            }
        }
    }
}

// MARK: Laden

struct SetupLoadingView: View {
    var model: SetupModel

    var body: some View {
        ScreenScaffold(title: "setup.loading.title") {
            let p = model.progress
            OmaProgressBar(fraction: p?.fraction ?? 0)
            if let p {
                Text(L("setup.loading.percent", p.percent, SetupFormat.bytes(p.bytesDone), SetupFormat.bytes(p.bytesTotal)))
                    .font(OmaStyle.bodyBold)
                Text(remaining(p))
                Label(phase(p.phase), systemImage: "info.circle").foregroundStyle(Color.omaSecondaryText)
            } else {
                Text("setup.loading.preparing").font(OmaStyle.bodyBold)
            }
            Label("setup.loading.hint", systemImage: "wifi").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack {
                OmaButton(title: "setup.pause", systemImage: "pause.circle") { model.pause() }
                Spacer()
            }
        }
    }

    private func remaining(_ p: InstallProgress) -> String {
        guard p.phase == .downloading, let s = p.remainingSeconds else { return "" }
        let minutes = Int((s / 60).rounded(.up))
        return minutes < 1 ? L("setup.loading.remainingShort") : L("setup.loading.remaining", minutes)
    }

    private func phase(_ phase: InstallProgress.Phase) -> String {
        switch phase {
        case .checking: L("setup.loading.phaseCheck")
        case .importing: L("setup.loading.phaseImport")
        case .downloading: L("setup.loading.phaseDownload")
        case .verifying, .finishing: L("setup.loading.phaseVerify")
        }
    }
}

struct SetupPausedView: View {
    var model: SetupModel
    var body: some View {
        ScreenScaffold(title: "setup.paused.title") {
            Text("setup.paused.text")
            if let p = model.progress {
                OmaProgressBar(fraction: p.fraction)
                Text(L("setup.loading.percent", p.percent, SetupFormat.bytes(p.bytesDone), SetupFormat.bytes(p.bytesTotal)))
            }
        } footer: {
            HStack {
                OmaButton(title: "setup.back", systemImage: "arrow.left.circle") { model.back() }
                Spacer()
                OmaButton(title: "setup.resume", systemImage: "play.circle", kind: .primary) { model.resume() }
            }
        }
    }
}

// MARK: Prüfen, fertig

struct SetupCheckingView: View {
    var body: some View {
        ScreenScaffold(title: "setup.checking.title") {
            HStack(spacing: 20) {
                ProgressView().controlSize(.large)
                Text("setup.checking.text")
            }
            .omaCard()
        }
    }
}

struct SetupDoneView: View {
    var model: SetupModel
    var body: some View {
        ScreenScaffold(title: "setup.done.title") {
            HStack(spacing: 20) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 64)).foregroundStyle(Color.omaBorder)
                Text("setup.done.text")
            }
            .omaCard()
        } footer: {
            HStack {
                Spacer()
                OmaButton(title: "setup.next", systemImage: "arrow.right.circle", kind: .primary) { model.next() }
            }
        }
    }
}

// MARK: Helfer eintragen

struct SetupHelperView: View {
    var model: SetupModel
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.settings
        ScreenScaffold(title: "setup.helper.title") {
            Text("setup.helper.text")
            VStack(alignment: .leading, spacing: 14) {
                Text("setup.helper.nameLabel").font(OmaStyle.bodyBold)
                TextField("settings.helper.name", text: $settings.helperName)
                    .textFieldStyle(.roundedBorder).font(OmaStyle.bodyFont)
                Text("setup.helper.phoneLabel").font(OmaStyle.bodyBold).padding(.top, 6)
                TextField("settings.helper.phone", text: $settings.helperPhone)
                    .textFieldStyle(.roundedBorder).font(OmaStyle.bodyFont)
            }
            .omaCard()
            Label("setup.helper.note", systemImage: "info.circle").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack {
                OmaButton(title: "setup.back", systemImage: "arrow.left.circle") { model.back() }
                Spacer()
                OmaButton(title: "setup.handover", systemImage: "checkmark.circle", kind: .primary) { model.finish() }
            }
        }
    }
}

// MARK: Fehler

struct SetupProblemView: View {
    var model: SetupModel
    var problem: SetupProblem

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(problem.titleKey)) {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: icon).font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                Text(message)
            }
            .omaCard()
            if let p = model.progress, p.bytesDone > 0 {
                Label(L("setup.problem.kept", SetupFormat.bytes(p.bytesDone)), systemImage: "externaldrive.badge.checkmark")
                    .foregroundStyle(Color.omaSecondaryText)
            }
        } footer: {
            HStack {
                OmaButton(title: "setup.back", systemImage: "arrow.left.circle") { model.back() }
                Spacer()
                OmaButton(title: "setup.problem.retry", systemImage: "arrow.clockwise", kind: .primary) { model.startLoading() }
            }
        }
    }

    private var icon: String {
        switch problem {
        case .offline: "wifi.slash"
        case .noSpace: "internaldrive"
        default: "exclamationmark.triangle"
        }
    }

    private var message: String {
        switch problem {
        case let .noSpace(missing): L(problem.messageKey, SetupFormat.bytes(missing))
        case let .server(status): L(problem.messageKey, status)
        default: L(problem.messageKey)
        }
    }
}
