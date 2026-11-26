import CoreImage
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

    func testShadingCorrectionKeepsLargeDarkFillDarkInSmallImages() throws {
        let size = CGSize(width: 200, height: 200)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 32.0 / 255.0, alpha: 1).setFill()
            context.fill(CGRect(x: 50, y: 50, width: 100, height: 100))
        }

        let corrected = try shadingCorrected(image)
        let center = colorComponents(try XCTUnwrap(TestImageFactory.pixelColor(of: corrected, x: 100, y: 100)))
        XCTAssertLessThan((center.red + center.green + center.blue) / 3, 0.2)
    }

    func testShadingCorrectionPreservesFaintColoredPrinting() throws {
        let size = CGSize(width: 512, height: 512)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for y in 0..<Int(size.height) {
                let shadow = CGFloat(y) / size.height
                UIColor(red: 0.94 - 0.12 * shadow,
                        green: 0.80 - 0.12 * shadow,
                        blue: 0.66 - 0.10 * shadow,
                        alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: CGFloat(y), width: size.width, height: 1))
            }
            UIColor(red: 0.74, green: 0.60, blue: 0.50, alpha: 1).setFill()
            context.fill(CGRect(x: 160, y: 252, width: 192, height: 8))
        }

        let corrected = try shadingCorrected(image)
        let sourceInk = colorComponents(try XCTUnwrap(TestImageFactory.pixelColor(of: image, x: 256, y: 256)))
        let correctedInk = colorComponents(try XCTUnwrap(TestImageFactory.pixelColor(of: corrected, x: 256, y: 256)))

        XCTAssertEqual(correctedInk.red / correctedInk.green, sourceInk.red / sourceInk.green, accuracy: 0.05)
        XCTAssertEqual(correctedInk.green / correctedInk.blue, sourceInk.green / sourceInk.blue, accuracy: 0.05)
        let paper = colorComponents(try XCTUnwrap(TestImageFactory.pixelColor(of: corrected, x: 64, y: 256)))
        XCTAssertGreaterThan(paper.blue - correctedInk.blue, 0.04)
    }

    func testShadingCorrectionKeepsSmoothShadowGradientMonotonic() throws {
        let width = 512, height = 96
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for x in 0..<width {
                let value = 0.02 + 0.55 * CGFloat(x) / CGFloat(width - 1)
                UIColor(white: value, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
            }
        }

        let corrected = try shadingCorrected(image)
        let bitmap = try PageBitmap(XCTUnwrap(corrected.cgImage))
        let row = height / 2
        var previous = Int(bitmap.data[(row * width) * 4])
        for x in 1..<width {
            let current = Int(bitmap.data[(row * width + x) * 4])
            XCTAssertGreaterThanOrEqual(current, previous - 1, "x=\(x)")
            let source = 0.02 + 0.55 * CGFloat(x) / CGFloat(width - 1)
            if (0.06...0.42).contains(source) {
                XCTAssertLessThanOrEqual(current - previous, 12, "x=\(x)")
            }
            previous = current
        }
    }

    func testShadingHighlightShoulderIsContinuousAcrossUnityGain() throws {
        let width = 512, height = 96
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for x in 0..<width {
                let value = x < 320 ? 0.96 + 0.04 * CGFloat(x) / 320 : 1
                UIColor(white: value, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
            }
            UIColor(red: 1, green: 200.0 / 255, blue: 150.0 / 255, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 40, width: CGFloat(width), height: 8))
        }

        let corrected = try shadingCorrected(image)
        let bitmap = try PageBitmap(XCTUnwrap(corrected.cgImage))
        let row = 44
        for x in 280..<460 {
            let offset = (row * width + x) * 4
            let previous = (row * width + x - 1) * 4
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(bitmap.data[offset + channel]) -
                                                Int(bitmap.data[previous + channel])), 2, "x=\(x)")
            }
        }
    }

    /// 白黒フィルタが輝度 0.75 の細線を保持しつつ大きな黒領域をくり抜かないことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 白紙に 2px の水平/垂直細線（輝度 0.75）と 60x60 の黒塊を描いた
    ///   800x600 画像へ blackAndWhite を適用し、細線上の最小輝度 < 0.5、
    ///   黒塊中心 < 0.1、余白 > 0.95 を検査する。
    ///   旧実装（グローバル閾値 0.88）では 0.75 の細線が白へ潰れて消える回帰テスト
    func testBlackAndWhiteKeepsFaintThinStrokes() throws {
        let size = CGSize(width: 800, height: 600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            // 実写の細いハイフン・漢字の横画を模した薄い細線（輝度 0.75、2px）
            UIColor(white: 0.75, alpha: 1).setFill()
            ctx.fill(CGRect(x: 100, y: 300, width: 600, height: 2))
            ctx.fill(CGRect(x: 500, y: 100, width: 2, height: 400))
            // 大きな黒領域（くり抜き防止の確認用）
            UIColor.black.setFill()
            ctx.fill(CGRect(x: 50, y: 50, width: 60, height: 60))
        }
        let result = try processor.apply(.blackAndWhite, to: image)
        // 水平細線: 線上のどこかが黒く残る（最小輝度 < 0.5）
        var minH: CGFloat = 1
        for x in stride(from: 120, to: 460, by: 20) {
            minH = min(minH, brightness(of: result, fx: CGFloat(x) / 800, fy: 301.0 / 600))
        }
        XCTAssertLessThan(minH, 0.5, "horizontal faint line vanished")
        // 垂直細線: 交差部を避けてサンプリング
        var minV: CGFloat = 1
        for y in stride(from: 120, to: 280, by: 20) {
            minV = min(minV, brightness(of: result, fx: 501.0 / 800, fy: CGFloat(y) / 600))
        }
        XCTAssertLessThan(minV, 0.5, "vertical faint line vanished")
        // 黒塊中心は黒のまま（適応側のくり抜きが出ないこと）
        XCTAssertLessThan(brightness(of: result, fx: 80.0 / 800, fy: 80.0 / 600), 0.1,
                          "solid black block hollowed out")
        // 余白は白
        XCTAssertGreaterThan(brightness(of: result, fx: 750.0 / 800, fy: 550.0 / 600), 0.95,
                             "blank paper not white")
    }

    /// 陰影のある合成書類画像を生成する。
    /// - 入力: なし
    /// - 出力: 1200x1600 で上端白(1.0)→下端暗(0.45)の縦グラデーション紙に、
    ///   上下それぞれ黒い 20px バーを持つ UIImage
    /// - 処理: 行ごとの明るさで塗り、上部・下部に黒帯を描く
    private func makeShadedPaper() -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            for y in 0..<Int(size.height) {
                let brightness = 1.0 - 0.55 * (CGFloat(y) / size.height)
                UIColor(white: brightness, alpha: 1).setFill()
                ctx.fill(CGRect(x: 0, y: CGFloat(y), width: size.width, height: 1))
            }
            UIColor.black.setFill()
            // 文字を模した黒バー（上部・下部）
            ctx.fill(CGRect(x: 100, y: 100, width: 1000, height: 20))
            ctx.fill(CGRect(x: 100, y: 1480, width: 1000, height: 20))
        }
    }

    /// 画像内の割合位置の明度（RGB 平均）を返す。
    /// - 入力: image … 対象画像、fx / fy … 0〜1 の割合座標
    /// - 出力: 0〜1 の明度。取得失敗時は -1
    /// - 処理: pixelColor で 1px サンプリングして RGB 平均を計算する
    private func brightness(of image: UIImage, fx: CGFloat, fy: CGFloat) -> CGFloat {
        let pixel = TestImageFactory.pixelSize(of: image)
        let x = min(Int(pixel.width * fx), Int(pixel.width) - 1)
        let y = min(Int(pixel.height * fy), Int(pixel.height) - 1)
        guard let color = TestImageFactory.pixelColor(of: image, x: x, y: y) else { return -1 }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r + g + b) / 3
    }

    /// blackAndWhite で暗い下部の紙も白・文字バーも黒になることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 陰影付き合成画像へ blackAndWhite を適用し、上部・下部の
    ///   紙サンプル ≥0.9、バーサンプル ≤0.1 を検査する。
    ///   旧実装（一律閾値 0.5）では下部紙が黒化し失敗する回帰テスト
    func testBlackAndWhiteLiftsShadedPaper() throws {
        let result = try processor.apply(.blackAndWhite, to: makeShadedPaper())
        // 上部: 紙は白、バーは黒
        XCTAssertGreaterThanOrEqual(brightness(of: result, fx: 0.5, fy: 0.05), 0.9, "top paper")
        XCTAssertLessThanOrEqual(brightness(of: result, fx: 0.5, fy: 0.068), 0.1, "top bar")
        // 下部: 陰のある紙も白、バーは黒（ここが旧実装で失敗する）
        XCTAssertGreaterThanOrEqual(brightness(of: result, fx: 0.5, fy: 0.875), 0.9, "bottom paper")
        XCTAssertLessThanOrEqual(brightness(of: result, fx: 0.5, fy: 0.93), 0.1, "bottom bar")
    }

    func testBlackAndWhiteKeepsFinePrintOnShadowedSmallPage() throws {
        let width = 180, height = 240
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for y in 0..<height {
                let value = 0.18 + 0.08 * CGFloat(y) / CGFloat(height - 1)
                UIColor(white: value, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: CGFloat(y), width: CGFloat(width), height: 1))
            }
            UIColor(white: 0.05, alpha: 1).setFill()
            context.fill(CGRect(x: 22, y: 120, width: 90, height: 1))
            ("FINE" as NSString).draw(at: CGPoint(x: 22, y: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 8),
                .foregroundColor: UIColor(white: 0.05, alpha: 1)
            ])
            UIColor(white: 32.0 / 255.0, alpha: 1).setFill()
            context.fill(CGRect(x: 145, y: 190, width: 24, height: 24))
        }
        var modelLoadCount = 0
        let enhancer = DocResEnhancer(modelLoader: {
            modelLoadCount += 1
            throw DocResModelLoadingError.restartRequired
        })
        let result = try DocumentImageProcessor(enhancer: enhancer).apply(.blackAndWhite, to: image)

        XCTAssertEqual(modelLoadCount, 0)
        XCTAssertGreaterThan(brightness(of: result, fx: 10.0 / CGFloat(width), fy: 20.0 / CGFloat(height)), 0.1,
                             "shadowed paper collapsed to black")
        XCTAssertLessThan(brightness(of: result, fx: 60.0 / CGFloat(width), fy: 120.0 / CGFloat(height)), 0.1,
                          "fine text stroke was lost")
        XCTAssertLessThan(brightness(of: result, fx: 157.0 / CGFloat(width), fy: 202.0 / CGFloat(height)), 0.1,
                          "dark fill was lifted")
    }

    /// enhanced で暗い下部の紙が明るく持ち上がることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 下部紙 ≥0.85、バー ≤0.3 を検査する
    func testEnhancedLiftsShadedPaper() throws {
        let result = try processor.apply(.enhanced, to: makeShadedPaper())
        XCTAssertGreaterThanOrEqual(brightness(of: result, fx: 0.5, fy: 0.875), 0.85, "bottom paper")
        XCTAssertLessThanOrEqual(brightness(of: result, fx: 0.5, fy: 0.93), 0.3, "bottom bar")
    }

    /// grayscale で R==G==B を保ち暗い下部の紙が明るくなることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 下部紙の R,G,B が ±2/255 で一致し明度 ≥0.85 を検査する
    func testGrayscaleNeutralAndLiftsShadedPaper() throws {
        let result = try processor.apply(.grayscale, to: makeShadedPaper())
        let pixel = TestImageFactory.pixelSize(of: result)
        let color = try XCTUnwrap(TestImageFactory.pixelColor(
            of: result, x: Int(pixel.width / 2), y: Int(pixel.height * 0.875)))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        XCTAssertEqual(r, g, accuracy: 2.0 / 255)
        XCTAssertEqual(g, b, accuracy: 2.0 / 255)
        XCTAssertGreaterThanOrEqual((r + g + b) / 3, 0.85, "bottom paper")
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

    private func shadingCorrected(_ image: UIImage) throws -> UIImage {
        let source = try XCTUnwrap(image.cgImage)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let ciImage = CIImage(cgImage: source, options: [.colorSpace: sRGB])
        let corrected = try ShadingCorrector.flattened(ciImage)
        return UIImage(cgImage: try XCTUnwrap(
            ImageRendering.context.createCGImage(corrected, from: corrected.extent,
                                                 format: .RGBA8, colorSpace: sRGB)
        ))
    }

    private func colorComponents(_ color: UIColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red, green, blue)
    }
}
