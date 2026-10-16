// Reiter „Hörbücher“ (Platz, Aufräumen, Löschen) und „Protokolle“ (Verdachtsfälle, Kopieren, Logs).
import AppKit
import Projects
import SwiftUI

private func sizeText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

// MARK: Hörbücher

struct BooksTab: View {
    @Environment(AppModel.self) private var model
    @State private var books: HelperBooksModel?
    @State private var pendingClean: ProjectOverview?
    @State private var pendingDelete: ProjectOverview?
    @State private var info: String?

    var body: some View {
        Form {
            if let books {
                Section {
                    if books.rows.isEmpty { Text("helper.books.empty").foregroundStyle(.secondary) }
                    ForEach(books.rows) { row($0) }
                } footer: {
                    Text("helper.books.info")
                }
                if let info { Text(info).foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .task {
            if books == nil { books = HelperBooksModel(store: model.store) }
            await books?.reload()
        }
        .confirmationDialog(
            pendingClean.map { L("helper.books.cleanConfirm", $0.summary.title, sizeText($0.usage.intermediates)) } ?? "",
            isPresented: Binding(get: { pendingClean != nil }, set: { if !$0 { pendingClean = nil } }),
            titleVisibility: .visible
        ) {
            Button("helper.books.cleanYes", role: .destructive) {
                guard let row = pendingClean else { return }
                pendingClean = nil
                Task {
                    if let freed = await books?.cleanIntermediates(id: row.id) {
                        info = L("helper.books.cleaned", sizeText(freed))
                        await model.refreshProjects()
                    }
                }
            }
            Button("ownVoice.settings.deleteNo", role: .cancel) { pendingClean = nil }
        }
        .confirmationDialog(
            pendingDelete.map { L("helper.books.deleteConfirm", $0.summary.title) } ?? "",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("helper.books.deleteYes", role: .destructive) {
                guard let row = pendingDelete else { return }
                pendingDelete = nil
                Task {
                    await books?.delete(id: row.id)
                    AppLog.info("helper", "Projekt gelöscht")
                    await model.refreshProjects()
                }
            }
            Button("ownVoice.settings.deleteNo", role: .cancel) { pendingDelete = nil }
        }
    }

    private func row(_ r: ProjectOverview) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.summary.title).lineLimit(1)
                Text(detail(r)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if r.summary.state == .finished {
                Button("helper.books.clean") { pendingClean = r }.disabled(!r.canCleanIntermediates)
            }
            Button("helper.books.delete") { pendingDelete = r }
        }
    }

    private func detail(_ r: ProjectOverview) -> String {
        var parts: [String] = [
            r.summary.state == .finished ? Fmt.minutes(r.summary.duration) : L("books.unfinished"),
            L("helper.books.size", sizeText(r.usage.total)),
        ]
        if r.usage.intermediates > 0 { parts.append(L("helper.books.intermediate", sizeText(r.usage.intermediates))) }
        parts.append(r.summary.updatedAt.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

// MARK: Protokolle

struct LogsTab: View {
    @Environment(AppModel.self) private var model
    @State private var problems: [ProjectProblems] = []
    @State private var copied = false

    var body: some View {
        Form {
            Section("helper.logs.header") {
                Text("helper.logs.info").foregroundStyle(.secondary)
                HStack {
                    Button("helper.logs.copy") { copy() }
                    Button("helper.logs.openFolder") {
                        try? FileManager.default.createDirectory(at: AppLog.file.directory, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AppLog.file.directory)
                    }
                    if copied { Label("helper.logs.copied", systemImage: "checkmark").foregroundStyle(.secondary) }
                }
            }
            Section("helper.logs.problems") {
                if problems.isEmpty {
                    Text("helper.logs.none").foregroundStyle(.secondary)
                }
                ForEach(problems) { p in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.title).font(.system(size: 15, weight: .semibold))
                        ForEach(p.entries) { e in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entryTitle(e)).font(.system(size: 13, weight: .medium))
                                Text(e.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                if let err = e.error { Text(err).font(.system(size: 12)).foregroundStyle(.red) }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reload() }
    }

    private func reload() async {
        problems = await model.store.recentProblems(limit: 10, onlyWithProblems: true)
    }

    private func entryTitle(_ e: ProtocolEntry) -> String {
        var s = L("helper.logs.chunk", e.chunkIndex)
        if let page = e.pageIndex { s += " (" + L("helper.logs.page", page + 1) + ")" }
        s += " · " + L(e.status == .failed ? "helper.logs.failed" : "helper.logs.suspicious")
        if !e.issues.isEmpty { s += " · " + e.issues.joined(separator: ", ") }
        return s
    }

    private func copy() {
        Task {
            let text = await HelperProtocol.report(store: model.store, log: AppLog.file)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            await reload()
        }
    }
}
