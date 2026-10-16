// Rahmen der Oberfläche: Kopfzeile mit Hilfe-Knopf, aktueller Bildschirm, große Dialoge.
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    private let setup = SetupState.shared

    var body: some View {
        // Einrichtung (App/Setup): der Assistent für den Helfer ersetzt das ganze Fenster.
        if setup.showAssistant { SetupAssistantView() } else { content }
    }

    private var content: some View {
        ZStack {
            Color.omaBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                HeaderBar()
                screen
                    .frame(maxWidth: OmaStyle.contentWidth, maxHeight: .infinity)
            }
            if model.showHelp { HelpOverlay() }
            if model.confirmStop { StopOverlay() }
        }
        .frame(minWidth: 960, minHeight: 760)
        .font(OmaStyle.bodyFont)
        .foregroundStyle(Color.omaText)
    }

    @ViewBuilder private var screen: some View {
        if setup.needsSetup { NotSetUpView() } else { mainScreen }
    }

    @ViewBuilder private var mainScreen: some View {
        switch model.screen {
        case .start: StartView()
        case .typeText: TypeTextView()
        case .importing: ImportingView()
        case .voice: VoiceView()
        case .comingSoon: ComingSoonView()
        case .describeVoice: DescribeVoiceView()
        case .ownVoice: if let flow = model.ownVoice { OwnVoiceView(flow: flow) }
        case .working: WorkingView()
        case .done: DoneView()
        case .problem(let key): ProblemView(messageKey: key)
        }
    }
}

struct HeaderBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            if model.isPreview {
                // Attrappe klar kennzeichnen (siehe PreviewAudiobookService).
                Text("preview.banner")
                    .font(OmaStyle.bodyBold)
                    .foregroundStyle(Color.omaSecondaryLabel)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.omaSecondaryFill)
            }
            HStack {
                Text("app.name")
                    .font(OmaStyle.headingFont)
                Spacer()
                OmaButton(title: "help.button", systemImage: "questionmark.circle") { model.showHelp = true }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 16)
        }
    }
}

/// Gemeinsamer Aufbau: scrollbarer Inhalt, Fußleiste mit Zurück/Weiter bleibt sichtbar.
struct ScreenScaffold<Content: View, Footer: View>: View {
    var step: Int?
    var title: LocalizedStringKey
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: OmaStyle.spacing) {
                    if let step {
                        Text(L("step.format", step)).font(OmaStyle.bodyBold).foregroundStyle(Color.omaSecondaryText)
                    }
                    Text(title).font(OmaStyle.headingFont).fixedSize(horizontal: false, vertical: true)
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 40)
                .padding(.bottom, 24)
            }
            Divider()
            footer
                .padding(.horizontal, 40)
                .padding(.vertical, 18)
        }
    }
}

extension ScreenScaffold where Footer == EmptyView {
    init(step: Int? = nil, title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.init(step: step, title: title, content: content, footer: { EmptyView() })
    }
}

// MARK: Große Dialoge (statt kleiner Systemfenster)

struct OverlayCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: OmaStyle.spacing) { content }
                .padding(36)
                .frame(maxWidth: 680)
                .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 3))
                .padding(40)
        }
    }
}

struct HelpOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OverlayCard {
            Text("help.title").font(OmaStyle.headingFont)
            if model.settings.hasHelper {
                Text("help.call")
                VStack(alignment: .leading, spacing: 8) {
                    if !model.settings.helperName.isEmpty {
                        Text(model.settings.helperName).font(OmaStyle.titleFont)
                    }
                    if !model.settings.helperPhone.isEmpty {
                        Label(model.settings.helperPhone, systemImage: "phone.fill").font(OmaStyle.titleFont)
                    }
                }
            } else {
                Text("help.none")
            }
            OmaButton(title: "common.close", systemImage: "xmark.circle", kind: .primary) { model.showHelp = false }
        }
    }
}

struct StopOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        OverlayCard {
            Text("stop.title").font(OmaStyle.headingFont)
            Text("stop.text")
            HStack(spacing: 20) {
                OmaButton(title: "stop.no", systemImage: "arrow.uturn.backward", kind: .primary) {
                    model.confirmStop = false
                }
                OmaButton(title: "stop.yes", systemImage: "pause.circle") {
                    Task { await model.stopWork() }
                }
            }
        }
    }
}
