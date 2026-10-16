import SwiftUI

@main
struct VorleserApp: App {
    @State private var model = AppModel.makeForLaunch()

    var body: some Scene {
        Window("app.name", id: "main") {
            RootView()
                .environment(model)
                .task { await DebugLaunch.runIfRequested(model) }
        }
        .defaultSize(width: 1040, height: 820)

        Settings {
            SettingsView().environment(model)
        }
    }
}
