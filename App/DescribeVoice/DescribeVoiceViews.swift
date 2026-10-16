// Bildschirme von „Stimme beschreiben“. Eine Frage pro Bildschirm, immer Zurück,
// Schrift ≥ 20 pt, Knöpfe ≥ 60 pt mit Symbol und Wort (PLAN §3).
import AppKit
import SwiftUI

struct DescribeVoiceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let d = model.describe {
            ZStack {
                switch d.step {
                case .wish: DescribeWishView(d: d)
                case .working: DescribeWorkingView(d: d)
                case .choose: DescribeChooseView(d: d)
                case .name: DescribeNameView(d: d)
                case .failed(let key): DescribeFailedView(d: d, messageKey: key)
                }
                if d.confirmCancel { DescribeCancelOverlay(d: d) }
            }
        }
    }
}

// MARK: Wunsch

struct DescribeWishView: View {
    @Bindable var d: DescribeVoiceModel
    @FocusState private var focused: Bool

    private static let examples = [
        "describeVoice.example.1", "describeVoice.example.2", "describeVoice.example.3", "describeVoice.example.4",
    ]

    var body: some View {
        ScreenScaffold(title: "describeVoice.title") {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $d.wishText)
                    .focused($focused)
                    .font(.system(size: 26))
                    .scrollContentBackground(.hidden)
                    .foregroundStyle(Color.omaText)
                    .padding(14)
                    .frame(minHeight: 150)
                    .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 2))
                if d.wishText.isEmpty {
                    Text("describeVoice.hint")
                        .font(.system(size: 26))
                        .foregroundStyle(Color.omaSecondaryText)
                        .padding(.horizontal, 20).padding(.vertical, 22)
                        .allowsHitTesting(false)
                }
            }

            OmaButton(title: "describeVoice.dictate", systemImage: "mic.fill") { dictate() }
            Text(d.dictationUnavailable ? "describeVoice.dictate.unavailable" : "describeVoice.dictate.hint")
                .foregroundStyle(Color.omaSecondaryText)

            Text("describeVoice.examples").font(OmaStyle.bodyBold).padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 400), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(Self.examples, id: \.self) { key in
                    Button { d.wishText = L(key); focused = true } label: {
                        Label(LocalizedStringKey(key), systemImage: "quote.bubble")
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(OmaButtonStyle())
                }
            }
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { d.back() }
                Spacer()
                OmaButton(title: "describeVoice.try", systemImage: "waveform", kind: .primary) { d.tryVoices() }
                    .disabled(!d.canTry)
            }
        }
        .onAppear { focused = true }
    }

    /// Systemdiktat: dieselbe Aktion wie „Bearbeiten › Diktat starten“. Geht nur, wenn Diktat im
    /// System eingeschaltet ist; sonst bleibt der Hinweis auf die Diktiertaste.
    private func dictate() {
        focused = true
        DispatchQueue.main.async {
            let ok = NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
            d.dictationUnavailable = !ok
        }
    }
}

// MARK: Warten

struct DescribeWorkingView: View {
    @Bindable var d: DescribeVoiceModel

    var body: some View {
        ScreenScaffold(title: "describeVoice.working.title") {
            Text("describeVoice.working.text")
            OmaProgressBar(fraction: d.fraction)
            HStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text(statusText).font(OmaStyle.bodyBold)
            }
            Text("describeVoice.working.quiet").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack {
                OmaButton(title: "describeVoice.cancel", systemImage: "xmark.circle") { d.back() }
                Spacer()
            }
        }
    }

    private var statusText: String {
        switch d.stage {
        case .preparing: L("describeVoice.working.prepare")
        case let .proposal(i, n): L("describeVoice.working.step", i, n)
        case .finishing: L("describeVoice.working.finish")
        }
    }
}

struct DescribeCancelOverlay: View {
    @Bindable var d: DescribeVoiceModel

    var body: some View {
        OverlayCard {
            Text("describeVoice.cancel.title").font(OmaStyle.headingFont)
            Text("describeVoice.cancel.text")
            HStack(spacing: 20) {
                OmaButton(title: "describeVoice.cancel.no", systemImage: "arrow.uturn.backward", kind: .primary) {
                    d.confirmCancel = false
                }
                OmaButton(title: "describeVoice.cancel.yes", systemImage: "xmark.circle") { d.cancelWork() }
            }
        }
    }
}

// MARK: Vorschlag wählen

struct DescribeChooseView: View {
    @Bindable var d: DescribeVoiceModel

    var body: some View {
        ScreenScaffold(title: "describeVoice.choose.title") {
            HStack(alignment: .top, spacing: 20) {
                ForEach(d.proposals) { p in ProposalCard(d: d, proposal: p) }
            }
            Text(L("describeVoice.choose.wish", d.wishText))
                .foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { d.back() }
                Spacer()
                OmaButton(title: "describeVoice.again", systemImage: "arrow.triangle.2.circlepath") { d.tryVoices() }
            }
        }
    }
}

struct ProposalCard: View {
    @Bindable var d: DescribeVoiceModel
    var proposal: DesignedProposal

    var body: some View {
        let isPlaying = d.playing == proposal.index
        VStack(spacing: 16) {
            Image(systemName: "waveform.circle.fill").font(.system(size: 56)).foregroundStyle(Color.omaBorder)
            Text(L("describeVoice.choose.proposal", proposal.index)).font(.system(size: 30, weight: .bold))
            if proposal.isSuspicious {
                Text("describeVoice.choose.check").foregroundStyle(Color.omaSecondaryText).multilineTextAlignment(.center)
            }
            Button { d.togglePlay(proposal) } label: {
                Label(isPlaying ? "describeVoice.listen.stop" : "describeVoice.listen",
                      systemImage: isPlaying ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OmaButtonStyle())
            Button { d.take(proposal) } label: {
                Label("describeVoice.take", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(OmaButtonStyle(kind: .primary))
        }
        .frame(maxWidth: .infinity)
        .omaCard()
    }
}

// MARK: Name

struct DescribeNameView: View {
    @Bindable var d: DescribeVoiceModel
    @FocusState private var focused: Bool

    var body: some View {
        ScreenScaffold(title: "describeVoice.name.title") {
            TextField("describeVoice.name.default", text: $d.name)
                .focused($focused)
                .textFieldStyle(.plain)
                .font(.system(size: 30))
                .padding(18)
                .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 2))
                .onSubmit { d.save() }
            Text("describeVoice.name.hint").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { d.back() }
                Spacer()
                OmaButton(title: "describeVoice.name.save", systemImage: "checkmark.circle.fill", kind: .primary) { d.save() }
                    .disabled(d.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { focused = true }
    }
}

// MARK: Fehler

struct DescribeFailedView: View {
    @Bindable var d: DescribeVoiceModel
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
                OmaButton(title: "common.back", systemImage: "chevron.left") { d.back() }
                Spacer()
                OmaButton(title: "describeVoice.retry", systemImage: "arrow.clockwise", kind: .primary) { d.tryVoices() }
            }
        }
    }
}
