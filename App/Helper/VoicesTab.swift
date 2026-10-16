// Reiter „Stimmen“: alle Stimmen (eingebaut, aufgenommen, beschrieben) mit Probe, Umbenennen, Löschen
// (nur eigene und beschriebene, mit Nachfrage) und Import einer Audiodatei.
import SwiftUI
import VorleserSpeech

struct VoicesTab: View {
    @Environment(AppModel.self) private var model
    @State private var voices: HelperVoicesModel?
    @State private var pendingDelete: HelperVoiceEntry?
    @State private var renaming: HelperVoiceEntry?
    @State private var newName = ""

    var body: some View {
        Form {
            if let voices {
                Section("helper.voices.builtIn") {
                    ForEach(voices.entries.filter { $0.origin == .builtIn }) { row($0, voices) }
                }
                Section("helper.voices.own") {
                    let own = voices.entries.filter { $0.origin != .builtIn }
                    if own.isEmpty { Text("helper.voices.ownEmpty").foregroundStyle(.secondary) }
                    ForEach(own) { row($0, voices) }
                }
            }
            Section {
                DisclosureGroup("ownVoice.settings.import.header") {
                    VoiceImportForm(store: model.library.store.custom ?? RecordedVoiceStore()) {
                        voices?.reload()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { if voices == nil { voices = HelperVoicesModel(library: model.library) } else { voices?.reload() } }
        .onDisappear { voices?.stopSample() }
        .confirmationDialog(
            pendingDelete.map { L("ownVoice.settings.deleteConfirm", $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("ownVoice.settings.deleteYes", role: .destructive) {
                if let v = pendingDelete {
                    try? voices?.delete(id: v.id)
                    AppLog.info("helper", "Stimme gelöscht (\(v.origin == .designed ? "beschrieben" : "aufgenommen"))")
                    model.validateSelectedVoice()
                }
                pendingDelete = nil
            }
            Button("ownVoice.settings.deleteNo", role: .cancel) { pendingDelete = nil }
        }
        .sheet(item: $renaming) { entry in
            VStack(alignment: .leading, spacing: 14) {
                Text("helper.voices.renameTitle").font(.headline)
                TextField("helper.voices.renameField", text: $newName).onSubmit { applyRename(entry) }
                HStack {
                    Spacer()
                    Button("ownVoice.settings.deleteNo") { renaming = nil }
                    Button("helper.voices.renameSave") { applyRename(entry) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
    }

    private func applyRename(_ entry: HelperVoiceEntry) {
        try? voices?.rename(id: entry.id, to: newName)
        renaming = nil
    }

    private func row(_ v: HelperVoiceEntry, _ voices: HelperVoicesModel) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(v.name)
                Text(detail(v)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(voices.playingID == v.id ? "helper.voices.stop" : "voice.sample") { voices.toggleSample(id: v.id) }
                .disabled(!voices.hasSample(v.id))
            if v.isEditable {
                Button("helper.voices.rename") { newName = v.name; renaming = v }
                Button("ownVoice.settings.delete") { pendingDelete = v }
            }
        }
    }

    private func detail(_ v: HelperVoiceEntry) -> String {
        var parts = [L(v.language.nameKey), L(originKey(v.origin))]
        if let s = v.durationSeconds { parts.append(Fmt.minutes(s)) }
        if let d = v.createdAt { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }

    private func originKey(_ o: VoiceOrigin) -> String {
        switch o {
        case .builtIn: "helper.voices.origin.builtIn"
        case .recorded: "helper.voices.origin.recorded"
        case .designed: "helper.voices.origin.designed"
        }
    }
}
