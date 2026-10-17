// Kleine Hilfen der Kommandozeile: Ausgabe auf stderr, Zeitformat, Speicherspitze.
import Darwin
import Foundation
import TextPrep
import VorleserSpeech

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

/// Eigene Stimmen (Standard: Application Support/Vorleser/Voices, oder `--voices-dir`).
func locateVoices(_ override: String?) -> VoiceStore {
    override.map { VoiceStore(customDirectory: URL(fileURLWithPath: $0, isDirectory: true)) } ?? VoiceStore()
}

/// Fester Lesetext je Sprache (ca. 10–12 s) aus `Resources/ReadAloud`: `--read-aloud-dir`, sonst vom
/// Arbeitsordner und Programmpfad aufwärts gesucht.
func readAloudText(_ language: Language, override: String?) throws -> String {
    var dirs: [URL] = override.map { [URL(fileURLWithPath: $0, isDirectory: true)] } ?? []
    if override == nil {
        var starts = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let exe = Bundle.main.executableURL { starts.append(exe.deletingLastPathComponent()) }
        for start in starts {
            var dir = start
            for _ in 0..<10 {
                dirs.append(dir.appending(path: "Resources/ReadAloud", directoryHint: .isDirectory))
                dir = dir.deletingLastPathComponent()
            }
        }
    }
    for dir in dirs {
        if let s = try? String(contentsOf: dir.appending(path: "\(language.rawValue).txt"), encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    throw CLIError("Lesetext für \(language.rawValue) nicht gefunden (--read-aloud-dir setzen).")
}
