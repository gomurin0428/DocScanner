import XCTest
@testable import DocScanner

/// DocumentImageProcessor のフィルタ・回転のテスト。
final class DocumentImageProcessorTests: XCTestCase {

    /// 対象プロセッサ。
    private let processor = DocumentImageProcessor()

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// グレースケール適用後に R/G/B がほぼ等しくなることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 単色画像へ grayscale を適用し複数ピクセルをサンプリングする
    func testGrayscaleProducesNeutralPixels() throws {
        let image = TestImageFactory.solid(UIColor(red: 0.8, green: 0.2, blue: 0.4, alpha: 1),
                                           size: CGSize(width: 64, height: 64))
        let result = try processor.apply(.grayscale, to: image)
        for (x, y) in [(8, 8), (32, 32), (56, 56)] {
            let color = try XCTUnwrap(TestImageFactory.pixelColor(of: result, x: x, y: y))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            XCTAssertEqual(r, g, accuracy: 0.05)
            XCTAssertEqual(g, b, accuracy: 0.05)
        }
    }

    /// 白黒 2 値化で全ピクセルが 0 か 255 付近になることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: グラデーション画像へ blackAndWhite を適用しサンプリングする
    func testBlackAndWhiteProducesBinaryPixels() throws {
        let image = TestImageFactory.gradient(size: CGSize(width: 128, height: 64))
        let result = try processor.apply(.blackAndWhite, to: image)
        for x in stride(from: 0, to: 128, by: 8) {
            let color = try XCTUnwrap(TestImageFactory.pixelColor(of: result, x: x, y: 32))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            let nearBlack = r < 0.1
            let nearWhite = r > 0.9
            XCTAssertTrue(nearBlack || nearWhite, "pixel at x=\(x) was \(r), expected near 0 or 1")
        }
    }

    /// 全フィルタでピクセルサイズが保持されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 各フィルタ適用後のピクセルサイズを入力と比較する
    func testFiltersPreservePixelSize() throws {
        let image = TestImageFactory.solid(.orange, size: CGSize(width: 200, height: 100))
        for filter in PageFilter.allCases {
            let result = try processor.apply(filter, to: image)
            XCTAssertEqual(TestImageFactory.pixelSize(of: result),
                           CGSize(width: 200, height: 100),
                           "filter \(filter.rawValue) changed pixel size")
        }
    }

    /// 1 回転で縦横が入れ替わることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 200x100 を 1 回転して 100x200 になることを検査する
    func testRotateOneTurnSwapsDimensions() throws {
        let image = TestImageFactory.solid(.blue, size: CGSize(width: 200, height: 100))
        let result = try processor.rotate(image, quarterTurns: 1)
        XCTAssertEqual(TestImageFactory.pixelSize(of: result), CGSize(width: 100, height: 200))
    }

    /// 4 回転と 0 回転でサイズが変わらないことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: quarterTurns 4 と 0 で 200x100 のままであることを検査する
    func testRotateFourAndZeroKeepSize() throws {
        let image = TestImageFactory.solid(.blue, size: CGSize(width: 200, height: 100))
        XCTAssertEqual(TestImageFactory.pixelSize(of: try processor.rotate(image, quarterTurns: 4)),
                       CGSize(width: 200, height: 100))
        XCTAssertEqual(TestImageFactory.pixelSize(of: try processor.rotate(image, quarterTurns: 0)),
                       CGSize(width: 200, height: 100))
    }

    /// 長辺が上限を超える横長画像が上限まで縮小されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 4000x3000 を downscaled(3000) して 3000x2250 になることを検査する
    func testDownscaledShrinksLargeLandscapeImage() throws {
        let image = TestImageFactory.solid(.blue, size: CGSize(width: 4000, height: 3000))
        let result = try processor.downscaled(image)
        XCTAssertEqual(TestImageFactory.pixelSize(of: result), CGSize(width: 3000, height: 2250))
    }

    /// 長辺が上限以内の画像はピクセルサイズが変わらないことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 1000x800 を downscaled(3000) して 1000x800 のままであることを検査する
    func testDownscaledKeepsSmallImage() throws {
        let image = TestImageFactory.solid(.blue, size: CGSize(width: 1000, height: 800))
        let result = try processor.downscaled(image)
        XCTAssertEqual(TestImageFactory.pixelSize(of: result), CGSize(width: 1000, height: 800))
    }

    /// 縦長画像も長辺基準で縮小されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 3000x4000 を downscaled(3000) して 2250x3000 になることを検査する
    func testDownscaledShrinksLargePortraitImage() throws {
        let image = TestImageFactory.solid(.blue, size: CGSize(width: 3000, height: 4000))
        let result = try processor.downscaled(image)
        XCTAssertEqual(TestImageFactory.pixelSize(of: result), CGSize(width: 2250, height: 3000))
    }

    /// -1 回転と 3 回転が同じサイズになることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: quarterTurns -1 と 3 のピクセルサイズを比較する
    func testRotateMinusOneEqualsRotateThree() throws {
        let image = TestImageFactory.solid(.blue, size: CGSize(width: 200, height: 100))
        let minusOne = try processor.rotate(image, quarterTurns: -1)
        let three = try processor.rotate(image, quarterTurns: 3)
        XCTAssertEqual(TestImageFactory.pixelSize(of: minusOne),
                       TestImageFactory.pixelSize(of: three))
    }
}
