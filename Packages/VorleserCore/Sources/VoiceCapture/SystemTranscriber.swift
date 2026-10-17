// Spracherkennung auf dem Gerät: bevorzugt SpeechAnalyzer/SpeechTranscriber (macOS 26),
// sonst SFSpeechRecognizer (nur on-device). Lädt von sich aus nichts herunter: Sind die
// Sprachdaten nicht installiert, kommt `.unavailable(.assetsNotInstalled)` zurück, und die
// Prüfung bleibt bei Dauer und Pegel. Installieren ist eine eigene, ausdrückliche Aktion
// (`installAssets(for:)`, nur für den Helfer).
import AVFoundation
import Foundation
import Speech
import TextPrep

public enum TranscriptionUnavailable: String, Sendable, Equatable, Codable {
    /// Weder SpeechTranscriber noch SFSpeechRecognizer kennen die Sprache.
    case languageNotSupported
    /// Unterstützt, aber die Daten sind nicht installiert (kein ungefragter Download).
    case assetsNotInstalled
    /// SFSpeechRecognizer ohne Erlaubnis der Nutzerin.
    case notAuthorized
    case failed
}

public enum TranscriptionResult: Sendable, Equatable {
    case text(String, engine: String)
    case unavailable(TranscriptionUnavailable)
}

public protocol SpeechTranscribing: Sendable {
    func transcribe(fileURL: URL, language: Language) async -> TranscriptionResult
}

/// Was für eine Sprache möglich ist (für Helfer-Hinweise).
public enum TranscriberStatus: Sendable, Equatable {
    case speechTranscriberInstalled(locale: String)
    case speechTranscriberNeedsDownload(locale: String)
    case legacyOnDevice(locale: String)
    case unsupported
}

public struct SystemTranscriber: SpeechTranscribing {
    public init() {}

    /// Bevorzugte Region je Sprache, falls es mehrere Gebietsschemata gibt.
    static func preferredLocales(for language: Language) -> [String] {
        switch language {
        case .de: ["de-DE", "de-AT", "de-CH"]
        case .pt: ["pt-PT", "pt-BR"]
        case .en: ["en-US", "en-GB", "en-AU"]
        case .es: ["es-ES", "es-MX", "es-US"]
        case .fr: ["fr-FR", "fr-CA"]
        case .it: ["it-IT"]
        case .ru: ["ru-RU"]
        case .zh: ["zh-CN", "zh-TW", "zh-HK"]
        case .ja: ["ja-JP"]
        case .ko: ["ko-KR"]
        }
    }

    /// Erstes Gebietsschema aus `available`, das zur Sprache passt (bevorzugte Region zuerst).
    static func pick(_ language: Language, from available: [Locale]) -> Locale? {
        let ids = available.map { $0.identifier(.bcp47) }
        for want in preferredLocales(for: language) {
            if let i = ids.firstIndex(of: want) { return available[i] }
        }
        return available.first { $0.language.languageCode?.identifier == language.rawValue }
    }

    // MARK: Status

    public func status(for language: Language) async -> TranscriberStatus {
        if SpeechTranscriber.isAvailable {
            let installed = await SpeechTranscriber.installedLocales
            if let l = Self.pick(language, from: installed) { return .speechTranscriberInstalled(locale: l.identifier(.bcp47)) }
            let supported = await SpeechTranscriber.supportedLocales
            if let l = Self.pick(language, from: supported) { return .speechTranscriberNeedsDownload(locale: l.identifier(.bcp47)) }
        }
        if let l = Self.legacyLocale(for: language) { return .legacyOnDevice(locale: l.identifier) }
        return .unsupported
    }

    /// Lädt die Sprachdaten für SpeechTranscriber (große Datei, nur auf ausdrückliche Anfrage).
    /// - Returns: `true`, wenn danach installiert.
    public func installAssets(for language: Language) async throws -> Bool {
        guard SpeechTranscriber.isAvailable else { return false }
        let supported = await SpeechTranscriber.supportedLocales
        guard let locale = Self.pick(language, from: supported) else { return false }
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
        let installed = await SpeechTranscriber.installedLocales
        return Self.pick(language, from: installed) != nil
    }

    // MARK: Erkennen

    public func transcribe(fileURL: URL, language: Language) async -> TranscriptionResult {
        var firstFailure: TranscriptionUnavailable = .languageNotSupported
        if SpeechTranscriber.isAvailable {
            let installed = await SpeechTranscriber.installedLocales
            if let locale = Self.pick(language, from: installed) {
                if let text = try? await Self.runSpeechTranscriber(fileURL: fileURL, locale: locale) {
                    return .text(text, engine: "SpeechTranscriber \(locale.identifier(.bcp47))")
                }
                firstFailure = .failed
            } else if Self.pick(language, from: await SpeechTranscriber.supportedLocales) != nil {
                firstFailure = .assetsNotInstalled
            }
        }
        // Zweiter Weg (z. B. Russisch zum Start von macOS 26): SFSpeechRecognizer, nur on-device.
        switch await Self.runLegacy(fileURL: fileURL, language: language) {
        case .text(let t, let engine): return .text(t, engine: engine)
        case .unavailable(.languageNotSupported): return .unavailable(firstFailure)
        case .unavailable(let why):
            return .unavailable(firstFailure == .assetsNotInstalled ? .assetsNotInstalled : why)
        }
    }

    private static func runSpeechTranscriber(fileURL: URL, locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: fileURL)
        let collector = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                if !text.isEmpty { text += " " }
                text += String(result.text.characters)
            }
            return text
        }
        do {
            try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            return try await collector.value
        } catch {
            collector.cancel()
            throw error
        }
    }

    // MARK: SFSpeechRecognizer

    static func legacyLocale(for language: Language) -> Locale? {
        let supported = SFSpeechRecognizer.supportedLocales()
        return pick(language, from: Array(supported))
    }

    /// Erlaubnis einholen (Systemdialog). Nur die App ruft das auf, nie die Kommandozeile.
    public static func requestLegacyAuthorization() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }

    /// Noch nicht gefragt? Dann kann die App `requestLegacyAuthorization()` aufrufen (nur wenn nötig).
    public static var legacyAuthorizationNotDetermined: Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined
    }

    private static func runLegacy(fileURL: URL, language: Language) async -> TranscriptionResult {
        guard let locale = legacyLocale(for: language), let recognizer = SFSpeechRecognizer(locale: locale) else {
            return .unavailable(.languageNotSupported)
        }
        guard recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else { return .unavailable(.languageNotSupported) }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else { return .unavailable(.notAuthorized) }
        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return await withCheckedContinuation { (cont: CheckedContinuation<TranscriptionResult, Never>) in
            let once = OnceFlag()
            recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal {
                    if once.take() { cont.resume(returning: .text(result.bestTranscription.formattedString, engine: "SFSpeechRecognizer \(locale.identifier)")) }
                } else if error != nil {
                    if once.take() { cont.resume(returning: .unavailable(.failed)) }
                }
            }
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var used = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
    }
}
