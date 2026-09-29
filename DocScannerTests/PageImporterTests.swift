import XCTest
@testable import DocScanner

/// PageImporter の検出・縮小処理のテスト。
final class PageImporterTests: XCTestCase {

    /// 対象インポータ。
    private let importer = PageImporter()

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// 書類らしい四角形を含む画像と一様画像で検出結果が振り分けられることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: [書類画像, 一様グレー画像] を渡し 1 検出 + 1 未検出になることを検査する
    func testMixedImagesAreSplitIntoDetectedAndUndetected() throws {
        let documentImage = Self.makeDocumentImage(size: CGSize(width: 1200, height: 1600))
        let blank = TestImageFactory.solid(UIColor(white: 0.5, alpha: 1),
                                           size: CGSize(width: 400, height: 300))
        let result = try importer.makePages(from: [documentImage, blank])
        XCTAssertEqual(result.detectedPages.count, 1)
        XCTAssertEqual(result.undetectedImages.count, 1)
    }

    /// 上限を超える入力が検出前に縮小されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 長辺 4000px の書類画像を渡し、検出済み画像の長辺が 3000 以下であることを検査する
    func testLargeInputIsDownscaledBeforeDetection() throws {
        let image = Self.makeDocumentImage(size: CGSize(width: 3000, height: 4000))
        let result = try importer.makePages(from: [image])
        XCTAssertEqual(result.detectedPages.count, 1)
        let pixel = TestImageFactory.pixelSize(of: result.detectedPages[0].baseImage)
        XCTAssertLessThanOrEqual(max(pixel.width, pixel.height), 3000)
    }

    /// テスト用の書類合成画像を生成する。
    /// - 入力: size … 画像サイズ
    /// - 出力: 暗背景に白い歪んだ四角形を含む UIImage
    /// - 処理: 中央寄りに台形を描画する
    private static func makeDocumentImage(size: CGSize) -> UIImage {
        let w = size.width
        let h = size.height
        let quad: [CGPoint] = [
            CGPoint(x: w * 0.27, y: h * 0.26),
            CGPoint(x: w * 0.79, y: h * 0.24),
            CGPoint(x: w * 0.75, y: h * 0.78),
            CGPoint(x: w * 0.23, y: h * 0.75)
        ]
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let path = UIBezierPath()
            path.move(to: quad[0])
            for point in quad.dropFirst() { path.addLine(to: point) }
            path.close()
            UIColor.white.setFill()
            path.fill()
        }
    }
}
