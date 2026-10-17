// Reiter „Helfer“, „Ablage“ und „Qualität“ des Helfer-Fensters.
import AppKit
import ModelSetup
import SwiftUI
import VorleserSpeech

// MARK: Helfer

struct HelperInfoTab: View {
    @Environment(AppModel.self) private var model
    @State private var showPreview = false

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("settings.helper.header") {
                TextField("settings.helper.name", text: $settings.helperName)
                TextField("settings.helper.phone", text: $settings.helperPhone)
                Text("settings.helper.note").foregroundStyle(.secondary)
            }
            Section("helper.helper.test.header") {
                Text("helper.helper.test.info").foregroundStyle(.secondary)
                Button("helper.helper.test.button") { showPreview = true }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showPreview) {
            HelpButtonPreview(name: model.settings.helperName, phone: model.settings.helperPhone) { showPreview = false }
        }
    }
}

/// So sieht die Oma den Hilfe-Knopf: derselbe Aufbau und dieselben Größen wie `HelpOverlay`.
struct HelpButtonPreview: View {
    var name: String
    var phone: String
    var close: () -> Void

    private var hasHelper: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty || !phone.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OmaStyle.spacing) {
            Text("helper.helper.test.caption").font(.system(size: 13)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Label("help.button", systemImage: "questionmark.circle")
                    .font(OmaStyle.buttonFont)
                    .foregroundStyle(Color.omaSecondaryLabel)
                    .padding(.horizontal, 28)
                    .frame(minHeight: OmaStyle.buttonHeight)
                    .background(Color.omaSecondaryFill, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: OmaStyle.spacing) {
                Text("help.title").font(OmaStyle.headingFont)
                if hasHelper {
                    Text("help.call")
                    if !name.isEmpty { Text(name).font(OmaStyle.titleFont) }
                    if !phone.isEmpty { Label(phone, systemImage: "phone.fill").font(OmaStyle.titleFont) }
                } else {
                    Text("help.none")
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 3))
            HStack { Spacer(); Button("helper.close", action: close).keyboardShortcut(.defaultAction) }
        }
        .font(OmaStyle.bodyFont)
        .foregroundStyle(Color.omaText)
        .padding(24)
        .frame(width: 600)
        .background(Color.omaBackground)
    }
}

// MARK: Ablage

struct FolderTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("settings.output.header") {
                LabeledContent("settings.output.current") {
                    Text(model.settings.effectiveOutputDirectory.path).textSelection(.enabled)
                }
                HStack {
                    Button("settings.output.choose") { chooseFolder() }
                    Button("settings.output.reset") {
                        model.settings.outputDirectory = nil
                        model.rebuildStore()
                    }
                    .disabled(model.settings.usesDefaultOutputDirectory)
                    Button("helper.folder.show") {
                        let dir = model.settings.effectiveOutputDirectory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
            Section("helper.folder.chapters.header") {
                Toggle("helper.folder.chapters.toggle", isOn: $settings.chaptersAsFiles)
                Text("helper.folder.chapters.info").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = L("settings.output.panelMessage")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                model.settings.outputDirectory = url
                model.rebuildStore()
            }
        }
    }
}

// MARK: Qualität

struct QualityTab: View {
    @Environment(AppModel.self) private var model

    /// 8-bit gewählt, aber noch nicht eingerichtet (Hauptmodell fehlt im Modellspeicher).
    private var needsSetupFor8Bit: Bool {
        let service = SetupState.shared.service
        guard let manifest = service.manifests(bits: .eight, includeVoiceDesign: false)?.first else { return true }
        return !service.status(of: manifest).isReady
    }

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("helper.quality.header") {
                Picker("helper.quality.header", selection: $settings.quality) {
                    ForEach(ModelQuality.allCases) { q in
                        Text(LocalizedStringKey(q.titleKey)).tag(q)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text("helper.quality.info").foregroundStyle(.secondary)
                Text("helper.quality.applies").foregroundStyle(.secondary)
                if settings.quality == .accurate, needsSetupFor8Bit {
                    Label("helper.quality.needsSetup", systemImage: "arrow.down.circle")
                    Button("helper.quality.openSetup") { SetupState.shared.reopenAssistant() }
                }
            }
            Section("helper.tempo.header") {
                Picker("helper.tempo.header", selection: $settings.defaultTempo) {
                    ForEach(Tempo.allCases) { t in Text(LocalizedStringKey(t.titleKey)).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("helper.tempo.info").foregroundStyle(.secondary)
            }
            Section("helper.advanced.header") {
                Toggle("helper.advanced.words.toggle", isOn: Binding(
                    get: { settings.chunkWords > 0 }, set: { settings.chunkWords = $0 ? 120 : 0 }))
                if settings.chunkWords > 0 {
                    Stepper(value: $settings.chunkWords, in: 20...600, step: 10) {
                        LabeledContent("helper.advanced.words.label") { Text(verbatim: "\(settings.chunkWords)") }
                    }
                }
                Text("helper.advanced.words.info").foregroundStyle(.secondary)
                Toggle("helper.advanced.seed.toggle", isOn: Binding(
                    get: { settings.fixedSeed > 0 }, set: { settings.fixedSeed = $0 ? 42 : 0 }))
                if settings.fixedSeed > 0 {
                    TextField("helper.advanced.seed.label", value: $settings.fixedSeed, format: .number.grouping(.never))
                }
                Text("helper.advanced.seed.info").foregroundStyle(.secondary)
            }
            SetupSettingsSection()
        }
        .formStyle(.grouped)
        .onChange(of: model.settings.quality) { _, _ in SetupState.shared.refresh() }
    }
}
