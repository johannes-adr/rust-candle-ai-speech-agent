// Bildschirm „Meine eigene Stimme“ (alle Schritte in einem Bildschirm mit wechselndem Inhalt).
// Oma-Regeln (PLAN §3): Schrift ≥ 20 pt, Knöpfe ≥ 60 pt mit Symbol und Wort, eine Frage je Schritt,
// immer „Zurück“, kein Fachwort.
import AppKit
import SwiftUI
import VoiceCapture

enum OwnVoiceStyle {
    /// Roter Aufnahmeknopf: weiß auf dunklem Rot, Kontrast mindestens 7:1 (in OmaRulesTests geprüft).
    static let recordFill = RGB(0xA80018)
    static let recordLabel = RGB(0xFFFFFF)
    /// Lesetext groß, damit man ihn aus einem Meter Abstand lesen kann.
    static let readingSize: CGFloat = 32
    static let countdownSize: CGFloat = 160
    static let fieldSize: CGFloat = 26
}

struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(OmaStyle.buttonFont)
            .labelStyle(OmaLabelStyle())
            .foregroundStyle(Color(red: OwnVoiceStyle.recordLabel.r, green: OwnVoiceStyle.recordLabel.g, blue: OwnVoiceStyle.recordLabel.b))
            .padding(.horizontal, 36)
            .frame(minHeight: 84)
            .background(
                Color(red: OwnVoiceStyle.recordFill.r, green: OwnVoiceStyle.recordFill.g, blue: OwnVoiceStyle.recordFill.b),
                in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 3))
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
    }
}

struct OwnVoiceView: View {
    @Environment(AppModel.self) private var model
    var flow: OwnVoiceFlow

    var body: some View {
        switch flow.step {
        case .ready: ReadyStep(flow: flow)
        case .micDenied: MicDeniedStep(flow: flow)
        case .countdown(let n): CountdownStep(flow: flow, number: n)
        case .recording: RecordingStep(flow: flow)
        case .analyzing: AnalyzingStep()
        case .review: ReviewStep(flow: flow)
        case .consent, .saving: ConsentStep(flow: flow)
        case .failed(let key): FailedStep(flow: flow, messageKey: key)
        }
    }
}

// MARK: Schritte

private struct ReadingTextCard: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: OwnVoiceStyle.readingSize))
            .lineSpacing(8)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .omaCard()
            .accessibilityLabel(Text(text))
    }
}

private struct BackFooter<Trailing: View>: View {
    var flow: OwnVoiceFlow
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack {
            OmaButton(title: "common.back", systemImage: "chevron.left") { flow.back() }
            Spacer()
            trailing
        }
    }
}

private struct ReadyStep: View {
    var flow: OwnVoiceFlow
    var body: some View {
        ScreenScaffold(title: "ownVoice.read.title") {
            ReadingTextCard(text: flow.readingText)
            Text("ownVoice.read.hint").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            BackFooter(flow: flow) {
                Button { flow.tapRecord() } label: { Label("ownVoice.record", systemImage: "record.circle") }
                    .buttonStyle(RecordButtonStyle())
            }
        }
    }
}

private struct CountdownStep: View {
    var flow: OwnVoiceFlow
    var number: Int
    var body: some View {
        ScreenScaffold(title: "ownVoice.countdown.title") {
            VStack(spacing: 12) {
                Text("\(number)")
                    .font(.system(size: OwnVoiceStyle.countdownSize, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(Text("\(number)"))
                Text("ownVoice.countdown.sub").frame(maxWidth: .infinity)
            }
            .omaCard()
            ReadingTextCard(text: flow.readingText)
        } footer: {
            BackFooter(flow: flow) { EmptyView() }
        }
    }
}

private struct RecordingStep: View {
    var flow: OwnVoiceFlow

    private var liveHintKey: String {
        if flow.level.isHot { return "ownVoice.live.loud" }
        if flow.level.meterFraction < 0.25 { return "ownVoice.live.quiet" }
        return "ownVoice.live.good"
    }

    var body: some View {
        ScreenScaffold(title: "ownVoice.recording.title") {
            ReadingTextCard(text: flow.readingText)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "mic.fill").font(.system(size: 30))
                    Text("ownVoice.recording.level").font(OmaStyle.bodyBold)
                    Spacer()
                    Text(L("ownVoice.recording.seconds", Int(flow.level.elapsedSeconds))).monospacedDigit()
                }
                OmaProgressBar(fraction: flow.level.meterFraction)
                // Auch ohne Farbe verständlich: ein Satz sagt, ob es passt.
                Text(LocalizedStringKey(liveHintKey)).font(OmaStyle.bodyBold)
            }
            .omaCard()
        } footer: {
            BackFooter(flow: flow) {
                OmaButton(title: "ownVoice.recording.done", systemImage: "stop.circle.fill", kind: .primary) { flow.tapDone() }
            }
        }
    }
}

private struct AnalyzingStep: View {
    var body: some View {
        ScreenScaffold(title: "ownVoice.analyzing.title") {
            HStack(spacing: 20) {
                ProgressView().controlSize(.large)
                Text("ownVoice.analyzing.text")
            }
            .omaCard()
        }
    }
}

private struct ReviewStep: View {
    var flow: OwnVoiceFlow

    var body: some View {
        ScreenScaffold(title: "ownVoice.review.title") {
            if flow.canKeep {
                OmaButton(
                    title: flow.isPlaying ? "ownVoice.listen.stop" : "ownVoice.listen",
                    systemImage: flow.isPlaying ? "stop.fill" : "play.fill") { flow.togglePlayback() }
            }
            if flow.isClean {
                Label("ownVoice.review.good", systemImage: "checkmark.circle.fill").font(OmaStyle.bodyBold)
                    .omaCard()
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text(flow.canKeep ? "ownVoice.review.problems" : "ownVoice.review.unusable").font(OmaStyle.bodyBold)
                    ForEach(flow.hintKeys, id: \.self) { key in
                        Label(LocalizedStringKey(key), systemImage: "lightbulb.fill")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .omaCard()
            }
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { flow.back() }
                Spacer()
                OmaButton(title: "ownVoice.again", systemImage: "arrow.counterclockwise", kind: flow.canKeep && flow.isClean ? .secondary : .primary) {
                    flow.retry()
                }
                if flow.canKeep {
                    OmaButton(
                        title: flow.isClean ? "ownVoice.keep" : "ownVoice.keepAnyway", systemImage: "checkmark.circle.fill",
                        kind: flow.isClean ? .primary : .secondary) { flow.keep() }
                }
            }
        }
    }
}

private struct ConsentStep: View {
    @Bindable var flow: OwnVoiceFlow
    var body: some View {
        ScreenScaffold(title: "ownVoice.consent.title") {
            Button { flow.consent.toggle() } label: {
                Label("ownVoice.consent.check", systemImage: flow.consent ? "checkmark.square.fill" : "square")
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(OmaButtonStyle(kind: flow.consent ? .primary : .secondary))
            .accessibilityAddTraits(flow.consent ? .isSelected : [])
            if !flow.consent {
                Text("ownVoice.consent.needed").foregroundStyle(Color.omaSecondaryText)
            }

            Text("ownVoice.name.question").font(OmaStyle.bodyBold).padding(.top, 8)
            TextField("ownVoice.name.placeholder", text: $flow.name)
                .textFieldStyle(.plain)
                .font(.system(size: OwnVoiceStyle.fieldSize))
                .padding(.horizontal, 16)
                .frame(minHeight: OmaStyle.minButtonHeight)
                .background(Color.omaSurface, in: RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 2))
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { flow.back() }
                Spacer()
                OmaButton(title: "ownVoice.save", systemImage: "square.and.arrow.down", kind: .primary) { flow.save() }
                    .disabled(!flow.canSave || flow.step == .saving)
            }
        }
    }
}

private struct MicDeniedStep: View {
    var flow: OwnVoiceFlow
    var body: some View {
        ScreenScaffold(title: "ownVoice.mic.title") {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "mic.slash.fill").font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                VStack(alignment: .leading, spacing: 14) {
                    Text("ownVoice.mic.text")
                    Text("ownVoice.mic.steps").font(OmaStyle.bodyBold)
                }
            }
            .omaCard()
        } footer: {
            HStack {
                OmaButton(title: "common.back", systemImage: "chevron.left") { flow.back() }
                Spacer()
                OmaButton(title: "ownVoice.mic.retry", systemImage: "arrow.clockwise") { flow.recheckMicrophone() }
                OmaButton(title: "ownVoice.mic.open", systemImage: "gearshape", kind: .primary) { OwnVoiceSystemSettings.openMicrophone() }
            }
        }
    }
}

private struct FailedStep: View {
    var flow: OwnVoiceFlow
    var messageKey: String
    var body: some View {
        ScreenScaffold(title: "problem.title") {
            HStack(spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                Text(LocalizedStringKey(messageKey))
            }
            .omaCard()
        } footer: {
            BackFooter(flow: flow) {
                OmaButton(title: "ownVoice.again", systemImage: "arrow.counterclockwise", kind: .primary) { flow.retry() }
            }
        }
    }
}

enum OwnVoiceSystemSettings {
    /// Datenschutz › Mikrofon in den Systemeinstellungen.
    static func openMicrophone() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
