// ② Stimme: erkannte Sprache, Stimmkarten, Stil, Tempo.
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

                OwnVoiceHonestNote()
                StyleSection(draft: draft).hiddenForOwnVoice()

                Text("voice.tempo").font(OmaStyle.bodyBold).padding(.top, 4)
                HStack(spacing: 16) {
                    ForEach(Tempo.allCases) { tempo in
                        ChoiceButton(
                            title: LocalizedStringKey(tempo.titleKey), systemImage: Self.tempoSymbol(tempo),
                            selected: draft.tempo == tempo) { model.selectTempo(tempo) }
                    }
                }
            } footer: {
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

    @ViewBuilder private func voiceCards(_ draft: Draft) -> some View {
        let voices = model.library.voices(for: draft.language)
        if voices.isEmpty {
            Text("voice.noVoices")
        }
        HStack(alignment: .top, spacing: 20) {
            ForEach(voices) { voice in VoiceCard(voice: voice, selected: draft.voiceID == voice.id) }
            OwnVoiceCard()
        }
        RecordedVoiceRow(draft: draft)
        if voices.contains(where: { !model.hasSample(voiceID: $0.id) }) {
            Text("voice.sampleSoon").foregroundStyle(Color.omaSecondaryText)
        }
        DesignedVoicesSection(draft: draft)
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

struct VoiceCard: View {
    @Environment(AppModel.self) private var model
    var voice: PresetVoice
    var selected: Bool

    var body: some View {
        VStack(spacing: 14) {
            Button { model.selectVoice(voice.id) } label: {
                VStack(spacing: 10) {
                    Image(systemName: "person.fill")
                        .font(.system(size: 44)).foregroundStyle(Color.omaBorder)
                    Text(voice.name).font(.system(size: 30, weight: .bold))
                    Text(voice.description(for: Self.uiLanguage)).foregroundStyle(Color.omaSecondaryText)
                        .multilineTextAlignment(.center)
                    if selected {
                        Label("voice.selected", systemImage: "checkmark.circle.fill").font(OmaStyle.bodyBold)
                    } else {
                        Label("voice.choose", systemImage: "circle").font(OmaStyle.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            .buttonStyle(.plain)

            let hasSample = model.hasSample(voiceID: voice.id)
            OmaButton(title: "voice.sample", systemImage: "play.fill") { model.playSample(voiceID: voice.id) }
                .disabled(!hasSample)
        }
        .omaCard(selected: selected)
    }

    /// Sprache der Oberfläche für die Kurzbeschreibung ("de" oder "pt").
    static var uiLanguage: String {
        (Bundle.main.preferredLocalizations.first ?? "de").hasPrefix("pt") ? "pt" : "de"
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
