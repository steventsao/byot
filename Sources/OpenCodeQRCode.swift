import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// Reads and draws QR codes with Core Image, for pairing codes picked from
/// Photos (the camera path uses AVFoundation metadata instead).
enum OpenCodeQRCode {
    static func messages(in image: CIImage) -> [String] {
        let detector = CIDetector(
            ofType: CIDetectorTypeQRCode,
            context: nil,
            options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
        )
        return (detector?.features(in: image) ?? [])
            .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }

    static func messages(inImageData data: Data) -> [String] {
        guard let image = UIImage(data: data), let cgImage = image.cgImage else {
            return CIImage(data: data).map(messages(in:)) ?? []
        }
        return messages(in: CIImage(cgImage: cgImage))
    }

    /// A crisp QR image, `scale` pixels per module.
    static func image(for message: String, scale: CGFloat = 8) -> CIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(message.utf8)
        filter.correctionLevel = "M"
        return filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    }
}

enum OpenCodeCameraAccess: Equatable, Sendable {
    case authorized
    case notDetermined
    case denied
    case restricted
    case unavailable

    static var current: OpenCodeCameraAccess {
        guard AVCaptureDevice.default(for: .video) != nil else { return .unavailable }
        return from(AVCaptureDevice.authorizationStatus(for: .video))
    }

    static func from(_ status: AVAuthorizationStatus) -> OpenCodeCameraAccess {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .denied
        }
    }
}

/// Ignores the stream of repeated metadata callbacks for a code that was
/// already handled, so one bad code shows one error and one good code
/// fills the form once.
struct OpenCodePairingScanGate: Sendable {
    private var lastCode: String?
    private(set) var isFinished = false

    mutating func shouldHandle(_ code: String) -> Bool {
        guard !isFinished, code != lastCode else { return false }
        lastCode = code
        return true
    }

    mutating func finish() { isFinished = true }

    mutating func reset() {
        lastCode = nil
        isFinished = false
    }
}
