// Einstellungsfenster (⌘,) für den Helfer, in Reitern. Normale Systemgröße (15 pt) ist hier gewollt:
// Das Fenster ist nicht für die Oma (PLAN.md §3, Regel 8), aber klar beschriftet. Gespeichert wird sofort.
import Observation
import SwiftUI

enum HelperTab: String, CaseIterable, Identifiable {
    case helper, folder, quality, model, voices, books, logs
    var id: String { rawValue }
    var titleKey: LocalizedStringKey { LocalizedStringKey("helper.tab.\(rawValue)") }
    var symbol: String {
        switch self {
        case .helper: "person.crop.circle"
        case .folder: "folder"
        case .quality: "slider.horizontal.3"
        case .model: "cpu"
        case .voices: "waveform"
        case .books: "headphones"
        case .logs: "doc.text.magnifyingglass"
        }
    }
}

/// Gewählter Reiter; auch für die Bildschirmfotos der Entwicklungshilfen.
@MainActor
@Observable
final class HelperNavigation {
    static let shared = HelperNavigation()
    var tab: HelperTab = .helper
}

struct HelperSettingsView: View {
    @Bindable private var nav = HelperNavigation.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("helper.window.note")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(.horizontal, 20).padding(.top, 12)
            TabView(selection: $nav.tab) {
                ForEach(HelperTab.allCases) { tab in
                    content(for: tab)
                        .tabItem { Label(tab.titleKey, systemImage: tab.symbol) }
                        .tag(tab)
                }
            }
        }
        .font(.system(size: 15))
        .frame(width: 740, height: 640)
    }

    @ViewBuilder private func content(for tab: HelperTab) -> some View {
        switch tab {
        case .helper: HelperInfoTab()
        case .folder: FolderTab()
        case .quality: QualityTab()
        case .model: ModelTab()
        case .voices: VoicesTab()
        case .books: BooksTab()
        case .logs: LogsTab()
        }
    }
}
