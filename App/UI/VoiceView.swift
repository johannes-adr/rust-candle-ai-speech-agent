// ② Stimme: erkannte Sprache, eigene Stimmen, Karten zum Aufnehmen und Beschreiben, Tempo.
import SwiftUI
import TextPrep

struct VoiceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let draft = model.draft {
            ScreenScaffold(step: 2, title: "voice.title") {
                LanguageRow(draft: draft)
                voiceCards(draft)
                if let key = model.sampleMessage { Text(LocalizedStringKey(key)).foregroundStyle(Color.omaSecondaryText) }

                Text("voice.tempo").font(OmaStyle.bodyBold).padding(.top, 4)
                HStack(spacing: 16) {
                    ForEach(Tempo.allCases) { tempo in
                        ChoiceButton(
                            title: LocalizedStringKey(tempo.titleKey), systemImage: Self.tempoSymbol(tempo),
                            selected: draft.tempo == tempo) { model.selectTempo(tempo) }
                    }
                }
            } footer: {
                VStack(alignment: .trailing, spacing: 10) {
                    if draft.voiceID == nil {
                        Label("voice.needVoice", systemImage: "exclamationmark.circle.fill")
                            .font(OmaStyle.bodyBold)
                    }
                    HStack {
                        OmaButton(title: "common.back", systemImage: "chevron.left") { model.goHome() }
                        Spacer()
                        OmaButton(title: "voice.start", systemImage: "play.circle.fill", kind: .primary) {
                            model.startWork()
                        }
                        .disabled(draft.voiceID == nil)
                    }
                }
            }
        }
    }

    @ViewBuilder private func voiceCards(_ draft: Draft) -> some View {
        if model.library.voices(for: draft.language).isEmpty {
            NoVoiceCard()
        }
        RecordedVoiceRow(draft: draft)
        DesignedVoicesSection(draft: draft)
        HStack(alignment: .top, spacing: 20) {
            OwnVoiceCard()
            DescribeVoiceCard()
        }
    }

    private static func tempoSymbol(_ t: Tempo) -> String {
        switch t {
        case .slower: "tortoise"
        case .normal: "equal.circle"
        case .faster: "hare"
        }
    }
}

struct LanguageRow: View {
    @Environment(AppModel.self) private var model
    var draft: Draft

    var body: some View {
        if model.showLanguagePicker {
            VStack(alignment: .leading, spacing: 14) {
                Text("voice.language.ask").font(OmaStyle.bodyBold)
                if draft.detection?.isUncertain ?? true {
                    Text("voice.language.unsure").foregroundStyle(Color.omaSecondaryText)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 14)], alignment: .leading, spacing: 14) {
                    ForEach(Language.allCases, id: \.self) { lang in
                        ChoiceButton(
                            title: LocalizedStringKey(lang.nameKey), systemImage: "globe",
                            selected: lang == draft.language) { model.setLanguage(lang) }
                    }
                }
            }
        } else {
            HStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 30)).foregroundStyle(Color.omaBorder)
                Text(L("voice.language", L(draft.language.nameKey))).font(OmaStyle.bodyBold)
                Spacer()
                OmaButton(title: "voice.language.change", systemImage: "pencil") { model.showLanguagePicker = true }
            }
        }
    }
}

/// Knopf, der „ausgewählt“ nicht nur durch Farbe, sondern auch durch Häkchen zeigt.
struct ChoiceButton: View {
    var title: LocalizedStringKey
    var systemImage: String
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: selected ? "checkmark.circle.fill" : systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(OmaButtonStyle(kind: selected ? .primary : .secondary))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Freundlicher Hinweis, solange es für die Sprache noch keine Stimme gibt.
struct NoVoiceCard: View {
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 44)).foregroundStyle(Color.omaBorder)
            VStack(alignment: .leading, spacing: 8) {
                Text("voice.empty.title").font(.system(size: 30, weight: .bold))
                Text("voice.empty.text")
            }
            Spacer(minLength: 0)
        }
        .omaCard()
    }
}

struct OwnVoiceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Button { model.chooseOwnVoice() } label: {
                VStack(spacing: 10) {
                    Image(systemName: "mic.fill").font(.system(size: 44)).foregroundStyle(Color.omaBorder)
                    Text("voice.own.title").font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                    Text("voice.own.sub").foregroundStyle(Color.omaSecondaryText).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            .buttonStyle(.plain)
            OmaButton(title: "voice.own.record", systemImage: "mic.circle") { model.chooseOwnVoice() }
        }
        .omaCard()
    }
}

struct DescribeVoiceCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Button { model.startDescribe() } label: {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Color.omaBorder)
                    Text("voice.describe.title").font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                    Text("voice.describe.sub").foregroundStyle(Color.omaSecondaryText).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            .buttonStyle(.plain)
            OmaButton(title: "voice.describe.button", systemImage: "text.bubble") { model.startDescribe() }
        }
        .omaCard()
    }
}
