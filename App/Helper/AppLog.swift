// Protokollieren: os.Logger (Subsystem de.vorleser.app, sichtbar in der Konsole) und zusätzlich eine
// Textdatei in ~/Library/Logs/Vorleser, die der Helfer im Einstellungsfenster öffnen kann.
// Nie Dokumenttext protokollieren, nur Ereignisse.
import Foundation
import OSLog
import Projects

enum AppLog {
    static let subsystem = "de.vorleser.app"
    static let file = EventLog()

    private static func logger(_ category: String) -> Logger { Logger(subsystem: subsystem, category: category) }

    static func info(_ category: String, _ message: String) {
        logger(category).info("\(message, privacy: .public)")
        file.write(.info, category, message)
    }

    static func warning(_ category: String, _ message: String) {
        logger(category).warning("\(message, privacy: .public)")
        file.write(.warning, category, message)
    }

    static func error(_ category: String, _ message: String) {
        logger(category).error("\(message, privacy: .public)")
        file.write(.error, category, message)
    }
}
