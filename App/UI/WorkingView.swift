// ③ Es arbeitet, ④ Fertig, dazu Fehler- und „Kommt bald“-Bildschirme.
import SwiftUI

struct WorkingView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScreenScaffold(step: 3, title: "working.title") {
            OmaProgressBar(fraction: model.progress.fraction)
            Text(positionText).font(OmaStyle.bodyBold)
            Text(remainingText)
            Label("working.hint", systemImage: "info.circle")
                .padding(.top, 8)
                .foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack(spacing: 20) {
                OmaButton(title: "working.listen", systemImage: "play.fill") { model.listenAhead() }
                    .disabled(model.phase != .working)
                Spacer()
                OmaButton(title: "working.stop", systemImage: "pause.circle") { model.confirmStop = true }
            }
        }
    }

    /// „Seite x von y“, sonst Prozent.
    private var positionText: String {
        switch model.phase {
        case .preparing: return L("working.preparing")
        case .finishing: return L("working.finishing")
        case .working:
            if let page = model.progress.currentPage, let total = model.progress.totalPages, total > 1 {
                return L("working.page", min(page, total), total)
            }
            return L("working.percent", Int((model.progress.fraction * 100).rounded()))
        }
    }

    private var remainingText: String {
        guard model.phase == .working, let minutes = Fmt.remainingMinutes(model.progress.remainingSeconds) else {
            return model.phase == .working ? L("working.remaining.unknown") : ""
        }
        if minutes < 1 { return L("working.remaining.short") }
        return String(localized: "working.remaining \(minutes)")
    }
}

// MARK: ④ Fertig

struct DoneView: View {
    @Environment(AppModel.self) private var model
    @State private var showPlayer = false

    var body: some View {
        if let result = model.result {
            ScreenScaffold(title: "done.title") {
                Text(L("done.name", result.title, Fmt.minutes(result.durationSeconds)))
                    .font(OmaStyle.bodyBold)
                HStack(spacing: 20) {
                    OmaButton(title: "done.listen", systemImage: "play.fill", kind: .primary) {
                        showPlayer = true
                        model.player.play()
                    }
                    ShareLink(item: result.fileURL) {
                        Label("done.share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(OmaButtonStyle(kind: .secondary))
                    OmaButton(title: "done.show", systemImage: "folder") { model.showInFinder() }
                }
                if showPlayer { PlayerPanel() }
                Label(L("done.saved", model.savedInDescription), systemImage: "externaldrive")
                    .foregroundStyle(Color.omaSecondaryText)
            } footer: {
                HStack {
                    OmaButton(title: "done.home", systemImage: "house") { model.goHome() }
                    Spacer()
                }
            }
        }
    }
}

struct PlayerPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let p = model.player
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 20) {
                Button { p.toggle() } label: {
                    Label(p.isPlaying ? "player.pause" : "player.play", systemImage: p.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 30, weight: .bold))
                        .padding(.horizontal, 12)
                }
                .buttonStyle(OmaButtonStyle(kind: .primary))
                .frame(minHeight: 80)
                OmaButton(title: "player.back30", systemImage: "gobackward.30") { p.back30() }
                Spacer()
                Text(L("player.position", Fmt.clock(p.position), Fmt.clock(p.duration)))
                    .font(OmaStyle.bodyBold).monospacedDigit()
            }
            OmaProgressBar(fraction: p.duration > 0 ? p.position / p.duration : 0)
        }
        .omaCard()
    }
}

// MARK: Hinweis-Bildschirme

struct ComingSoonView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScreenScaffold(title: "comingSoon.title") {
            HStack(spacing: 20) {
                Image(systemName: "sparkles").font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                Text("comingSoon.text")
            }
            .omaCard()
        } footer: {
            HStack {
                OmaButton(title: "comingSoon.back", systemImage: "chevron.left", kind: .primary) { model.screen = .voice }
                Spacer()
            }
        }
    }
}

struct ProblemView: View {
    @Environment(AppModel.self) private var model
    var messageKey: String

    var body: some View {
        ScreenScaffold(title: "problem.title") {
            HStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                Text(LocalizedStringKey(messageKey))
            }
            .omaCard()
        } footer: {
            HStack {
                OmaButton(title: "problem.back", systemImage: "house", kind: .primary) { model.goHome() }
                Spacer()
            }
        }
    }
}
