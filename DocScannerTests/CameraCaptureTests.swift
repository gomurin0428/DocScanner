import XCTest
import UIKit
@testable import DocScanner

/// 表示領域の固定・画角変換・写真の向き・取り込みの回帰テスト。
final class CameraCaptureTests: XCTestCase {
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// 大きい別書類が写っていても、緑枠で選んだ小さい赤い領域だけを保存する。
    func testCameraImportKeepsSelectedRegionInsteadOfRedetecting() throws {
        let image = twoDocuments()
        let boundary = DocumentBoundary(corners: [
            CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.3, y: 0.8),
            CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.1, y: 0.4)
        ])
        let result = try PageImporter().makePages(from: [PageSource.camera(image, boundary: boundary)])
        let page = try XCTUnwrap(result.detectedPages.first)
        XCTAssertEqual(page.baseImage.size.width, 120, accuracy: 1)
        XCTAssertEqual(page.baseImage.size.height, 200, accuracy: 1)
        try assertRed(page.baseImage)
    }

    /// 枠が無い撮影を、撮影後に自動検出して別領域へ切り替えない。
    func testCameraWithoutOverlayRequiresFullImageConfirmation() throws {
        let result = try PageImporter().makePages(from: [PageSource.camera(twoDocuments(), boundary: nil)])
        XCTAssertEqual(result.undetectedImages.count, 1)
        XCTAssertTrue(result.detectedPages.isEmpty)
        XCTAssertTrue(result.pages(includingUndetected: false).isEmpty)
        XCTAssertEqual(result.pages(includingUndetected: true).count, 1)
    }

    /// 右回転の EXIF 画像でも画素・四隅の向きを揃えて同じ赤い範囲を保存する。
    func testRotatedPhotoUsesUprightBoundary() throws {
        let raw = twoDocuments()
        let image = UIImage(cgImage: try XCTUnwrap(raw.cgImage), scale: 1, orientation: .right)
        let rawCorners = [CGPoint(x: 60, y: 300), CGPoint(x: 60, y: 100),
                          CGPoint(x: 180, y: 100), CGPoint(x: 180, y: 300)]
        let boundary = DocumentBoundary(corners: rawCorners.map {
            CameraCaptureGeometry.normalizedPhotoPoint($0, size: raw.size, orientation: .right)
        })
        let result = try PageImporter().makePages(from: [PageSource.camera(image, boundary: boundary)])
        let page = try XCTUnwrap(result.detectedPages.first)
        XCTAssertEqual(page.baseImage.size.width, 200, accuracy: 1)
        XCTAssertEqual(page.baseImage.size.height, 120, accuracy: 1)
        try assertRed(page.baseImage)
    }

    /// 縮小前の正規化輪郭を保存し、3000px へ縮小しても違う範囲を選ばない。
    func testHighResolutionCapturePreservesNormalizedSelection() throws {
        let image = twoDocuments(scale: 7)
        let boundary = DocumentBoundary(corners: [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.3, y: 0.8),
                                                  CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.1, y: 0.4)])
        let result = try PageImporter().makePages(from: [PageSource.camera(image, boundary: boundary)])
        let page = try XCTUnwrap(result.detectedPages.first)
        XCTAssertEqual(page.baseImage.size.width, 600, accuracy: 1)
        XCTAssertEqual(page.baseImage.size.height, 1000, accuracy: 1)
        try assertRed(page.baseImage)
    }

    /// 撮影ごとの輪郭を保持し、失敗した撮影を混ぜずに入力順を維持する。
    func testPhotoStateKeepsEachCaptureBoundaryAndSkipsFailure() throws {
        var state = CameraPhotoState()
        let first = DocumentBoundary(corners: [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.3, y: 0.8),
                                               CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.1, y: 0.4)])
        let second = first.map { CGPoint(x: $0.x + 0.4, y: $0.y) }
        state.beginCapture()
        state.finishCapture(image: twoDocuments(), shouldAppend: true, boundary: first)
        state.beginCapture()
        state.finishCapture(image: nil, shouldAppend: false, boundary: second)
        state.beginCapture()
        state.finishCapture(image: twoDocuments(), shouldAppend: true, boundary: second)
        XCTAssertEqual(state.sources.count, 2)
        for (source, expected) in zip(state.sources, [first, second]) {
            guard case .camera(_, let boundary) = source else { return XCTFail("Expected camera source") }
            XCTAssertEqual(boundary, expected)
        }
    }

    /// 縦向き解析バッファの中心クロップを、センサー座標経由で写真の画角へ戻す。
    func testDifferentVideoAndPhotoFieldsOfView() {
        let toMetadata = CameraCaptureGeometry.transform(
            origin: CGPoint(x: 1, y: 0.125), x: CGPoint(x: 1, y: 0.875), y: CGPoint(x: 0, y: 0.125))
        let toPhotoPixels = CameraCaptureGeometry.transform(
            origin: .zero, x: CGPoint(x: 4000, y: 0), y: CGPoint(x: 0, y: 3000))
        let point = CGPoint(x: 0.2, y: 0.7).applying(toMetadata).applying(toPhotoPixels)
        let upright = CameraCaptureGeometry.normalizedPhotoPoint(point,
            size: CGSize(width: 4000, height: 3000), orientation: .right)
        XCTAssertEqual(upright.x, 0.725, accuracy: 0.00001)
        XCTAssertEqual(upright.y, 0.7, accuracy: 0.00001)
    }

    /// 全 EXIF 向きで左上原点の写真ピクセルを表示向きの左下原点へ変換する。
    func testAllPhotoOrientations() {
        let cases: [(UIImage.Orientation, CGPoint)] = [
            (.up, CGPoint(x: 0.2, y: 0.7)), (.down, CGPoint(x: 0.8, y: 0.3)),
            (.left, CGPoint(x: 0.3, y: 0.2)), (.right, CGPoint(x: 0.7, y: 0.8)),
            (.upMirrored, CGPoint(x: 0.8, y: 0.7)), (.downMirrored, CGPoint(x: 0.2, y: 0.3)),
            (.leftMirrored, CGPoint(x: 0.3, y: 0.8)), (.rightMirrored, CGPoint(x: 0.7, y: 0.2))
        ]
        for (orientation, expected) in cases {
            let point = CameraCaptureGeometry.normalizedPhotoPoint(CGPoint(x: 80, y: 90),
                size: CGSize(width: 400, height: 300), orientation: orientation)
            XCTAssertEqual(point.x, expected.x, accuracy: 0.00001)
            XCTAssertEqual(point.y, expected.y, accuracy: 0.00001)
        }
    }

    /// 不正な保存輪郭を黙って再検出せずエラーにする。
    func testInvalidSavedBoundaryIsRejected() {
        let boundary = DocumentBoundary(top: [], right: [], bottom: [], left: [])
        XCTAssertThrowsError(try PageImporter().makePages(from: [PageSource.camera(twoDocuments(), boundary: boundary)]))
    }

    /// 大きい白い書類と小さい赤い選択範囲を描画する。
    private func twoDocuments(scale: CGFloat = 1) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 500), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 500))
            UIColor.white.setFill()
            context.fill(CGRect(x: 270, y: 20, width: 310, height: 460))
            UIColor.red.setFill()
            context.fill(CGRect(x: 60, y: 100, width: 120, height: 200))
        }
    }

    /// 出力の各所が選択した赤色で、別書類や背景を含まないことを確認する。
    private func assertRed(_ image: UIImage) throws {
        for x in [0.1, 0.5, 0.9] {
            for y in [0.1, 0.5, 0.9] {
                let color = try XCTUnwrap(TestImageFactory.pixelColor(of: image,
                    x: Int(image.size.width * x), y: Int(image.size.height * y)))
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                XCTAssertGreaterThan(red, 0.95)
                XCTAssertLessThan(green, 0.05)
                XCTAssertLessThan(blue, 0.05)
            }
        }
    }
}
