import XCTest
@testable import DocScanner

/// CameraCaptureView.overlayPoints の座標変換テスト。
final class CameraCaptureViewTests: XCTestCase {

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// 中央点がビュー中央へ写ることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 正規化 (0.5,0.5) が aspect-fill 変換後もビュー中心になることを検査する
    func testCenterMapsToViewCenter() {
        let points = CameraCaptureView.overlayPoints(
            normalized: [CGPoint(x: 0.5, y: 0.5)],
            bufferSize: CGSize(width: 300, height: 400),
            viewSize: CGSize(width: 90, height: 195))
        XCTAssertEqual(points[0].x, 45, accuracy: 1e-6)
        XCTAssertEqual(points[0].y, 97.5, accuracy: 1e-6)
    }

    /// 3:4 バッファを 9:19.5 ビューで表示したとき、可視範囲の隅がビュー隅へ写ることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: aspect-fill では左右がクロップされる。可視クロップの左端/右端の
    ///   正規化 x を求め、その 4 隅（y-up）がビュー 4 隅へ一致することを検査する
    func testVisibleCropCornersMapToViewCorners() {
        let buffer = CGSize(width: 300, height: 400)   // 3:4
        let view = CGSize(width: 90, height: 195)      // 9:19.5
        // scale = max(90/300, 195/400) = 0.4875 → 横がはみ出す
        let scaledW = buffer.width * 0.4875            // 146.25
        let minX = (scaledW - view.width) / 2 / scaledW  // ≈0.1923
        let maxX = 1 - minX
        let normalized = [
            CGPoint(x: minX, y: 0),   // 左下 → view 左下 (0, 195)
            CGPoint(x: maxX, y: 0),   // 右下 → view 右下 (90, 195)
            CGPoint(x: maxX, y: 1),   // 右上 → view 右上 (90, 0)
            CGPoint(x: minX, y: 1)    // 左上 → view 左上 (0, 0)
        ]
        let points = CameraCaptureView.overlayPoints(
            normalized: normalized, bufferSize: buffer, viewSize: view)
        let expected = [
            CGPoint(x: 0, y: 195), CGPoint(x: 90, y: 195),
            CGPoint(x: 90, y: 0), CGPoint(x: 0, y: 0)
        ]
        for (point, want) in zip(points, expected) {
            XCTAssertEqual(point.x, want.x, accuracy: 1e-6)
            XCTAssertEqual(point.y, want.y, accuracy: 1e-6)
        }
    }

    /// クロップされた領域外の点がビュー外へ写ることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 正規化 x=0 は is aspect-fill で左にはみ出すため x<0 になることを検査する
    func testOffscreenPointMapsOutsideView() {
        let points = CameraCaptureView.overlayPoints(
            normalized: [CGPoint(x: 0, y: 0.5)],
            bufferSize: CGSize(width: 300, height: 400),
            viewSize: CGSize(width: 90, height: 195))
        XCTAssertLessThan(points[0].x, 0)
    }
}
