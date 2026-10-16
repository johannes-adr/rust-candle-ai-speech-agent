// Navigation für „Vom iPhone fotografieren“ und die dritte Karte auf dem Startbildschirm.
import CryptoKit
import DocumentImport
import Foundation
import SwiftUI
import TextPrep

extension AppModel {
    func startCamera() {
        let flow = CameraFlow(camera: makeCamera(), reader: { urls, progress in
            try await DocumentImporter().importPhotos(at: urls, languageHint: nil, progress: progress)
        })
        flow.onExit = { [weak self] in
            self?.camera = nil
            self?.goHome()
        }
        flow.onFailed = { [weak self] key in
            self?.camera = nil
            self?.screen = .problem(key)
        }
        flow.onFinished = { [weak self, weak flow] result, urls in
            guard let self else { return }
            self.finishPhotoImport(result: result, photoURLs: urls)
            flow?.finishAndClean()
            self.camera = nil
        }
        AppLog.info("camera", "Kamera-Ablauf gestartet")
        camera = flow
        screen = .camera
        flow.start()
    }

    /// Fotos sind gelesen: weiter zu Schritt 2. Quelle ist die Summe der Bilder (für „schon angefangen“).
    func finishPhotoImport(result: ImportResult, photoURLs: [URL]) {
        var hasher = SHA256()
        for url in photoURLs { if let d = try? Data(contentsOf: url) { hasher.update(data: d) } }
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let first: String = {
            for block in result.document.blocks {
                switch block {
                case .heading(_, let t): return t
                case .paragraph(let p): return p
                }
            }
            return ""
        }()
        let title = first.isEmpty ? L("camera.title.fallback") : Self.title(fromText: first)
        AppLog.info("camera", "Fotos gelesen: \(photoURLs.count) Seiten, \(result.rotatedPages.count) gedreht")
        makeDraft(
            title: title, document: result.document, sourceHash: hash, sourceKind: "image",
            sourceData: nil, sourceExtension: nil)
    }
}

/// Dritte große Karte auf dem Startbildschirm: breit, ein Knopf.
struct CameraCard: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 24) {
                Image(systemName: "camera.viewfinder")
                    .font(.system(size: 56)).foregroundStyle(Color.omaBorder).frame(width: 90)
                VStack(alignment: .leading, spacing: 6) {
                    Text("camera.card.title").font(.system(size: 30, weight: .bold))
                    Text("camera.card.sub").foregroundStyle(Color.omaSecondaryText)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 24, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .omaCard()
        }
        .buttonStyle(.plain)
    }
}
