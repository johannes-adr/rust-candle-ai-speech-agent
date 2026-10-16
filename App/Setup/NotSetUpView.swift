// Bildschirm für die Oma, solange die Sprachdaten fehlen: ein Satz, wen sie anrufen soll, ein Knopf für den Helfer.
// Gilt wie alle Oma-Bildschirme: große Schrift, Knöpfe mit Symbol und Wort, nichts Verstecktes.
import SwiftUI

struct NotSetUpView: View {
    @Environment(AppModel.self) private var model
    private let setup = SetupState.shared

    var body: some View {
        ScreenScaffold(title: "setup.not.title") {
            HStack(alignment: .top, spacing: 24) {
                Image(systemName: "phone.circle.fill").font(.system(size: 72)).foregroundStyle(Color.omaBorder)
                VStack(alignment: .leading, spacing: 12) {
                    Text(callText).font(OmaStyle.titleFont).fixedSize(horizontal: false, vertical: true)
                    if !model.settings.helperPhone.isEmpty {
                        Label(model.settings.helperPhone, systemImage: "phone.fill").font(OmaStyle.titleFont)
                    }
                }
            }
            .omaCard()
            Text("setup.not.text").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack(spacing: 20) {
                OmaButton(title: "setup.not.helperButton", systemImage: "wrench.and.screwdriver") { setup.showAssistant = true }
                Spacer()
                OmaButton(title: "setup.not.recheck", systemImage: "arrow.clockwise", kind: .primary) { setup.refresh() }
            }
        }
    }

    /// „Bitte rufen Sie Frau Schmidt an.“ bzw. ohne Namen „… Ihren Helfer an.“
    private var callText: String {
        let name = model.settings.helperName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? L("setup.not.callNoName") : L("setup.not.call", name)
    }
}
