// Aufgenommene Stimmen in Schritt ②: Karten.
import SwiftUI
import TextPrep

/// Die eigenen, aufgenommenen Stimmen der Sprache.
struct RecordedVoiceRow: View {
    @Environment(AppModel.self) private var model
    var draft: Draft

    var body: some View {
        let voices = model.library.recordedVoices(for: draft.language)
        if !voices.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20)], alignment: .leading, spacing: 20) {
                ForEach(voices) { voice in
                    RecordedVoiceCard(voice: voice, selected: draft.voiceID == voice.id)
                }
            }
        }
    }
}

struct RecordedVoiceCard: View {
    @Environment(AppModel.self) private var model
    var voice: StoredVoice
    var selected: Bool

    var body: some View {
        VStack(spacing: 14) {
            Button { model.selectVoice(voice.id) } label: {
                VStack(spacing: 10) {
                    Image(systemName: "mic.fill").font(.system(size: 44)).foregroundStyle(Color.omaBorder)
                    Text(voice.name).font(.system(size: 30, weight: .bold)).multilineTextAlignment(.center)
                    Text("ownVoice.card.sub").foregroundStyle(Color.omaSecondaryText).multilineTextAlignment(.center)
                    if selected {
                        Label("voice.selected", systemImage: "checkmark.circle.fill").font(OmaStyle.bodyBold)
                    } else {
                        Label("voice.choose", systemImage: "circle").font(OmaStyle.bodyBold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
            }
            .buttonStyle(.plain)
            OmaButton(title: "voice.sample", systemImage: "play.fill") { model.playSample(voiceID: voice.id) }
        }
        .omaCard(selected: selected)
    }
}
