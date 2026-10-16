// Ist die App eingerichtet? Entscheidet beim Start zwischen „Start“ (①), dem Hinweis für die Oma
// („noch nicht eingerichtet“) und dem Assistenten für den Helfer. Eine Instanz für die ganze App.
import AppKit
import Foundation
import ModelSetup
import Observation
import VorleserSpeech

@MainActor
@Observable
final class SetupState {
    static let shared = SetupState()

    /// UserDefaults-Schlüssel der Qualität (Bit-Tiefe des Hauptmodells, 4 oder 8). Die Helfer-Einstellungen
    /// schreiben ihn; ohne Eintrag gilt 4 (PLAN.md §4.6). Der Assistent liest ihn nur.
    nonisolated static let bitsDefaultsKey = "modelBits"

    private(set) var baseStatus: ModelStatus = .missing
    private(set) var designStatus: ModelStatus = .missing
    /// Soll der Assistent den Bildschirm übernehmen (Knopf „Einrichten“ bzw. „Einrichtung erneut prüfen“)?
    var showAssistant = false

    private(set) var service: any SetupServicing
    private var demo: String?
    private let defaults: UserDefaults

    init(service: any SetupServicing = LiveSetupService(), defaults: UserDefaults = .standard, observeActivation: Bool = true) {
        self.service = service
        self.defaults = defaults
        refresh()
        #if DEBUG
        applyDebugDemo()
        #endif
        if observeActivation {
            // Der Helfer kann die Daten auch im Terminal einrichten; beim Zurückkehren neu schauen.
            // Die Instanz lebt so lange wie die App; der Beobachter wird nie entfernt.
            _ = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    var bits: ModelBits {
        let raw = defaults.integer(forKey: Self.bitsDefaultsKey)
        return ModelBits(rawValue: raw) ?? .four
    }

    /// Ohne fertiges Hauptmodell kann die App nichts vorlesen.
    var needsSetup: Bool {
        #if DEBUG
        let env = ProcessInfo.processInfo.environment
        if demo == nil, env["VORLESER_PREVIEW"] == "1" || env["VORLESER_SKIP_SETUP"] == "1" { return false }
        #endif
        return !baseStatus.isReady
    }

    func refresh() {
        if demo != nil { return }
        let manifests = service.manifests(bits: bits, includeVoiceDesign: true)
        baseStatus = manifests?.first.map(service.status(of:)) ?? .missing
        designStatus = manifests.flatMap { $0.count > 1 ? service.status(of: $0[1]) : nil } ?? .missing
    }

    /// „Einrichtung erneut prüfen“ (Helfer-Einstellungen): öffnet den Assistenten, auch wenn alles bereit ist.
    func reopenAssistant() { showAssistant = true }

    #if DEBUG
    /// VORLESER_DEMO=setup-welcome|setup-plan|setup-loading|setup-problem|setup-space|setup-checking|setup-done|setup-helper|notsetup
    /// zeigt den Bildschirm mit einem Dienst ohne Netz (für Bildschirmfotos).
    private func applyDebugDemo() {
        guard let demo = ProcessInfo.processInfo.environment["VORLESER_DEMO"], demo.hasPrefix("setup-") || demo == "notsetup" else { return }
        self.demo = demo
        service = DemoSetupService(demo: demo)
        baseStatus = .missing
        showAssistant = demo != "notsetup"
    }
    #endif
}
