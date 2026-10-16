// Eintrag für das Einstellungsfenster (Helfer): „Einrichtung erneut prüfen“.
// Wird in SettingsView als `SetupSettingsSection()` eingebunden (siehe docs/phase5-setup.md).
import ModelSetup
import SwiftUI

struct SetupSettingsSection: View {
    private let setup = SetupState.shared

    var body: some View {
        Section("setup.settings.header") {
            LabeledContent("setup.settings.base") { Text(statusText(setup.baseStatus)) }
            LabeledContent("setup.settings.design") { Text(statusText(setup.designStatus)) }
            Button("setup.settings.recheck") { setup.reopenAssistant() }
        }
    }

    private func statusText(_ status: ModelStatus) -> String {
        switch status {
        case .ready: L("setup.settings.ready")
        case .missing: L("setup.settings.missing")
        case .partial: L("setup.settings.partial")
        case .corrupt: L("setup.settings.corrupt")
        }
    }
}
