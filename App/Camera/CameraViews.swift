// Oberfläche „Vom iPhone fotografieren“. Oma-Regeln: Schrift ≥ 20 pt, Knöpfe ≥ 60 pt mit Symbol und Wort,
// eine Frage pro Bildschirm, immer „Zurück“, Abbrechen fragt nach. Kein Hover, kein Rechtsklick.
import AppKit
import SwiftUI

struct CameraView: View {
    var flow: CameraFlow

    var body: some View {
        ZStack {
            content
            if flow.confirmDiscard { DiscardOverlay(flow: flow) }
        }
        .task { flow.start() }
    }

    @ViewBuilder private var content: some View {
        switch flow.step {
        case .waiting: CameraWaitingView(flow: flow)
        case .denied: CameraDeniedView(flow: flow)
        case .shoot: CameraShootView(flow: flow)
        case .review: CameraReviewView(flow: flow)
        case .more: CameraMoreView(flow: flow)
        case .reading: CameraReadingView(flow: flow)
        case .partial(let pages): CameraPartialView(flow: flow, pages: pages)
        }
    }
}

private struct BackFooter<Extra: View>: View {
    var flow: CameraFlow
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack {
            OmaButton(title: "common.back", systemImage: "chevron.left") { flow.back() }
            Spacer()
            extra
        }
    }
}

// MARK: Kein iPhone

struct CameraWaitingView: View {
    var flow: CameraFlow

    var body: some View {
        ScreenScaffold(title: "camera.waiting.title") {
            HStack(alignment: .top, spacing: 24) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 72)).foregroundStyle(Color.omaBorder)
                VStack(alignment: .leading, spacing: 14) {
                    Text("camera.waiting.step1")
                    Text("camera.waiting.step2")
                    Text("camera.waiting.step3")
                }
            }
            .omaCard()
            HStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text("camera.waiting.searching").foregroundStyle(Color.omaSecondaryText)
            }
            Text("camera.waiting.helper").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            BackFooter(flow: flow) { EmptyView() }
        }
    }
}

struct CameraDeniedView: View {
    var flow: CameraFlow

    var body: some View {
        ScreenScaffold(title: "camera.denied.title") {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "camera.badge.ellipsis").font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                Text("camera.denied.text")
            }
            .omaCard()
        } footer: {
            BackFooter(flow: flow) {
                OmaButton(title: "camera.denied.open", systemImage: "gearshape", kind: .primary) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }
}

// MARK: Aufnehmen

struct CameraShootView: View {
    var flow: CameraFlow

    var body: some View {
        ScreenScaffold(title: "camera.shoot.title") {
            Text(L("camera.shoot.page", flow.pageCount + 1)).font(OmaStyle.bodyBold).foregroundStyle(Color.omaSecondaryText)
            ZStack {
                Color.black
                if let session = flow.camera.previewSession {
                    CameraPreview(session: session)
                } else {
                    Image(systemName: "camera.viewfinder").font(.system(size: 80)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: OmaStyle.cornerRadius).stroke(Color.omaBorder, lineWidth: 2))
            Text("camera.shoot.hint").foregroundStyle(Color.omaSecondaryText)
            if flow.captureFailed {
                Label("camera.shoot.error", systemImage: "exclamationmark.triangle").font(OmaStyle.bodyBold)
            }
        } footer: {
            BackFooter(flow: flow) {
                OmaButton(title: "camera.shoot.take", systemImage: "camera.fill", kind: .primary) { flow.takePhoto() }
                    .disabled(flow.isCapturing)
            }
        }
    }
}

struct CameraReviewView: View {
    var flow: CameraFlow

    var body: some View {
        ScreenScaffold(title: "camera.review.title") {
            if let url = flow.lastPage, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 420)
                    .frame(maxWidth: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.omaBorder, lineWidth: 2))
            }
            Text("camera.review.hint").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            BackFooter(flow: flow) {
                OmaButton(title: "camera.review.again", systemImage: "arrow.counterclockwise") { flow.retakeLast() }
                OmaButton(title: "camera.review.yes", systemImage: "checkmark", kind: .primary) { flow.acceptLast() }
            }
        }
    }
}

// MARK: Noch eine Seite?

struct CameraMoreView: View {
    var flow: CameraFlow

    var body: some View {
        ScreenScaffold(title: "camera.more.title") {
            Text(L("camera.more.count", flow.pageCount)).font(OmaStyle.bodyBold)
            ScrollView(.horizontal) {
                HStack(spacing: 14) {
                    ForEach(Array(flow.pages.enumerated()), id: \.offset) { i, url in
                        VStack(spacing: 6) {
                            if let image = NSImage(contentsOf: url) {
                                Image(nsImage: image).resizable().scaledToFit().frame(height: 130)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.omaBorder, lineWidth: 2))
                            }
                            Text("\(i + 1)").font(OmaStyle.bodyBold)
                        }
                    }
                }
                .padding(4)
            }
            HStack(spacing: 20) {
                OmaButton(title: "camera.more.another", systemImage: "plus.circle") { flow.anotherPage() }
                OmaButton(title: "camera.more.done", systemImage: "checkmark.circle", kind: .primary) { flow.finish() }
            }
        } footer: {
            BackFooter(flow: flow) { EmptyView() }
        }
    }
}

// MARK: Lesen

struct CameraReadingView: View {
    var flow: CameraFlow

    var body: some View {
        ScreenScaffold(title: "camera.reading.title") {
            Text(L("camera.reading.page", flow.readingPage, flow.pageCount)).font(OmaStyle.bodyBold)
            ProgressView().controlSize(.extraLarge)
            Text("camera.reading.hint").foregroundStyle(Color.omaSecondaryText)
        } footer: {
            HStack {
                OmaButton(title: "camera.reading.cancel", systemImage: "xmark.circle") { flow.back() }
                Spacer()
            }
        }
    }
}

struct CameraPartialView: View {
    var flow: CameraFlow
    var pages: [Int]

    var body: some View {
        ScreenScaffold(title: "camera.partial.title") {
            HStack(alignment: .top, spacing: 20) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 56)).foregroundStyle(Color.omaBorder)
                Text(L("camera.partial.text", pages.map(String.init).joined(separator: ", ")))
            }
            .omaCard()
        } footer: {
            BackFooter(flow: flow) {
                OmaButton(title: "camera.partial.again", systemImage: "arrow.counterclockwise") { flow.startOver() }
                OmaButton(title: "camera.partial.continue", systemImage: "chevron.right", kind: .primary) { flow.continueAnyway() }
            }
        }
    }
}

struct DiscardOverlay: View {
    var flow: CameraFlow

    var body: some View {
        OverlayCard {
            Text("camera.discard.title").font(OmaStyle.headingFont)
            Text("camera.discard.text")
            HStack(spacing: 20) {
                OmaButton(title: "camera.discard.no", systemImage: "arrow.uturn.backward", kind: .primary) {
                    flow.confirmDiscard = false
                }
                OmaButton(title: "camera.discard.yes", systemImage: "trash") { flow.discardAll() }
            }
        }
    }
}
