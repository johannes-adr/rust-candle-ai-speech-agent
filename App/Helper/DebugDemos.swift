// Entwicklungshilfen für Bildschirmfotos der Helfer-Einstellungen und des Kamera-Ablaufs (nur Debug).
// VORLESER_DEMO=settings-helper|settings-folder|settings-quality|settings-voices|settings-books|settings-logs,
// camera-waiting|camera-denied|camera-shoot|camera-review|camera-more|home. Siehe docs/phase5-helper.md.
// Kamera-Bild: VORLESER_DEMO_PHOTO=<jpg> (z. B. Packages/VorleserCore/Tests/DocumentImportTests/Fixtures/foto.jpg).
#if DEBUG
import AppKit
import AudioOut
import Foundation
import Projects
import SwiftUI
import TextPrep
import VorleserSpeech

@MainActor
enum HelperDemos {
    /// true = behandelt (Bildschirmfoto und Beenden inklusive).
    static func run(_ demo: String, _ model: AppModel) async -> Bool {
        let env = ProcessInfo.processInfo.environment
        if demo.hasPrefix("settings-") {
            let name = String(demo.dropFirst("settings-".count))
            guard let tab = HelperTab(rawValue: name) else { return false }
            await seed(model)
            HelperNavigation.shared.tab = tab
            if tab == .helper, model.settings.helperName.isEmpty {
                model.settings.helperName = "Johannes"
                model.settings.helperPhone = "0151 234 5678"
            }
            // Eigenes Fenster mit demselben Inhalt wie das Einstellungsfenster (das echte lässt sich nicht
            // zuverlässig per Code öffnen).
            let window = NSWindow(
                contentRect: NSRect(x: 100, y: 100, width: 740, height: 640), styleMask: [.titled, .closable],
                backing: .buffered, defer: false)
            window.contentViewController = NSHostingController(rootView: SettingsView().environment(model))
            window.title = "Einstellungen"
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(2))
            if let path = env["VORLESER_SNAPSHOT"] {
                snapshot(window, to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
            return true
        }
        guard demo.hasPrefix("camera-") || demo == "home" else { return false }
        if demo == "home" {
            await seed(model)
            model.goHome()
        } else {
            let photo = env["VORLESER_DEMO_PHOTO"].map { URL(fileURLWithPath: $0) }
            let camera = DemoCamera(phone: demo != "camera-waiting", photos: photo.map { [$0] } ?? [])
            camera.allowed = demo != "camera-denied"
            model.makeCamera = { camera }
            model.startCamera()
            guard let flow = model.camera else { return false }
            flow.searchInterval = .milliseconds(200)
            switch demo {
            case "camera-review", "camera-more":
                await wait { flow.step == .shoot }
                flow.takePhoto()
                await wait { flow.step == .review }
                if demo == "camera-more" {
                    flow.acceptLast()
                    flow.anotherPage()
                    flow.takePhoto()
                    await wait { flow.pageCount == 2 }
                    flow.acceptLast()
                }
            case "camera-shoot":
                await wait { flow.step == .shoot }
            default:
                try? await Task.sleep(for: .seconds(1))
            }
        }
        try? await Task.sleep(for: .seconds(1))
        if let path = env["VORLESER_SNAPSHOT"] {
            snapshotMain(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
        return true
    }

    private static func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: Beispieldaten (im Debug-Datenordner)

    /// Zwei fertige Hörbücher (eines mit Verdachtsfall), ein unfertiges mit Fehler, zwei eigene Stimmen.
    static func seed(_ model: AppModel) async {
        let store = model.store
        guard await store.list().isEmpty else { return }
        func chunks(_ texts: [String]) -> [Chunk] {
            texts.enumerated().map { Chunk(index: $0 + 1, text: $1, spokenText: $1, kind: .sentence, chapter: 0) }
        }
        let tone = (0..<24_000 * 12).map { Float(sin(Double($0) / 24_000 * 2 * .pi * 180)) * 0.2 }
        func make(_ title: String, _ texts: [String], finished: Bool) async -> Project? {
            guard let p = try? await store.create(
                title: title, sourceHash: UUID().uuidString, sourceKind: "pdf", sourceData: Data(repeating: 1, count: 80_000),
                sourceExtension: "pdf", language: .de, voiceID: "own-demo", chunks: chunks(texts)) else { return nil }
            for i in 1...texts.count {
                _ = try? store.chunkStore(for: p.id).write(tone, sampleRate: 24_000, index: i)
                _ = try? await store.markChunkDone(id: p.id, chunkIndex: i, duration: 12)
            }
            if finished {
                try? await store.setState(.finished, id: p.id)
                try? FileManager.default.createDirectory(at: store.outputDirectory, withIntermediateDirectories: true)
                try? Data(repeating: 9, count: 1_400_000).write(to: store.outputURL(title: title))
            }
            return try? await store.load(id: p.id)
        }
        _ = await make("Brief Krankenkasse", ["Sehr geehrte Frau Meier, vielen Dank für Ihr Schreiben.", "Wir haben Ihren Antrag geprüft.", "Die Kosten werden übernommen."], finished: true)
        if let p = await make("Rotkäppchen", ["Es war einmal ein kleines süßes Mädchen.", "Wer einmal hinaufging, der kam nie wieder.", "Nun komm, Großmutter, und iss."], finished: true) {
            let json = """
            {"sampleRate":24000,"originalDurationSeconds":1.2,"trimmedDurationSeconds":1.2,"leadingSilenceSeconds":0,
             "trailingSilenceSeconds":0,"nonFiniteCount":0,"clippingFraction":0,"peakDBFS":-3,"rmsDBFS":-20,
             "expectedDurationSeconds":6,"durationRatio":0.2,"issues":["tooShort"]}
            """
            if let qc = try? JSONDecoder().decode(ChunkQCReport.self, from: Data(json.utf8)) {
                _ = try? await store.markChunkSuspicious(id: p.id, chunkIndex: 2, duration: 1.2, qc: qc, attemptsUsed: 3)
            }
        }
        if let p = await make("Zeitung: Gemeinderat beschließt Radweg", ["Der Gemeinderat hat am Montagabend mit großer Mehrheit den Bau beschlossen.", "Die Kosten betragen 19,99 Euro je Meter."], finished: false) {
            _ = try? await store.markChunkFailed(id: p.id, chunkIndex: 2, error: "Nicht-endlicher Wert im Signal (NaN)")
        }
        do {
            let custom = model.library.store.custom
            _ = try? custom.save(
                samples: tone, sampleRate: 24_000, transcript: "Lesetext.", name: "Omas Stimme", language: .de,
                consent: true, source: "recording", transcriptSource: "reading")
            _ = try? custom.saveDesigned(
                samples: tone, sampleRate: 24_000, referenceText: "Lesetext.", name: "Warm und ruhig", language: .de,
                wish: "ruhig und warm, wie eine Großmutter", prompt: nil, seed: 1)
        }
        await model.refreshProjects()
        AppLog.info("demo", "Beispieldaten angelegt")
    }

    // MARK: Bildschirmfotos

    private static func snapshotMain(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 900 }) else { return }
        snapshot(window, to: url)
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
