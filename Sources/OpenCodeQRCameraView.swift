import AVFoundation
import SwiftUI
import UIKit

/// Live camera preview that reports QR code strings. Capture runs on a
/// private queue; metadata arrives on the main queue.
struct OpenCodeQRCameraView: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onFailure: () -> Void

    func makeUIViewController(context: Context) -> OpenCodeQRCameraController {
        let controller = OpenCodeQRCameraController()
        controller.onCode = onCode
        controller.onFailure = onFailure
        return controller
    }

    func updateUIViewController(_ controller: OpenCodeQRCameraController, context: Context) {
        controller.onCode = onCode
        controller.onFailure = onFailure
    }

    static func dismantleUIViewController(_ controller: OpenCodeQRCameraController, coordinator: ()) {
        controller.stopRunning()
    }
}

final class OpenCodeQRCameraController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onFailure: (() -> Void)?

    private final class SessionBox: @unchecked Sendable {
        let session = AVCaptureSession()
    }

    private let capture = SessionBox()
    private let sessionQueue = DispatchQueue(label: "app.byot.pairing.camera")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.isAccessibilityElement = true
        view.accessibilityLabel = String(localized: "Camera viewfinder")
        view.accessibilityHint = String(localized: "Point the camera at the pairing code on your computer.")
        guard configure() else {
            onFailure?()
            return
        }
        let preview = AVCaptureVideoPreviewLayer(session: capture.session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        previewLayer = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        updatePreviewRotation()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startRunning()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        stopRunning()
    }

    func startRunning() {
        guard isConfigured else { return }
        sessionQueue.async { [capture] in
            if !capture.session.isRunning { capture.session.startRunning() }
        }
    }

    func stopRunning() {
        sessionQueue.async { [capture] in
            if capture.session.isRunning { capture.session.stopRunning() }
        }
    }

    nonisolated func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        let codes = metadataObjects.compactMap { ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }
        guard !codes.isEmpty else { return }
        MainActor.assumeIsolated {
            codes.forEach { onCode?($0) }
        }
    }

    private func configure() -> Bool {
        let session = capture.session
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return false }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        let output = AVCaptureMetadataOutput()
        guard session.canAddInput(input), session.canAddOutput(output) else { return false }
        session.addInput(input)
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else { return false }
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        isConfigured = true
        return true
    }

    /// Keeps the preview upright in every interface orientation the app supports.
    private func updatePreviewRotation() {
        guard let connection = previewLayer?.connection else { return }
        let angle: CGFloat = switch view.window?.windowScene?.interfaceOrientation {
        case .landscapeLeft: 180
        case .landscapeRight: 0
        case .portraitUpsideDown: 270
        default: 90
        }
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }
}
