// Auf Bildschirm ②: Stilfrage mit „Eigener Wunsch …“ und die Karten der beschriebenen Stimmen.
import Pipeline
import Speech
import SwiftUI
import TextPrep

/// Stilknöpfe plus „Eigener Wunsch …“. Bei einer beschriebenen Stimme steckt der Stil schon in
/// der Beschreibung (Base übernimmt Sprechweise aus der Referenz, `instruct` wirkt dort nicht).
struct StyleSection: View {
    @Environment(AppModel.self) private var model
    var draft: Draft

    var body: some View {
        let designed = DesignedVoiceStore.isDesignedID(draft.voiceID ?? "")
        Text("voice.styleQuestion").font(OmaStyle.bodyBold).padding(.top, 4)
        if designed {
            Text("describeVoice.styleHint").foregroundStyle(Color.omaSecondaryText)
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 16)], alignment: .leading, spacing: 16) {
            if !designed {
                ForEach(VoiceStyle.allCases) { style in
                    ChoiceButton(
                        title: LocalizedStringKey(style.titleKey), systemImage: style.symbol,
                        selected: draft.style == style) { model.selectStyle(style) }
                }
            }
            ChoiceButton(title: "describeVoice.custom", systemImage: "text.bubble", selected: designed) {
                model.startDescribe()
            }
        }
    }
}

/// Die selbst beschriebenen Stimmen dieser Sprache als Karten.
struct DesignedVoicesSection: View {
    @Environment(AppModel.self) private var model
    var draft: Draft

    var body: some View {
        let voices = DesignedVoiceStore.standard.voices(for: draft.language)
        if !voices.isEmpty {
            Text("describeVoice.mine").font(OmaStyle.bodyBold).padding(.top, 4)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 20)], alignment: .leading, spacing: 20) {
                ForEach(voices, id: \.id) { voice in
                    DesignedVoiceCard(voice: voice, selected: draft.voiceID == voice.id)
                }
            }
        }
    }
}

struct DesignedVoiceCard: View {
    @Environment(AppModel.self) private var model
    var voice: Voice
    var selected: Bool
    @State private var playing = false

    var body: some View {
        VStack(spacing: 14) {
            Button { model.selectVoice(voice.id) } label: {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Color.omaBorder)
                    Text(voice.name).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                    Text(voice.description ?? "").foregroundStyle(Color.omaSecondaryText)
                        .multilineTextAlignment(.center).lineLimit(3)
                    if selected {
                        Label("voice.selected", systemImage: "checkmark.circle.fill").font(OmaStyle.bodyBold)
                    } else {
                        Label("voice.choose", systemImage: "circle").font(OmaStyle.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            .buttonStyle(.plain)

            Button {
                if playing { PreviewPlayer.shared.stop() } else {
                    playing = true
                    PreviewPlayer.shared.play(voice.referenceAudio) { playing = false }
                }
            } label: {
                Label(playing ? "describeVoice.listen.stop" : "voice.sample", systemImage: playing ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(OmaButtonStyle())
        }
        .omaCard(selected: selected)
    }
}

// MARK: Anbindung an AppModel

extension AppModel {
    /// „Eigener Wunsch …“ auf ②: öffnet den Bildschirm zum Beschreiben.
    func startDescribe() {
        guard let d = draft else { return }
        let model = makeDescribeModel()
        let ui: Language = VoiceCard.uiLanguage == "pt" ? .pt : .de
        model.begin(readingLanguage: d.language, uiLanguage: ui)
        model.onExit = { [weak self] in
            PreviewPlayer.shared.stop()
            self?.screen = .voice
        }
        model.onSaved = { [weak self] voice in
            self?.draft?.voiceID = voice.id
            self?.screen = .voice
        }
        describe = model
        screen = .describeVoice
    }

    /// Name der Stimme für Anzeige und MP3-Tags (fertige oder beschriebene Stimme).
    func voiceName(_ id: String) -> String {
        library.voice(id: id)?.name ?? DesignedVoiceStore.standard.voice(id: id)?.name ?? ""
    }

    /// Bei beschriebenen Stimmen gibt es keinen Stil (steckt in der Referenz).
    func styleKey(forVoice id: String?, style: VoiceStyle) -> String? {
        DesignedVoiceStore.isDesignedID(id ?? "") ? nil : style.rawValue
    }

    private func makeDescribeModel() -> DescribeVoiceModel {
        #if DEBUG
        if ProcessInfo.processInfo.environment["VORLESER_PREVIEW"] == "1" {
            return DescribeVoiceModel(service: PreviewVoiceDesignService())
        }
        #endif
        return DescribeVoiceModel(service: LiveVoiceDesignService(translator: SystemDescriptionTranslator()))
    }
}

#if DEBUG
/// Attrappe für Entwicklung und Bildschirmfotos (`VORLESER_PREVIEW=1`): kurze Wartezeit, Sinustöne.
struct PreviewVoiceDesignService: VoiceDesignService {
    func propose(
        wish: VoiceWish, referenceText: String, onStage: @escaping @Sendable (DesignStage) -> Void
    ) async throws -> [DesignedProposal] {
        onStage(.preparing)
        try await Task.sleep(for: .seconds(1))
        var out: [DesignedProposal] = []
        for i in 1...2 {
            onStage(.proposal(i, of: 2))
            try await Task.sleep(for: .seconds(1))
            let url = FileManager.default.temporaryDirectory.appending(path: "vorschau-\(i).wav")
            let rate = 24_000.0
            let samples = (0..<Int(rate * 2)).map { Float(0.2 * sin(2 * Double.pi * (200 + 80 * Double(i)) * Double($0) / rate)) }
            try ReferenceFiles.writeWAV(samples, sampleRate: rate, to: url)
            out.append(DesignedProposal(index: i, previewURL: url, duration: 2, isSuspicious: false))
        }
        onStage(.finishing)
        return out
    }

    func save(proposal index: Int, name: String) async throws -> Voice {
        let rate = 24_000.0
        let samples = (0..<Int(rate)).map { Float(0.2 * sin(2 * Double.pi * 220 * Double($0) / rate)) }
        return try DesignedVoiceStore.standard.save(
            samples: samples, sampleRate: rate, name: name, language: .de, description: "Vorschau", referenceText: "Vorschau")
    }
}
#endif
