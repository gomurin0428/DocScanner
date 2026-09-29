import XCTest
@testable import DocScanner

/// DocumentDetector の書類検出・台形補正のテスト。
final class DocumentDetectorTests: XCTestCase {

    /// 対象検出器。
    private let detector = DocumentDetector()

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// 合成画像内の歪んだ四角形を検出し補正後の縦横比が概ね一致することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 暗背景 + 白い歪んだ四角形を描き、補正後画像の縦横比を許容誤差付きで検査する
    func testDetectsSkewedQuadrilateral() throws {
        let size = CGSize(width: 1200, height: 1600)
        // 書類は約 600x800（縦横比 0.75）。角をずらして台形にする
        let quad: [CGPoint] = [
            CGPoint(x: 320, y: 420),   // 左上
            CGPoint(x: 950, y: 390),   // 右上
            CGPoint(x: 900, y: 1250),  // 右下
            CGPoint(x: 280, y: 1200)   // 左下
        ]
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let path = UIBezierPath()
            path.move(to: quad[0])
            for point in quad.dropFirst() { path.addLine(to: point) }
            path.close()
            UIColor.white.setFill()
            path.fill()
        }

        let corrected = try detector.detectAndCorrect(image)
        let pixel = TestImageFactory.pixelSize(of: corrected)
        let aspect = pixel.width / pixel.height
        XCTAssertEqual(aspect, 0.75, accuracy: 0.25)
    }

    /// 一様なグレー画像では noDocumentFound が送出されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 四角形の無い画像に対して検出を試行する
    func testUniformImageThrowsNoDocumentFound() {
        let image = TestImageFactory.solid(UIColor(white: 0.5, alpha: 1),
                                           size: CGSize(width: 400, height: 300))
        XCTAssertThrowsError(try detector.detectAndCorrect(image)) { error in
            XCTAssertEqual(error as? DocumentDetectionError, .noDocumentFound)
        }
    }
}
