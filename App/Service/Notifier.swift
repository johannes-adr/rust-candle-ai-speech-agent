// Mitteilung „Ihr Hörbuch ist fertig“, wenn die App gerade nicht vorne ist.
import AppKit
import Foundation
import UserNotifications

@MainActor
enum Notifier {
    /// Nur in einer richtigen App (nicht in Kommandozeilen-Hosts).
    private static var available: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    /// Fragt einmal um Erlaubnis; später passiert nichts mehr sichtbar.
    static func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func postFinished(title: String) {
        guard available, !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "notify.done.title")
        content.body = L("notify.done.body", title)
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
