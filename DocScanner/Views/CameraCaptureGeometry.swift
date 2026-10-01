import CoreGraphics
import UIKit

/// 出力間の画角・回転変換と、写真の EXIF 向きの座標変換。
enum CameraCaptureGeometry {
    /// 正規化点を出力座標変換へ通すアフィン写像を 3 点から作る。
    /// - 入力: 単位原点・X端・Y端の変換後座標、出力: 正規化座標用変換行列
    static func transform(origin: CGPoint, x: CGPoint, y: CGPoint) -> CGAffineTransform {
        CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                          c: y.x - origin.x, d: y.y - origin.y,
                          tx: origin.x, ty: origin.y)
    }

    /// EXIF 未適用の写真ピクセル座標を、表示向きの左下原点正規化座標へ変換する。
    static func normalizedPhotoPoint(_ point: CGPoint, size: CGSize,
                                     orientation: UIImage.Orientation) -> CGPoint {
        let x = point.x / size.width, y = point.y / size.height
        let upright: CGPoint
        switch orientation {
        case .up: upright = CGPoint(x: x, y: y)
        case .down: upright = CGPoint(x: 1 - x, y: 1 - y)
        case .left: upright = CGPoint(x: y, y: 1 - x)
        case .right: upright = CGPoint(x: 1 - y, y: x)
        case .upMirrored: upright = CGPoint(x: 1 - x, y: y)
        case .downMirrored: upright = CGPoint(x: x, y: 1 - y)
        case .leftMirrored: upright = CGPoint(x: y, y: x)
        case .rightMirrored: upright = CGPoint(x: 1 - y, y: 1 - x)
        @unknown default: return CGPoint(x: CGFloat.nan, y: CGFloat.nan)
        }
        return CGPoint(x: upright.x, y: 1 - upright.y)
    }
}
