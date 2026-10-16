// Start der App und Entwicklungshilfen (nur in Debug-Builds wirksam).
import AppKit
import Foundation

extension AppModel {
    /// Attrappe aktiv? Dann zeigt die Kopfzeile einen deutlichen Hinweis.
    var isPreview: Bool { service is PreviewAudiobookService }

    static func makeForLaunch() -> AppModel {
        #if DEBUG
        // Entwicklung: eigener Datenordner, damit weder Musik noch echte Einstellungen berührt werden.
        if let dir = ProcessInfo.processInfo.environment["VORLESER_DATA_DIR"] {
            let base = URL(fileURLWithPath: dir, isDirectory: true)
            let settings = AppSettings(defaults: UserDefaults(suiteName: "de.vorleser.debug") ?? .standard)
            settings.outputDirectory = base.appending(path: "Output", directoryHint: .isDirectory)
            return AppModel(settings: settings, storeRoot: base.appending(path: "Projects", directoryHint: .isDirectory))
        }
        #endif
        return AppModel()
    }
}

#if DEBUG
/// Springt für Screenshots direkt zu einem Bildschirm:
/// VORLESER_DEMO=start|text|voice|voice-empty|language|working|done|problem|convert, VORLESER_SNAPSHOT=<png>,
/// VORLESER_APPEARANCE=dark|light, VORLESER_PREVIEW_SECONDS=<Sekunden Simulation>.
@MainActor
enum DebugLaunch {
    private static var started = false

    static func runIfRequested(_ model: AppModel) async {
        let env = ProcessInfo.processInfo.environment
        guard let demo = env["VORLESER_DEMO"], !started else { return }
        started = true
        switch env["VORLESER_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        try? await Task.sleep(for: .seconds(1))

        // Es gibt keine fertigen Stimmen: in der Vorschau eine Attrappen-Stimme anlegen (außer „voice-empty“).
        if env["VORLESER_PREVIEW"] == "1", demo != "voice-empty" { seedDemoVoice(model) }

        switch demo {
        case "start":
            model.typedText = sample(paragraphs: 3)
            model.submitTypedText()
            model.startWork()
            await waitUntil { model.screen == .done }
            model.goHome()
        case "convert":
            // Ohne Klicken umwandeln (echte Sprachausgabe): VORLESER_TEXT_FILE=<txt> (sonst Beispiel),
            // VORLESER_RESULT_FILE=<txt> bekommt Pfad, Dauer und Zeiten; danach beendet sich die App.
            let text = env["VORLESER_TEXT_FILE"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? sample(paragraphs: 1)
            model.typedText = text
            model.submitTypedText()
            let began = Date()
            model.startWork()
            await waitUntil(seconds: 900) { model.screen == .done || { if case .problem = model.screen { true } else { false } }() }
            var lines = ["screen=\(model.screen)", "seconds=\(Date().timeIntervalSince(began))",
                         "instant=\(model.draft?.isShort ?? false)"]
            if let r = model.result { lines += ["file=\(r.fileURL.path)", "duration=\(r.durationSeconds)", "title=\(r.title)"] }
            if let out = env["VORLESER_RESULT_FILE"] { try? lines.joined(separator: "\n").write(toFile: out, atomically: true, encoding: .utf8) }
        case "text":
            model.typedText = "Liebe Frau Meier,"
            model.screen = .typeText
        case "voice", "voice-empty", "language":
            model.typedText = sample(paragraphs: 3)
            model.submitTypedText()
            model.showLanguagePicker = demo == "language"
        case "describe", "describeWorking", "describeChoose", "describeName":
            // Stimme beschreiben (Phase 4) mit der Attrappe des Dienstes (VORLESER_PREVIEW=1).
            model.typedText = sample(paragraphs: 3)
            model.submitTypedText()
            model.startDescribe()
            if demo != "describe" {
                model.describe?.wishText = "ruhig und warm, wie eine Großmutter"
                model.describe?.tryVoices()
                if demo == "describeWorking" { try? await Task.sleep(for: .milliseconds(1500)) } else {
                    await waitUntil { model.describe?.step == .choose }
                    if demo == "describeName", let p = model.describe?.proposals.first { model.describe?.take(p) }
                }
            }
        case "working":
            model.typedText = sample(paragraphs: 40)
            model.submitTypedText()
            model.startWork()
            await waitUntil { model.phase == .working && model.progress.fraction > 0.3 }
        case "done":
            model.typedText = sample(paragraphs: 3)
            model.submitTypedText()
            model.startWork()
            await waitUntil { model.screen == .done }
        case "problem":
            model.screen = .problem("problem.noText")
        default:
            // Helfer-Einstellungen und Kamera-Ablauf (App/Helper/DebugDemos.swift)
            if await HelperDemos.run(demo, model) { return }
        }

        try? await Task.sleep(for: .seconds(1))
        if let path = env["VORLESER_SNAPSHOT"] {
            snapshot(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    private static func seedDemoVoice(_ model: AppModel) {
        guard model.library.voices(for: .de).isEmpty else { return }
        let tone = (0..<24_000 * 12).map { Float(sin(Double($0) / 24_000 * 2 * .pi * 180)) * 0.2 }
        _ = try? model.library.store.custom.save(
            samples: tone, sampleRate: 24_000, transcript: "Lesetext.", name: "Demo-Stimme", language: .de,
            consent: true, source: "recording", transcriptSource: "reading")
    }

    private static func waitUntil(seconds: Int = 60, _ condition: @MainActor () -> Bool) async {
        for _ in 0..<(seconds * 10) {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    static func sample(paragraphs: Int) -> String {
        let p = "Sehr geehrte Frau Meier, vielen Dank für Ihr Schreiben vom 3.5.2024. Wir haben Ihren Antrag geprüft und freuen uns, Ihnen mitzuteilen, dass die Kosten in Höhe von 12,50 € übernommen werden. Bitte melden Sie sich bei Rückfragen jederzeit bei uns."
        return (0..<paragraphs).map { _ in p }.joined(separator: "\n\n")
    }

    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#else
@MainActor
enum DebugLaunch {
    static func runIfRequested(_ model: AppModel) async {}
}
#endif
