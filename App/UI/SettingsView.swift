// Einstellungsfenster (⌘,) für den Helfer: Name/Telefon, Ablageort. Gespeichert wird sofort.
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section("settings.helper.header") {
                TextField("settings.helper.name", text: $settings.helperName)
                TextField("settings.helper.phone", text: $settings.helperPhone)
                Text("settings.helper.note").foregroundStyle(.secondary)
            }
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
                }
            }
            OwnVoiceSettingsSection()
            Section("settings.later.header") {
                Text("settings.later.text").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .font(.system(size: 15))
        .frame(width: 560)
        .padding()
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
