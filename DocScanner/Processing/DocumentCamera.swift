import CoreGraphics
import ImageIO
import UIKit

struct DocumentCamera {
    let focalX: Double
    let focalY: Double
    let centerX: Double
    let centerY: Double
    let referenceSize: CGSize

    static func from(data: Data) -> DocumentCamera? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let exif = properties[kCGImagePropertyExifDictionary] as? NSDictionary,
              let focal = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              focal.doubleValue > 0, width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        let w = width.doubleValue, h = height.doubleValue
        let f = focal.doubleValue * hypot(w, h) / hypot(36, 24)
        return DocumentCamera(focalX: f, focalY: f, centerX: w / 2, centerY: h / 2,
                              referenceSize: CGSize(width: w, height: h))
    }

    func oriented(_ orientation: UIImage.Orientation) -> DocumentCamera {
        let point = CameraCaptureGeometry.normalizedPhotoPoint(CGPoint(x: centerX, y: centerY),
                                                               size: referenceSize, orientation: orientation)
        let swapsAxes = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
        let size = swapsAxes ? CGSize(width: referenceSize.height, height: referenceSize.width) : referenceSize
        return DocumentCamera(focalX: swapsAxes ? focalY : focalX, focalY: swapsAxes ? focalX : focalY,
                              centerX: point.x * size.width, centerY: (1 - point.y) * size.height,
                              referenceSize: size)
    }

    func scaled(to size: CGSize) -> DocumentCamera {
        let x = size.width / referenceSize.width, y = size.height / referenceSize.height
        return DocumentCamera(focalX: focalX * x, focalY: focalY * y,
                              centerX: centerX * x, centerY: centerY * y, referenceSize: size)
    }
}
