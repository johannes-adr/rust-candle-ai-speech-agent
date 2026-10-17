// Kamera-Attrappe für Tests und Bildschirmfotos (nur Debug). Liefert ein vorgegebenes Bild statt eines iPhones.
#if DEBUG
import AVFoundation
import Foundation

@MainActor
final class DemoCamera: PhotoCamera {
    var allowed = true
    var phone: Bool
    /// Bilder, die nacheinander „aufgenommen“ werden (Dateien); danach wird das letzte wiederholt.
    var photos: [URL]
    private(set) var started = false
    private(set) var captures = 0
    var failNextCapture = false

    init(phone: Bool = true, photos: [URL] = []) {
        self.phone = phone
        self.photos = photos
    }

    var previewSession: AVCaptureSession? { nil }

    func authorization() async -> CameraAuthorization { allowed ? .allowed : .denied }
    func phoneAvailable() -> Bool { phone }

    func startSession() async throws {
        guard phone else { throw CameraError.noPhone }
        started = true
    }

    func stopSession() { started = false }

    func capture() async throws -> Data {
        guard started else { throw CameraError.notRunning }
        if failNextCapture { failNextCapture = false; throw CameraError.captureFailed }
        guard !photos.isEmpty else { throw CameraError.captureFailed }
        defer { captures += 1 }
        return try Data(contentsOf: photos[min(captures, photos.count - 1)])
    }
}
#endif
