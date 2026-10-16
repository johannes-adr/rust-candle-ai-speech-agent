// Helfer-Einstellungen (⌘,): eigene Stimmen ansehen, löschen (mit Nachfrage) und eine vorhandene
// Aufnahme als Stimme hinzufügen. Normale Systemgröße, denn das ist für den Helfer.
import AppKit
import Foundation
import Observation
import VorleserSpeech
import SwiftUI
import TextPrep
import VoiceCapture

/// Zustand des Imports im Einstellungsfenster.
@MainActor
@Observable
final class OwnVoiceImportModel {
    enum State: Equatable { case idle, working, done, failed(String) }

    var fileURL: URL?
    var language: Language = AppModel.uiDefaultLanguage
    var name = ""
    var providedText = ""
    var consent = false
    private(set) var state: State = .idle

    var canImport: Bool { fileURL != nil && consent && state != .working }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("ownVoice.settings.import.panelMessage")
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.fileURL = url
                if self?.name.isEmpty ?? false { self?.name = url.deletingPathExtension().lastPathComponent }
                self?.state = .idle
            }
        }
    }

    func run(store: RecordedVoiceStore, transcriber: any SpeechTranscribing = SystemTranscriber()) {
        guard canImport, let url = fileURL else { return }
        state = .working
        let language = language, name = name, text = providedText
        Task {
            do {
                let ref = try await VoiceImporter.prepare(
                    fileURL: url, language: language, providedText: text.isEmpty ? nil : text, transcriber: transcriber)
                try store.save(
                    samples: ref.samples, sampleRate: ref.sampleRate, transcript: ref.transcript, name: name,
                    language: language, consent: consent, source: "import", transcriptSource: ref.transcriptSource.rawValue)
                state = .done
                fileURL = nil
                providedText = ""
                consent = false
            } catch VoiceImportError.transcriptNeeded {
                state = .failed("ownVoice.settings.import.needText")
            } catch VoiceImportError.providedTextNeedsShortFile {
                state = .failed("ownVoice.settings.import.tooLong")
            } catch VoiceImportError.recordingUnusable {
                state = .failed("ownVoice.settings.import.unusable")
            } catch {
                state = .failed("ownVoice.settings.import.failed")
            }
        }
    }
}

struct OwnVoiceSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var importModel = OwnVoiceImportModel()
    @State private var refresh = 0
    @State private var pendingDelete: RecordedVoiceInfo?

    private var store: RecordedVoiceStore { model.library.store.custom ?? RecordedVoiceStore() }

    var body: some View {
        Section("ownVoice.settings.header") {
            let voices = { _ = refresh; return store.list() }()
            if voices.isEmpty {
                Text("ownVoice.settings.empty").foregroundStyle(.secondary)
            }
            ForEach(voices) { v in
                HStack {
                    VStack(alignment: .leading) {
                        Text(v.name)
                        Text("\(L(v.language.nameKey)) · \(Fmt.minutes(v.durationSeconds)) · \(v.createdAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("ownVoice.settings.delete") { pendingDelete = v }
                }
            }
            DisclosureGroup("ownVoice.settings.import.header") {
                importForm
            }
        }
        .confirmationDialog(
            pendingDelete.map { L("ownVoice.settings.deleteConfirm", $0.name) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("ownVoice.settings.deleteYes", role: .destructive) {
                if let v = pendingDelete { try? store.delete(id: v.id) }
                pendingDelete = nil
                refresh += 1
                model.validateSelectedVoice()
            }
            Button("ownVoice.settings.deleteNo", role: .cancel) { pendingDelete = nil }
        }
    }

    @ViewBuilder private var importForm: some View {
        @Bindable var m = importModel
        Text("ownVoice.settings.import.info").font(.system(size: 12)).foregroundStyle(.secondary)
        HStack {
            Button("ownVoice.settings.import.choose") { importModel.chooseFile() }
            Text(importModel.fileURL?.lastPathComponent ?? "").foregroundStyle(.secondary)
        }
        Picker("ownVoice.settings.import.language", selection: $m.language) {
            ForEach(Language.allCases, id: \.self) { Text(L($0.nameKey)).tag($0) }
        }
        TextField("ownVoice.settings.import.name", text: $m.name)
        TextField("ownVoice.settings.import.text", text: $m.providedText, axis: .vertical)
        Toggle("ownVoice.settings.import.consent", isOn: $m.consent)
        HStack {
            Button("ownVoice.settings.import.run") {
                importModel.run(store: store)
            }
            .disabled(!importModel.canImport)
            switch importModel.state {
            case .working: ProgressView().controlSize(.small)
            case .done:
                Text("ownVoice.settings.import.done").foregroundStyle(.secondary)
            case .failed(let key): Text(LocalizedStringKey(key)).foregroundStyle(.red)
            case .idle: EmptyView()
            }
        }
        .onChange(of: importModel.state) { _, new in if new == .done { refresh += 1 } }
    }
}
