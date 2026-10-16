// Kamera-Schnittstelle für „Vom iPhone fotografieren“ und ihre echte Umsetzung über Continuity Camera.
//
// Weg: `AVCaptureDevice` vom Typ `.continuityCamera` (macOS 13+), eigene große Oberfläche mit Live-Bild und
// einem großen Knopf. Gewählt statt der „Von iPhone importieren“-Menüeinträge (NSServicesMenuRequestor):
// Die gibt es nur als kleines Systemmenü (Rechtsklick-ähnlich) und lassen sich nicht mit einem Knopf auslösen.
// Voraussetzung in Info.plist: `NSCameraUsageDescription` und `NSCameraUseContinuityCameraDeviceType = YES`
// (sonst meldet macOS das iPhone nur als „externe Kamera“). Siehe docs/phase5-helper.md.
import AVFoundation
import AppKit
import SwiftUI

enum CameraAuthorization: Equatable, Sendable { case allowed, denied }

enum CameraError: Error, Equatable { case noPhone, notRunning, captureFailed }

/// Was der Ablauf von der Kamera braucht. Die echte Kamera ist `ContinuityCamera`; Tests und Entwicklungshilfen
/// verwenden Attrappen.
@MainActor
protocol PhotoCamera: AnyObject {
    /// Fragt bei Bedarf nach der Erlaubnis.
    func authorization() async -> CameraAuthorization
    /// Ist ein iPhone (oder iPad) als Kamera in Reichweite?
    func phoneAvailable() -> Bool
    /// Startet das Live-Bild mit dem iPhone.
    func startSession() async throws
    func stopSession()
    /// Nimmt ein Foto auf (JPEG).
    func capture() async throws -> Data
    /// Für die Anzeige des Live-Bilds; nil bei Attrappen.
    var previewSession: AVCaptureSession? { get }
}

/// Echte Kamera: das iPhone als Webcam (Continuity Camera).
@MainActor
final class ContinuityCamera: NSObject, PhotoCamera {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var configured = false
    private var delegates: [Int64: PhotoDelegate] = [:]

    var previewSession: AVCaptureSession? { session }

    func authorization() async -> CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .allowed
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video) ? .allowed : .denied
        default: return .denied
        }
    }

    static func findPhone() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.continuityCamera, .external], mediaType: .video, position: .unspecified)
        return discovery.devices.first { d in
            d.deviceType == .continuityCamera || d.localizedName.contains("iPhone") || d.localizedName.contains("iPad")
        }
    }

    func phoneAvailable() -> Bool { Self.findPhone() != nil }

    func startSession() async throws {
        guard let device = Self.findPhone() else { throw CameraError.noPhone }
        if !configured {
            session.beginConfiguration()
            session.sessionPreset = .photo
            for input in session.inputs { session.removeInput(input) }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                throw CameraError.notRunning
            }
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            configured = true
        }
        let session = session
        // startRunning blockiert; nicht auf dem Hauptthread.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                if !session.isRunning { session.startRunning() }
                c.resume()
            }
        }
    }

    func stopSession() {
        let session = session
        DispatchQueue.global(qos: .utility).async { if session.isRunning { session.stopRunning() } }
        // Beim nächsten Start neu verbinden (das iPhone kann inzwischen ein anderes Gerät sein).
        for input in session.inputs { session.removeInput(input) }
        for out in session.outputs { session.removeOutput(out) }
        configured = false
    }

    func capture() async throws -> Data {
        guard session.isRunning else { throw CameraError.notRunning }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<Data, Error>) in
            let delegate = PhotoDelegate { [weak self] result in
                self?.delegates[settings.uniqueID] = nil
                c.resume(with: result)
            }
            delegates[settings.uniqueID] = delegate
            output.capturePhoto(with: settings, delegate: delegate)
        }
    }

    private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
        private let done: @MainActor (Result<Data, Error>) -> Void
        init(done: @escaping @MainActor (Result<Data, Error>) -> Void) { self.done = done }

        func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            let result: Result<Data, Error>
            if let data = photo.fileDataRepresentation(), error == nil { result = .success(data) }
            else { result = .failure(error ?? CameraError.captureFailed) }
            let done = done
            Task { @MainActor in done(result) }
        }
    }
}

/// Live-Bild der Kamera.
struct CameraPreview: NSViewRepresentable {
    var session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        if view.previewLayer.session !== session { view.previewLayer.session = session }
    }

    final class PreviewView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }
        required init?(coder: NSCoder) { fatalError() }
        override func makeBackingLayer() -> CALayer { AVCaptureVideoPreviewLayer() }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
