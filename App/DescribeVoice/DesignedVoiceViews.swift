// Auf Bildschirm ②: die Karten der beschriebenen Stimmen und der Weg zum Beschreiben.
import Pipeline
import VorleserSpeech
import SwiftUI
import TextPrep

/// Die selbst beschriebenen Stimmen dieser Sprache als Karten.
struct DesignedVoicesSection: View {
    @Environment(AppModel.self) private var model
    var draft: Draft

    var body: some View {
        let voices = model.library.store.designedVoices(for: draft.language)
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
    var voice: RecordedVoiceInfo
    var selected: Bool
    @State private var playing = false

    var body: some View {
        VStack(spacing: 14) {
            Button { model.selectVoice(voice.id) } label: {
                VStack(spacing: 10) {
                    Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(Color.omaBorder)
                    Text(voice.name).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                    Text(voice.wish ?? "").foregroundStyle(Color.omaSecondaryText)
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
                    if let url = model.library.referenceURL(voiceID: voice.id) {
                        PreviewPlayer.shared.play(url) { playing = false }
                    }
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
    /// Sprache der Oberfläche ("de" oder "pt").
    static var uiLanguageCode: String {
        (Bundle.main.preferredLocalizations.first ?? "de").hasPrefix("pt") ? "pt" : "de"
    }

    /// „Stimme beschreiben“ auf ②: öffnet den Bildschirm zum Beschreiben.
    func startDescribe() {
        guard let d = draft else { return }
        let model = makeDescribeModel()
        let ui: Language = Self.uiLanguageCode == "pt" ? .pt : .de
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

    /// Name der Stimme für Anzeige und MP3-Tags.
    func voiceName(_ id: String) -> String {
        library.voice(id: id)?.name ?? ""
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
        return try RecordedVoiceStore(directory: VoiceLibrary.defaultCustomDirectory).saveDesigned(
            samples: samples, sampleRate: rate, referenceText: "Vorschau", name: name, language: .de,
            wish: "Vorschau", prompt: nil, seed: nil)
    }
}
#endif
