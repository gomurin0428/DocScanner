import CoreImage
import Foundation
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
        let sourceImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 1, green: 200.0 / 255, blue: 150.0 / 255, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let illuminationImage = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for x in 0..<width {
                let value = 0.98 + 0.02 * CGFloat(x) / CGFloat(width - 1)
                UIColor(white: value, alpha: 1).setFill()
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: CGFloat(height)))
            }
        }
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let source = CIImage(cgImage: try XCTUnwrap(sourceImage.cgImage), options: [.colorSpace: sRGB])
        let illumination = CIImage(cgImage: try XCTUnwrap(illuminationImage.cgImage), options: [.colorSpace: sRGB])
        let corrected = try ShadingCorrector.applyingCorrection(to: source, using: illumination)
        let correctedCGImage = try XCTUnwrap(ImageRendering.context.createCGImage(
            corrected, from: corrected.extent, format: .RGBA8, colorSpace: sRGB
        ))
        let sourcePixels = try PageBitmap(XCTUnwrap(sourceImage.cgImage)).data
        let resultPixels = try PageBitmap(correctedCGImage).data
        let row = 44
        let unityOffset = (row * width + width - 1) * 4
        for channel in 0..<3 {
            XCTAssertLessThanOrEqual(abs(Int(resultPixels[unityOffset + channel]) -
                                            Int(sourcePixels[unityOffset + channel])), 1)
        }
        for x in 1..<width {
            let offset = (row * width + x) * 4
            let previous = (row * width + x - 1) * 4
            for channel in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(resultPixels[offset + channel]) -
                                                Int(resultPixels[previous + channel])), 2, "x=\(x)")
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

    func testBlackAndWhiteRetainsFaintPinkStrokesOnWhiteAndYellow() throws {
        let size = CGSize(width: 240, height: 240)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let pink = UIColor(red: 0.80, green: 0.74, blue: 0.80, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.82, green: 0.76, blue: 0.64, alpha: 1).setFill()
            context.fill(CGRect(x: 120, y: 0, width: 120, height: size.height))
            pink.setFill()
            context.fill(CGRect(x: 12, y: 70, width: 96, height: 3))
            context.fill(CGRect(x: 132, y: 170, width: 96, height: 3))
            ("STAMP" as NSString).draw(at: CGPoint(x: 15, y: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 16), .foregroundColor: pink
            ])
            ("MAP" as NSString).draw(at: CGPoint(x: 135, y: 190), withAttributes: [
                .font: UIFont.systemFont(ofSize: 16), .foregroundColor: pink
            ])
            let road = UIBezierPath()
            road.move(to: CGPoint(x: 135, y: 226))
            road.addLine(to: CGPoint(x: 228, y: 210))
            road.lineWidth = 3
            pink.setStroke()
            road.stroke()
        }

        let result = try processor.apply(.blackAndWhite, to: image)
        let pixels = try PageBitmap(XCTUnwrap(result.cgImage))
        func darkPixels(in rect: CGRect) -> Int {
            var count = 0
            for y in Int(rect.minY)..<Int(rect.maxY) {
                for x in Int(rect.minX)..<Int(rect.maxX) where pixels.luminance(atX: Double(x), y: Double(y)) < 220 {
                    count += 1
                }
            }
            return count
        }

        XCTAssertLessThan(brightness(of: result, fx: 0.25, fy: 0.30), 0.8,
                          "faint pink stroke on white disappeared")
        XCTAssertLessThan(brightness(of: result, fx: 0.75, fy: 0.71), 0.8,
                          "faint pink stroke on yellow disappeared")
        XCTAssertGreaterThan(darkPixels(in: CGRect(x: 10, y: 95, width: 95, height: 30)), 20,
                             "faint pink label on white disappeared")
        XCTAssertGreaterThan(darkPixels(in: CGRect(x: 130, y: 185, width: 90, height: 30)), 12,
                             "faint pink map label on yellow disappeared")
        XCTAssertLessThan(brightness(of: result, fx: 0.69, fy: 0.92), 0.8,
                          "faint map road was lost")
        XCTAssertGreaterThan(brightness(of: result, fx: 0.25, fy: 0.5), 0.95,
                             "white paper was darkened")
        XCTAssertGreaterThan(brightness(of: result, fx: 0.75, fy: 0.5), 0.95,
                             "yellow paper field was darkened")
    }

    func testBlackAndWhiteKeepsThinInkLegibleOnChromaticPaperTexture() throws {
        let size = CGSize(width: 240, height: 240)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let pink = UIColor(red: 0.80, green: 0.74, blue: 0.80, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for y in stride(from: 0, to: 240, by: 8) {
                for x in stride(from: 0, to: 240, by: 8) {
                    let texture = CGFloat(0.012 * (sin(Double(x) * 0.71) + cos(Double(y) * 0.63)))
                    UIColor(red: 0.94 + texture, green: 0.94 - texture * 0.5,
                            blue: 0.94 - texture * 0.5, alpha: 1).setFill()
                    context.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: 8, height: 8))
                }
            }
            let canvas = context.cgContext
            canvas.setLineWidth(2)
            canvas.setStrokeColor(pink.cgColor)
            canvas.move(to: CGPoint(x: 20, y: 64))
            canvas.addLine(to: CGPoint(x: 220, y: 64))
            canvas.strokePath()
            ("FINE" as NSString).draw(at: CGPoint(x: 38, y: 100), withAttributes: [
                .font: UIFont.systemFont(ofSize: 20), .foregroundColor: pink
            ])
            canvas.setLineWidth(3)
            canvas.setStrokeColor(UIColor(white: 0.72, alpha: 1).cgColor)
            canvas.move(to: CGPoint(x: 20, y: 165))
            canvas.addLine(to: CGPoint(x: 220, y: 165))
            canvas.strokePath()
        }

        let result = try processor.apply(.blackAndWhite, to: image)
        let pixels = try PageBitmap(XCTUnwrap(result.cgImage))
        func meanLuminance(x: Range<Int>, y: Range<Int>) -> Double {
            let values = y.flatMap { row in x.map { pixels.luminance(atX: Double($0), y: Double(row)) } }
            return values.reduce(0, +) / Double(values.count)
        }
        let paperSamples = (20..<50).flatMap { row in
            (20..<220).map { pixels.luminance(atX: Double($0), y: Double(row)) }
        }
        let paperMean = meanLuminance(x: 20..<220, y: 20..<50)
        let lineMean = meanLuminance(x: 30..<210, y: 63..<66)
        let labelMean = meanLuminance(x: 25..<120, y: 96..<128)
        let labelPaperMean = meanLuminance(x: 25..<120, y: 132..<156)
        let road = (30..<210).map { pixels.luminance(atX: Double($0), y: 165) }
        let roadMean = road.reduce(0, +) / Double(road.count)
        let pinkSource = colorComponents(pink)
        let pinkSourceLuma = 0.299 * Double(pinkSource.red)
            + 0.587 * Double(pinkSource.green) + 0.114 * Double(pinkSource.blue)
        let paperSourceLuma = 0.299 * 0.94 + 0.587 * 0.94 + 0.114 * 0.94
        let labelContrast = labelPaperMean - labelMean
        let details = String(format: "background=warm paper texture baseRGB=(0.940,0.940,0.940) textureAmplitude=0.018 sourceLuma=%.3f inkRGB=(%.3f,%.3f,%.3f) inkLuma=%.3f outputPaperMean=%.1f paperMin=%.1f lineMean=%.1f labelMean=%.1f labelPaperMean=%.1f labelContrast=%.1f roadMean=%.1f",
            paperSourceLuma, Double(pinkSource.red), Double(pinkSource.green), Double(pinkSource.blue),
            pinkSourceLuma, paperMean, paperSamples.min() ?? 0, lineMean, labelMean, labelPaperMean,
            labelContrast, roadMean)

        XCTAssertGreaterThan(paperMean, 230, "low-amplitude paper color texture became dark noise: \(details)")
        XCTAssertGreaterThan(paperSamples.min() ?? 0, 220, "paper texture produced dark chromatic blobs: \(details)")
        XCTAssertGreaterThan(lineMean, 55, "pink ink collapsed to black blobs: \(details)")
        XCTAssertGreaterThan(paperMean - lineMean, 35, "thin pink glyph lost contrast: \(details)")
        XCTAssertGreaterThan(labelContrast, 12, "faint text is not legible against paper: \(details)")
        XCTAssertGreaterThan(roadMean, 20, "gray road became a black blob: \(details)")
        XCTAssertLessThan(roadMean, 190, "gray road disappeared: \(details)")
        XCTAssertLessThan((road.max() ?? 0) - (road.min() ?? 0), 24, "gray road became mottled: \(details)")
    }

    func testBlackAndWhitePreservesWhiteKnockoutTextOnNavy() throws {
        let size = CGSize(width: 240, height: 240)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIColor(red: 0.02, green: 0.05, blue: 0.20, alpha: 1).setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
            ("WHITE" as NSString).draw(at: CGPoint(x: 34, y: 92), withAttributes: [
                .font: UIFont.systemFont(ofSize: 34), .foregroundColor: UIColor.white
            ])
        }

        let result = try processor.apply(.blackAndWhite, to: image)
        let pixels = try PageBitmap(XCTUnwrap(result.cgImage))
        var brightGlyphPixels = 0
        for y in 85..<135 {
            for x in 25..<220 where pixels.luminance(atX: Double(x), y: Double(y)) > 220 {
                brightGlyphPixels += 1
            }
        }

        XCTAssertGreaterThan(brightGlyphPixels, 100, "white knockout text on navy disappeared")
        XCTAssertLessThan(brightness(of: result, fx: 0.05, fy: 0.10), 0.15,
                          "navy field should remain dark")
    }

    func testBlackAndWhiteRetainsBrightYellowTextOnBlue() throws {
        let size = CGSize(width: 240, height: 300)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let blue = UIColor(red: 0.04, green: 0.09, blue: 0.45, alpha: 1)
        let yellow = UIColor(red: 1, green: 0.84, blue: 0.02, alpha: 1)
        let font = UIFont.systemFont(ofSize: 36)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width, height: 150))
            UIColor(white: 0.68, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 150, width: size.width, height: 150))
            ("YELLOW" as NSString).draw(at: CGPoint(x: 22, y: 55), withAttributes: [
                .font: font, .foregroundColor: yellow
            ])
            ("YELLOW" as NSString).draw(at: CGPoint(x: 22, y: 185), withAttributes: [
                .font: font, .foregroundColor: yellow
            ])
        }
        let glyphMask = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("YELLOW" as NSString).draw(at: CGPoint(x: 22, y: 55), withAttributes: [
                .font: font, .foregroundColor: UIColor.white
            ])
            ("YELLOW" as NSString).draw(at: CGPoint(x: 22, y: 185), withAttributes: [
                .font: font, .foregroundColor: UIColor.white
            ])
        }

        let result = try processor.apply(.blackAndWhite, to: image)
        let pixels = try PageBitmap(XCTUnwrap(result.cgImage))
        let maskPixels = try PageBitmap(XCTUnwrap(glyphMask.cgImage))
        var blueGlyph = [Double](), grayGlyph = [Double]()
        var blueBackground = [Double](), grayBackground = [Double]()
        for y in 50..<110 {
            for x in 18..<225 where maskPixels.luminance(atX: Double(x), y: Double(y)) > 220 {
                blueGlyph.append(pixels.luminance(atX: Double(x), y: Double(y)))
            }
        }
        for y in 180..<240 {
            for x in 18..<225 where maskPixels.luminance(atX: Double(x), y: Double(y)) > 220 {
                grayGlyph.append(pixels.luminance(atX: Double(x), y: Double(y)))
            }
        }
        for y in 120..<145 {
            for x in 20..<220 {
                blueBackground.append(pixels.luminance(atX: Double(x), y: Double(y)))
            }
        }
        for y in 260..<285 {
            for x in 20..<220 {
                grayBackground.append(pixels.luminance(atX: Double(x), y: Double(y)))
            }
        }
        guard !blueGlyph.isEmpty, !grayGlyph.isEmpty else {
            XCTFail("yellow text mask contained no glyph pixels")
            return
        }
        let blueGlyphMean = blueGlyph.reduce(0, +) / Double(blueGlyph.count)
        let grayGlyphMean = grayGlyph.reduce(0, +) / Double(grayGlyph.count)
        let blueBackgroundMean = blueBackground.reduce(0, +) / Double(blueBackground.count)
        let grayBackgroundMean = grayBackground.reduce(0, +) / Double(grayBackground.count)

        XCTAssertGreaterThan(blueGlyph.count, 100)
        XCTAssertGreaterThan(grayGlyph.count, 100)
        XCTAssertGreaterThan(blueGlyphMean - blueBackgroundMean, 25,
                             "bright chromatic text merged into its dark blue field")
        XCTAssertLessThan(blueBackgroundMean, 40, "blue field should remain dark")
        XCTAssertGreaterThan(grayBackgroundMean - grayGlyphMean, 25,
                             "bright yellow text merged into the light paper field")
        XCTAssertGreaterThan(grayBackgroundMean, 200, "light paper should remain bright")
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
        XCTAssertGreaterThan(brightness(of: result, fx: 10.0 / CGFloat(width), fy: 20.0 / CGFloat(height)), 0.75,
                             "shadowed paper was not lifted")
        XCTAssertLessThan(brightness(of: result, fx: 60.0 / CGFloat(width), fy: 120.0 / CGFloat(height)), 0.1,
                          "synthetic hairline was lost")
        XCTAssertLessThan(brightness(of: result, fx: 157.0 / CGFloat(width), fy: 202.0 / CGFloat(height)), 0.1,
                          "dark fill was lifted")

        let sourcePixels = try PageBitmap(XCTUnwrap(image.cgImage)).data
        let resultPixels = try PageBitmap(XCTUnwrap(result.cgImage)).data
        var glyphPixelCount = 0
        for y in 0..<height where !(117..<124).contains(y) {
            for x in 18..<70 {
                let offset = (y * width + x) * 4
                let sourceLuma = (Int(sourcePixels[offset]) + Int(sourcePixels[offset + 1]) +
                                  Int(sourcePixels[offset + 2])) / 3
                if sourceLuma < 24 {
                    glyphPixelCount += 1
                    let resultLuma = (Int(resultPixels[offset]) + Int(resultPixels[offset + 1]) +
                                      Int(resultPixels[offset + 2])) / 3
                    XCTAssertLessThan(resultLuma, 26, "glyph pixel at (\(x), \(y)) was lost")
                }
            }
        }
        XCTAssertGreaterThan(glyphPixelCount, 5, "synthetic text mask was empty")
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

    func testEnhancedPreservesWarmCastRatiosAndColoredMarks() throws {
        let size = CGSize(width: 240, height: 160)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let paper = UIColor(red: 0.88, green: 0.77, blue: 0.65, alpha: 1)
        let yellow = UIColor(red: 0.96, green: 0.84, blue: 0.12, alpha: 1)
        let pink = UIColor(red: 0.91, green: 0.58, blue: 0.70, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            paper.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            yellow.setFill()
            context.fill(CGRect(x: 20, y: 40, width: 80, height: 80))
            pink.setFill()
            context.fill(CGRect(x: 140, y: 40, width: 80, height: 80))
        }
        let result = try DocumentImageProcessor(enhancer: DocResEnhancer(model: nil)).apply(.enhanced, to: image)
        func components(_ image: UIImage, x: Int, y: Int) throws -> (CGFloat, CGFloat, CGFloat) {
            let color = try XCTUnwrap(TestImageFactory.pixelColor(of: image, x: x, y: y))
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        }
        let sourcePaper = try components(image, x: 10, y: 20)
        let outputPaper = try components(result, x: 10, y: 20)
        XCTAssertEqual((outputPaper.1 - outputPaper.2) / ((outputPaper.0 + outputPaper.1 + outputPaper.2) / 3),
                       (sourcePaper.1 - sourcePaper.2) / ((sourcePaper.0 + sourcePaper.1 + sourcePaper.2) / 3),
                       accuracy: 0.04)
        let outputYellow = try components(result, x: 60, y: 80)
        let outputPink = try components(result, x: 180, y: 80)
        XCTAssertGreaterThan(abs(outputYellow.0 - outputYellow.2), 0.3)
        XCTAssertGreaterThan(abs(outputPink.0 - outputPink.1), 0.15)
        let yellowGreenBlueContrast = outputYellow.1 / outputYellow.2 - outputPaper.1 / outputPaper.2
        let pinkRedGreenContrast = outputPink.0 / outputPink.1 - outputPaper.0 / outputPaper.1
        XCTAssertGreaterThan(yellowGreenBlueContrast, 2.0)
        XCTAssertGreaterThan(pinkRedGreenContrast, 0.2)
    }

    func testEnhancedKeepsDarkBlueDistinctFromBlack() throws {
        let size = CGSize(width: 128, height: 80)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let darkBlue = UIColor(red: 0.015, green: 0.035, blue: 0.14, alpha: 1)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            darkBlue.setFill()
            context.fill(CGRect(x: 64, y: 0, width: 64, height: size.height))
        }
        let enhanced = try DocumentImageProcessor(enhancer: DocResEnhancer(model: nil))
            .apply(.enhanced, to: image)
        let black = colorComponents(try XCTUnwrap(TestImageFactory.pixelColor(of: enhanced, x: 32, y: 40)))
        let blue = colorComponents(try XCTUnwrap(TestImageFactory.pixelColor(of: enhanced, x: 96, y: 40)))

        XCTAssertLessThan(black.red + black.green + black.blue, 0.02)
        XCTAssertGreaterThan(blue.blue, blue.red + 0.02)
        XCTAssertGreaterThan(blue.red + blue.green + blue.blue,
                             black.red + black.green + black.blue + 0.03)
    }

    func testBlackAndWhitePreservesYellowContrastAcrossGrayAndLightBlueBackgrounds() throws {
        let size = CGSize(width: 450, height: 150)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let backgrounds: [UIColor] = [.init(white: 0.26, alpha: 1), .init(white: 0.30, alpha: 1),
                                      .init(white: 0.36, alpha: 1), .init(white: 0.42, alpha: 1),
                                      .init(red: 0.35, green: 0.62, blue: 0.95, alpha: 1)]
        let backgroundLabels = ["gray 0.26", "gray 0.30", "gray 0.36", "gray 0.42", "light blue"]
        let yellow = UIColor(red: 0.98, green: 0.82, blue: 0.05, alpha: 1)
        let yellowSource = colorComponents(yellow)
        let yellowSourceLuma = 0.299 * Double(yellowSource.red)
            + 0.587 * Double(yellowSource.green) + 0.114 * Double(yellowSource.blue)
        let font = UIFont.systemFont(ofSize: 24)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            for (index, background) in backgrounds.enumerated() {
                background.setFill()
                context.fill(CGRect(x: CGFloat(index * 90), y: 0, width: 90, height: 150))
                ("Y" as NSString).draw(at: CGPoint(x: CGFloat(index * 90 + 28), y: 55),
                    withAttributes: [.font: font, .foregroundColor: yellow])
            }
        }
        let mask = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for index in backgrounds.indices {
                ("Y" as NSString).draw(at: CGPoint(x: CGFloat(index * 90 + 28), y: 55),
                    withAttributes: [.font: font, .foregroundColor: UIColor.white])
            }
        }
        let result = try processor.apply(.blackAndWhite, to: image)
        let pixels = try PageBitmap(XCTUnwrap(result.cgImage))
        let maskPixels = try PageBitmap(XCTUnwrap(mask.cgImage))
        for index in backgrounds.indices {
            var glyph = [Double](), backdrop = [Double]()
            for y in 50..<105 {
                for x in (index * 90 + 12)..<(index * 90 + 78) {
                    if maskPixels.luminance(atX: Double(x), y: Double(y)) > 220 {
                        glyph.append(pixels.luminance(atX: Double(x), y: Double(y)))
                    }
                }
            }
            for y in 115..<140 {
                for x in (index * 90 + 12)..<(index * 90 + 78) {
                    backdrop.append(pixels.luminance(atX: Double(x), y: Double(y)))
                }
            }
            let backgroundRGB = colorComponents(backgrounds[index])
            let backgroundSourceLuma = 0.299 * Double(backgroundRGB.red)
                + 0.587 * Double(backgroundRGB.green) + 0.114 * Double(backgroundRGB.blue)
            let inputDetails = String(format: "background=%@ RGB=(%.3f,%.3f,%.3f) sourceLuma=%.3f yellowRGB=(%.3f,%.3f,%.3f) yellowLuma=%.3f glyphPixels=%d",
                backgroundLabels[index], Double(backgroundRGB.red), Double(backgroundRGB.green),
                Double(backgroundRGB.blue), backgroundSourceLuma, Double(yellowSource.red),
                Double(yellowSource.green), Double(yellowSource.blue), yellowSourceLuma, glyph.count)
            XCTAssertGreaterThan(glyph.count, 5, inputDetails)
            guard glyph.count > 5, !backdrop.isEmpty else { continue }
            let glyphMean = glyph.reduce(0, +) / Double(glyph.count)
            let backdropMean = backdrop.reduce(0, +) / Double(backdrop.count)
            let difference = glyphMean - backdropMean
            let details = String(format: "background=%@ RGB=(%.3f,%.3f,%.3f) sourceLuma=%.3f yellowRGB=(%.3f,%.3f,%.3f) yellowLuma=%.3f glyphPixels=%d outputGlyphMean=%.1f outputBackdropMean=%.1f difference=%.1f",
                backgroundLabels[index], Double(backgroundRGB.red), Double(backgroundRGB.green),
                Double(backgroundRGB.blue), backgroundSourceLuma, Double(yellowSource.red),
                Double(yellowSource.green), Double(yellowSource.blue), yellowSourceLuma, glyph.count,
                glyphMean, backdropMean, difference)
            XCTAssertGreaterThan(abs(difference), 20, "bright ink lost contrast: \(details)")
            if index < 2 {
                XCTAssertGreaterThan(difference, 20, "bright ink should lift from a dark B&W background: \(details)")
            }
            if index == backgrounds.count - 1 {
                XCTAssertLessThan(difference, -20, "light-blue print should retain its dark B&W separation: \(details)")
            }
        }
    }

    func testBlackAndWhiteKeepsNearEqualLumaColoredInkDark() throws {
        let size = CGSize(width: 180, height: 120)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let ink = UIColor(red: 0.10, green: 0.29, blue: 0.95, alpha: 1)
        let font = UIFont.systemFont(ofSize: 28)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.30, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("Y" as NSString).draw(at: CGPoint(x: 70, y: 35),
                                   withAttributes: [.font: font, .foregroundColor: ink])
        }
        let mask = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("Y" as NSString).draw(at: CGPoint(x: 70, y: 35),
                withAttributes: [.font: font, .foregroundColor: UIColor.white])
        }
        let result = try processor.apply(.blackAndWhite, to: image)
        let pixels = try PageBitmap(XCTUnwrap(result.cgImage))
        let maskPixels = try PageBitmap(XCTUnwrap(mask.cgImage))
        var glyph = [Double](), backdrop = [Double]()
        for y in 32..<82 {
            for x in 60..<120 where maskPixels.luminance(atX: Double(x), y: Double(y)) > 220 {
                glyph.append(pixels.luminance(atX: Double(x), y: Double(y)))
            }
        }
        for y in 92..<112 {
            for x in 40..<140 {
                backdrop.append(pixels.luminance(atX: Double(x), y: Double(y)))
            }
        }

        let background = colorComponents(UIColor(white: 0.30, alpha: 1))
        let inkSource = colorComponents(ink)
        let backgroundLuma = 0.299 * Double(background.red) + 0.587 * Double(background.green)
            + 0.114 * Double(background.blue)
        let inkLuma = 0.299 * Double(inkSource.red) + 0.587 * Double(inkSource.green)
            + 0.114 * Double(inkSource.blue)
        let inputDetails = String(format: "background=gray 0.30 RGB=(%.3f,%.3f,%.3f) sourceLuma=%.3f inkRGB=(%.3f,%.3f,%.3f) inkLuma=%.3f glyphPixels=%d",
            Double(background.red), Double(background.green), Double(background.blue), backgroundLuma,
            Double(inkSource.red), Double(inkSource.green), Double(inkSource.blue), inkLuma,
            glyph.count)
        XCTAssertGreaterThan(glyph.count, 5, inputDetails)
        guard glyph.count > 5, !backdrop.isEmpty else { return }
        let glyphMean = glyph.reduce(0, +) / Double(glyph.count)
        let backdropMean = backdrop.reduce(0, +) / Double(backdrop.count)
        let separation = backdropMean - glyphMean
        let details = String(format: "background=gray 0.30 RGB=(%.3f,%.3f,%.3f) sourceLuma=%.3f inkRGB=(%.3f,%.3f,%.3f) inkLuma=%.3f glyphPixels=%d outputGlyphMean=%.1f outputBackdropMean=%.1f separation=%.1f",
            Double(background.red), Double(background.green), Double(background.blue), backgroundLuma,
            Double(inkSource.red), Double(inkSource.green), Double(inkSource.blue), inkLuma,
            glyph.count, glyphMean, backdropMean, separation)
        XCTAssertGreaterThan(separation, 20, "near-equal-luma colored ink should retain its dark separation: \(details)")
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
