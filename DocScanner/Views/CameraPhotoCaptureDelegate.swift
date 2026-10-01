import AVFoundation
import UIKit

/// 1 件の撮影について処理結果と最終完了をまとめるデリゲート。
final class CameraPhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {

    private let lock = NSLock()
    private var image: UIImage?
    private let metadataBoundary: DocumentBoundary?
    private var photoBoundary: DocumentBoundary?
    private var processingError: CameraError?
    private let completion: (CameraPhotoCaptureDelegate, UIImage?, DocumentBoundary?, CameraError?) -> Void

    init(boundary: DocumentBoundary?, completion: @escaping (CameraPhotoCaptureDelegate, UIImage?, DocumentBoundary?, CameraError?) -> Void) {
        self.metadataBoundary = boundary
        self.completion = completion
    }

    /// 写真の処理結果を保持し、最終コールバックまで UI へ配信しない。
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: (any Error)?) {
        var resultImage: UIImage?
        var resultError: CameraError?
        var boundary: DocumentBoundary?
        if let error {
            resultImage = nil
            resultError = .captureFailed(error.localizedDescription)
        } else if let data = photo.fileDataRepresentation(),
                  let decoded = UIImage(data: data) {
            resultImage = decoded
            resultError = nil
            if let metadataBoundary, let cg = decoded.cgImage {
                let size = CGSize(width: cg.width, height: cg.height)
                func toPhoto(_ point: CGPoint) -> CGPoint {
                    output.outputRectConverted(fromMetadataOutputRect: CGRect(origin: point, size: .zero)).origin
                }
                let transform = CameraCaptureGeometry.transform(
                    origin: toPhoto(.zero), x: toPhoto(CGPoint(x: 1, y: 0)),
                    y: toPhoto(CGPoint(x: 0, y: 1)))
                boundary = metadataBoundary.map {
                    CameraCaptureGeometry.normalizedPhotoPoint($0.applying(transform), size: size,
                                                               orientation: decoded.imageOrientation)
                }
                if boundary?.isValid != true {
                    resultImage = nil
                    resultError = .captureFailed("The displayed boundary could not be mapped to the photo. Please try again.")
                }
            }
        } else {
            resultImage = nil
            resultError = .invalidPhotoData
        }
        lock.lock()
        image = resultImage
        photoBoundary = boundary
        processingError = resultError
        lock.unlock()
    }

    /// 最終コールバックで画像・エラーをまとめて配信する。
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
                     error: (any Error)?) {
        lock.lock()
        let processedImage = image
        let processedError = processingError
        let boundary = photoBoundary
        lock.unlock()

        let finalError = error.map { CameraError.captureFailed($0.localizedDescription) }
            ?? processedError
        completion(self, processedImage, boundary, finalError ?? (processedImage == nil ? .invalidPhotoData : nil))
    }
}
