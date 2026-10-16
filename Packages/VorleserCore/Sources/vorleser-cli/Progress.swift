// Fortschrittsanzeige auf stderr: eine Zeile, die sich bei einem Terminal selbst überschreibt.
import Darwin
import Foundation
import Pipeline

final class ProgressPrinter {
    private let tty = isatty(STDERR_FILENO) != 0
    private var lineOpen = false

    func handle(_ event: SynthesisEvent) {
        switch event {
        case let .stage(s):
            switch s {
            case .importing: say("Dokument lesen …")
            case .detectingLanguage: break
            case .planning: say("Abschnitte planen …")
            case .loadingModel: say("Modell laden …")
            case .preparingVoice: say("Stimme vorbereiten …")
            case .synthesizing: break
            case .exporting: say("MP3 schreiben …")
            }
        case let .projectReady(id, resumed, total, done, language):
            say("Projekt \(id.uuidString.prefix(8)) (\(language.rawValue)), \(total) Abschnitte"
                + (resumed ? ", fortgesetzt: \(done) schon fertig" : ""))
        case let .chunkDone(p):
            let page = p.currentPage.map { " Seite \($0)/\(p.totalPages ?? $0)" } ?? ""
            var line = String(format: "[%3d/%d]%@ %3.0f %%  Rest %@  RTF %.2f", p.chunksDone, p.chunksTotal, page,
                              p.fraction * 100, clock(p.remainingSeconds), p.realTimeFactor)
            if p.attempts > 1 { line += "  (Versuch \(p.attempts))" }
            if p.isSuspicious { line += "  VERDACHT" }
            update(line)
        case let .suspicious(s):
            say("! Abschnitt \(s.chunkIndex) Versuch \(s.attempt + 1): \(s.issues.map(\.rawValue).joined(separator: ", "))"
                + (s.willRetry ? " → neuer Seed" : " → behalten und markiert"))
        case let .coolingDown(sec): say("Mac ist warm, Pause \(Int(sec)) s …")
        case .paused: say("Pausiert.")
        case .resumed: say("Weiter.")
        case .exporting, .finished, .stopped, .failed: break
        }
    }

    func finishLine() {
        if lineOpen { err(""); lineOpen = false }
    }

    private func say(_ s: String) {
        finishLine()
        err(s)
    }

    private func update(_ s: String) {
        if tty {
            err("\r\u{1B}[2K" + s, terminator: "")
            lineOpen = true
        } else {
            err(s)
        }
    }
}
