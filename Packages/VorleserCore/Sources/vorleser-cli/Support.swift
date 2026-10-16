// Kleine Hilfen der Kommandozeile: Ausgabe auf stderr, Zeitformat, Speicherspitze.
import Darwin
import Foundation
import Speech

func err(_ s: String, terminator: String = "\n") {
    FileHandle.standardError.write(Data((s + terminator).utf8))
}

func clock(_ seconds: Double?) -> String {
    guard let s = seconds, s.isFinite else { return "--:--" }
    let t = Int(s.rounded())
    return t >= 3600
        ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
        : String(format: "%02d:%02d", t / 60, t % 60)
}

func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

/// phys_footprint jetzt und Spitze seit Prozessstart (Ledger), in GB.
func footprintGB() -> (now: Double, peak: Double) {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    return (Double(info.phys_footprint) / 1e9, Double(info.ledger_phys_footprint_peak) / 1e9)
}

struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ d: String) { description = d }
}

/// Deutsche Kurznamen der Stile, damit `--style ruhig` geht.
func normalizedStyle(_ s: String) -> String {
    switch s.lowercased() {
    case "ruhig": "calm"
    case "froh", "fröhlich", "froehlich": "happy"
    case "märchen", "maerchen": "fairytale"
    case "sachlich": "factual"
    default: s.lowercased()
    }
}

func locateVoices(_ override: String?) throws -> VoiceStore {
    if let override {
        let store = VoiceStore(directory: URL(fileURLWithPath: override, isDirectory: true))
        guard !store.allPresets.isEmpty else { throw CLIError("Keine presets.json in \(override)") }
        return store
    }
    guard let store = VoiceStore.locateDefault(), !store.allPresets.isEmpty else {
        throw CLIError("Resources/Voices/presets.json nicht gefunden (--voices-dir oder VORLESER_VOICES_DIR setzen).")
    }
    return store
}
