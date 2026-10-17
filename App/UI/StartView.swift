// ① Start: Datei wählen oder Text eintippen, darunter „Meine Hörbücher“.
import Projects
import SwiftUI

struct StartView: View {
    @Environment(AppModel.self) private var model
    @State private var dropTargeted = false

    var body: some View {
        ScreenScaffold(title: "start.title") {
            HStack(spacing: OmaStyle.spacing) {
                ChoiceCard(
                    systemImage: "doc.richtext", title: "start.file.title", subtitle: "start.file.sub"
                ) { model.chooseFile() }
                ChoiceCard(
                    systemImage: "square.and.pencil", title: "start.text.title", subtitle: "start.text.sub"
                ) { model.screen = .typeText }
            }
            CameraCard { model.startCamera() }
            Label("start.drop", systemImage: "arrow.down.doc")
                .foregroundStyle(Color.omaSecondaryText)
                .frame(maxWidth: .infinity)

            Text("start.books").font(OmaStyle.headingFont).padding(.top, 8)
            if model.projects.isEmpty {
                Text("start.books.empty").foregroundStyle(Color.omaSecondaryText)
            } else {
                VStack(spacing: 12) {
                    ForEach(model.projects) { BookRow(summary: $0) }
                }
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: OmaStyle.cornerRadius)
                    .stroke(Color.omaBorder, style: StrokeStyle(lineWidth: 6, dash: [14, 8]))
                    .padding(12)
            }
        }
        // Ziehen geht zusätzlich; der Weg über die Karten bleibt der Hauptweg.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: \.isFileURL) else { return false }
            model.importFile(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .task { await model.refreshProjects() }
    }
}

/// Große Karte, die als ein einziger Knopf funktioniert.
struct ChoiceCard: View {
    var systemImage: String
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                Image(systemName: systemImage).font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                Text(title).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                Text(subtitle).foregroundStyle(Color.omaSecondaryText).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .omaCard()
        }
        .buttonStyle(.plain)
    }
}

struct BookRow: View {
    @Environment(AppModel.self) private var model
    var summary: ProjectSummary

    var body: some View {
        Button { model.open(summary) } label: {
            HStack(spacing: 18) {
                Image(systemName: summary.state == .finished ? "headphones" : "hourglass")
                    .font(.system(size: 30)).foregroundStyle(Color.omaBorder).frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary.title).font(OmaStyle.bodyBold).lineLimit(1)
                    Text(subtitle).foregroundStyle(Color.omaSecondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 24, weight: .semibold))
            }
            .frame(minHeight: OmaStyle.buttonHeight)
            .omaCard()
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        if summary.state == .finished {
            return "\(Fmt.minutes(summary.duration)) · \(Fmt.relative(summary.updatedAt))"
        }
        return L("books.unfinished")
    }
}

// MARK: Text eintippen

struct TypeTextView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ScreenScaffold(step: 1, title: "typeText.title") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.typedText)
                    .font(.system(size: 24))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Color.omaText)
                    .padding(14)
                    .frame(minHeight: 340)
                    .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 2))
                if model.typedText.isEmpty {
                    Text("typeText.hint")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.omaSecondaryText)
                        .padding(.horizontal, 20).padding(.vertical, 22)
                        .allowsHitTesting(false)
                }
            }
            OmaButton(title: "typeText.paste", systemImage: "doc.on.clipboard") {
                if let s = NSPasteboard.general.string(forType: .string) { model.typedText += s }
            }
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { model.goHome() }
                Spacer()
                OmaButton(title: "common.next", systemImage: "chevron.right", kind: .primary) {
                    model.submitTypedText()
                }
                .disabled(model.typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

// MARK: Datei wird gelesen

struct ImportingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScreenScaffold(step: 1, title: "importing.title") {
            Text("importing.sub").foregroundStyle(Color.omaSecondaryText)
            ProgressView().controlSize(.extraLarge)
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { model.goHome() }
                Spacer()
            }
        }
    }
}
