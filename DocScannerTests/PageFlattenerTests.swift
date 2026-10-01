import XCTest
import CoreGraphics
import Foundation
@testable import DocScanner

/// PageFlattener（マスク輪郭追跡 + Coons パッチ矩形化）のテスト。ML には依存しない。
final class PageFlattenerTests: XCTestCase {

    /// 対象フラットナ。
    private let flattener = PageFlattener()

    /// プレビューでなぞった湾曲輪郭を保存し、解像度が違う写真にも同じ四辺を使う。
    func testSavedCurvedBoundaryIsReusedAtPhotoResolution() throws {
        let size = CGSize(width: 1500, height: 2000)
        let path = curvedPagePath()
        let photo = renderPage(path: path, size: size)
        var scale = CGAffineTransform(scaleX: 0.5, y: 0.5)
        let previewPath = try XCTUnwrap(path.copy(using: &scale))
        let previewSize = CGSize(width: 750, height: 1000)
        let preview = renderPage(path: previewPath, size: previewSize)
        let boundary = try flattener.traceBoundary(preview, corners: [
            CGPoint(x: 100, y: 150), CGPoint(x: 650, y: 175),
            CGPoint(x: 640, y: 875), CGPoint(x: 115, y: 850)
        ], mask: makeMask(path: previewPath, size: previewSize))
        XCTAssertTrue(boundary.isValid)
        XCTAssertEqual(boundary.top.count, 65)
        let straightMidpoint = (boundary.top[0].y + boundary.top[64].y) / 2
        XCTAssertGreaterThan(abs(boundary.top[32].y - straightMidpoint), 0.004)
        let output = try flattener.flatten(photo, boundary: boundary)
        XCTAssertGreaterThan(output.width, 1000)
        XCTAssertGreaterThan(output.height, 1300)
        let result = UIImage(cgImage: output)
        for x in stride(from: 10, to: output.width - 10, by: 100) {
            let color = try XCTUnwrap(TestImageFactory.pixelColor(of: result, x: x, y: 10))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            XCTAssertGreaterThan((red + green + blue) / 3, 0.8)
        }
    }

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// ホモグラフィが四隅を矩形の角へ写し、逆変換で往復できることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 台形 4 点から homography/逆行列を求め、写像先と往復誤差を 1e-6 で検査する
    func testHomographyMapsCornersAndRoundTrips() throws {
        let src = [
            PagePoint(x: 100, y: 50), PagePoint(x: 900, y: 80),
            PagePoint(x: 950, y: 1400), PagePoint(x: 80, y: 1350)
        ]
        let dst = [
            PagePoint(x: 0, y: 0), PagePoint(x: 800, y: 0),
            PagePoint(x: 800, y: 1200), PagePoint(x: 0, y: 1200)
        ]
        let h = try PageGeometry.homography(from: src, to: dst)
        for i in 0..<4 {
            let mapped = PageGeometry.apply(h, to: src[i])
            XCTAssertEqual(mapped.x, dst[i].x, accuracy: 1e-6)
            XCTAssertEqual(mapped.y, dst[i].y, accuracy: 1e-6)
        }
        let inv = try PageGeometry.homography(from: dst, to: src)
        for i in 0..<4 {
            let round = PageGeometry.apply(inv, to: PageGeometry.apply(h, to: src[i]))
            XCTAssertEqual(round.x, src[i].x, accuracy: 1e-6)
            XCTAssertEqual(round.y, src[i].y, accuracy: 1e-6)
        }
    }

    /// 曲線辺を持つページで、背景が残らず出力サイズが弧長相当になることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 上辺・下辺 ±40px、左辺 30px に湾曲した白ページ（暗い背景 + 黒バー）を
    ///   1500x2000 で描き、同形状の 150x200 マスクと四隅で flatten。
    ///   出力外周 6px の平均輝度 > 200、サイズが矩形弧長の ±5% 以内を検査する
    func testCurvedPageFlattensToFilledRectangle() throws {
        let size = CGSize(width: 1500, height: 2000)
        let path = curvedPagePath()
        let image = renderPage(path: path, size: size)
        let mask = makeMask(path: path, size: size)
        let corners: [CGPoint] = [
            CGPoint(x: 200, y: 300), CGPoint(x: 1300, y: 350),
            CGPoint(x: 1280, y: 1750), CGPoint(x: 230, y: 1700)
        ]
        let output = try flattener.flatten(image, corners: corners, mask: mask)
        let result = UIImage(cgImage: output)

        // 外周 6px バンドに背景（暗灰）が残っていないこと
        for y in [0, 2, 5, output.height - 6, output.height - 3, output.height - 1] {
            for x in stride(from: 0, to: output.width, by: 60) {
                let color = try XCTUnwrap(
                    TestImageFactory.pixelColor(of: result, x: x, y: y))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThan((r + g + b) / 3, 200.0 / 255.0,
                                     "border pixel (\(x),\(y)) = \(r)")
            }
        }
        for x in [0, 5, output.width - 6, output.width - 1] {
            for y in stride(from: 0, to: output.height, by: 80) {
                let color = try XCTUnwrap(
                    TestImageFactory.pixelColor(of: result, x: x, y: y))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThan((r + g + b) / 3, 200.0 / 255.0,
                                     "border pixel (\(x),\(y)) = \(r)")
            }
        }

        // 出力サイズは四辺の平均弧長（矩形化後）の ±5% 以内
        let topLen = PagePoint(x: 1300, y: 350) - PagePoint(x: 200, y: 300)
        let bottomLen = PagePoint(x: 1280, y: 1750) - PagePoint(x: 230, y: 1700)
        let leftLen = PagePoint(x: 230, y: 1700) - PagePoint(x: 200, y: 300)
        let rightLen = PagePoint(x: 1280, y: 1750) - PagePoint(x: 1300, y: 350)
        let expectedW = (topLen.length + bottomLen.length) / 2
        let expectedH = (leftLen.length + rightLen.length) / 2
        XCTAssertEqual(Double(output.width), expectedW, accuracy: expectedW * 0.05)
        XCTAssertEqual(Double(output.height), expectedH, accuracy: expectedH * 0.05)
    }

    /// 直線辺の矩形ページでは出力がほぼそのままの切り出しになることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 軸平行な矩形ページ + 同形状マスクで flatten し、
    ///   出力サイズがページ辺長の ±2% 以内であることを検査する
    func testStraightRectangleOutputsPageCrop() throws {
        let size = CGSize(width: 1500, height: 2000)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 200, y: 300))
        path.addLine(to: CGPoint(x: 1300, y: 300))
        path.addLine(to: CGPoint(x: 1300, y: 1700))
        path.addLine(to: CGPoint(x: 200, y: 1700))
        path.closeSubpath()
        let image = renderPage(path: path, size: size)
        let mask = makeMask(path: path, size: size)
        let corners: [CGPoint] = [
            CGPoint(x: 200, y: 300), CGPoint(x: 1300, y: 300),
            CGPoint(x: 1300, y: 1700), CGPoint(x: 200, y: 1700)
        ]
        let output = try flattener.flatten(image, corners: corners, mask: mask)
        XCTAssertEqual(Double(output.width), 1100, accuracy: 1100 * 0.02)
        XCTAssertEqual(Double(output.height), 1400, accuracy: 1400 * 0.02)
    }

    /// 上原点 raw 画像とマスクで、ページ位置・上下マーカーを保って flatten することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 非対称な 100x150 RGBA 画像・上原点マスク・縦オフセット四角形で
    ///   PageBitmap のサンプルと出力の上下マーカー位置を確認する
    func testTopOriginAsymmetricImageAndMaskKeepMarkerPositions() throws {
        let image = try makeTopOriginRawImage(width: 100, height: 150)
        let bitmap = try PageBitmap(image)
        let topSourceOffset = (50 * bitmap.width + 37) * 4
        let bottomSourceOffset = (109 * bitmap.width + 63) * 4
        XCTAssertGreaterThan(bitmap.data[topSourceOffset], 200)
        XCTAssertLessThan(bitmap.data[topSourceOffset + 2], 80)
        XCTAssertLessThan(bitmap.data[bottomSourceOffset], 80)
        XCTAssertGreaterThan(bitmap.data[bottomSourceOffset + 2], 200)

        let corners = [
            CGPoint(x: 20, y: 30), CGPoint(x: 80, y: 30),
            CGPoint(x: 80, y: 130), CGPoint(x: 20, y: 130)
        ]
        let mask = makeTopOriginMask(width: 100, height: 150)
        let output = try flattener.flatten(image, corners: corners, mask: mask)
        let outputBitmap = try PageBitmap(output)
        let topX = Int(Double(output.width) * 0.28)
        let topY = Int(Double(output.height) * 0.21)
        let bottomX = Int(Double(output.width) * 0.75)
        let bottomY = Int(Double(output.height) * 0.79)
        let topOffset = (topY * outputBitmap.width + topX) * 4
        let bottomOffset = (bottomY * outputBitmap.width + bottomX) * 4
        XCTAssertGreaterThan(outputBitmap.data[topOffset], 180)
        XCTAssertLessThan(outputBitmap.data[topOffset + 2], 80)
        XCTAssertLessThan(outputBitmap.data[bottomOffset], 80)
        XCTAssertGreaterThan(outputBitmap.data[bottomOffset + 2], 180)
    }

    /// 上下辺 ±40px・左辺 30px に湾曲したページ形状の CGPath を返す。
    /// - 入力: なし
    /// - 出力: 左上→右上→右下→左下の閉パス（左上原点座標）
    /// - 処理: 各辺を二次曲線（control を外向きにずらす）で結ぶ
    private func curvedPagePath() -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 200, y: 300))
        // 上辺は上に 40px 膨らむ
        path.addQuadCurve(to: CGPoint(x: 1300, y: 350),
                          control: CGPoint(x: 750, y: 265))
        // 右辺はほぼ直線（軽い膨らみ）
        path.addQuadCurve(to: CGPoint(x: 1280, y: 1750),
                          control: CGPoint(x: 1310, y: 1050))
        // 下辺は下に 40px 膨らむ（右→左へ描く）
        path.addQuadCurve(to: CGPoint(x: 230, y: 1700),
                          control: CGPoint(x: 760, y: 1790))
        // 左辺は左に 30px 膨らむ（下→上へ描く）
        path.addQuadCurve(to: CGPoint(x: 200, y: 300),
                          control: CGPoint(x: 170, y: 1000))
        path.closeSubpath()
        return path
    }

    /// 暗灰背景 + 白いページ形状 + 黒い横バーの合成画像を描画する。
    /// - 入力: path … ページ形状（左上原点）、size … 画像サイズ
    /// - 出力: 描画済み CGImage
    /// - 処理: 背景を 40 の灰で塗り、パスを白で塗り、内部に黒バーを数本描く
    private func renderPage(path: CGPath, size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 40.0 / 255.0, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.addPath(path)
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.fillPath()
            UIColor.black.setFill()
            for i in 0..<8 {
                ctx.fill(CGRect(x: 400, y: 500 + i * 140, width: 700, height: 20))
            }
        }.cgImage!
    }

    /// ページ形状と同じ形を低解像度でラスタライズした合成マスクを返す。
    /// - 入力: path … ページ形状、size … 画像サイズ
    /// - 出力: 150x200 の SegmentationMask（内部=1、外部=0）
    /// - 処理: グレー 8bit コンテキストにスケール済みパスを白塗りして Float 化する
    private func makeMask(path: CGPath, size: CGSize) -> SegmentationMask {
        let mw = 150
        let mh = 200
        var buf = [UInt8](repeating: 0, count: mw * mh)
        let context = CGContext(
            data: &buf, width: mw, height: mh, bitsPerComponent: 8,
            bytesPerRow: mw, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        // 生の CGBitmapContext は左下原点なので、左上原点のパス座標と
        // 行が上から順のマスクレイアウトに合わせるため上下を反転してから描く
        context.translateBy(x: 0, y: CGFloat(mh))
        context.scaleBy(x: Double(mw) / Double(size.width),
                        y: -Double(mh) / Double(size.height))
        context.addPath(path)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath()
        let values = buf.map { Float($0) / 255 }
        return SegmentationMask(width: mw, height: mh, values: values,
                                imageWidth: Int(size.width), imageHeight: Int(size.height))
    }

    private func makeTopOriginRawImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let isPage = (20..<80).contains(x) && (30..<130).contains(y)
                let color: (UInt8, UInt8, UInt8) = {
                    if (30..<45).contains(x) && (44..<59).contains(y) { return (255, 0, 0) }
                    if (56..<71).contains(x) && (102..<117).contains(y) { return (0, 0, 255) }
                    return isPage ? (245, 245, 245) : (40, 40, 40)
                }()
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeTopOriginMask(width: Int, height: Int) -> SegmentationMask {
        var values = [Float](repeating: 0, count: width * height)
        for y in 30..<130 {
            for x in 20..<80 {
                values[y * width + x] = 1
            }
        }
        return SegmentationMask(width: width, height: height, values: values,
                                imageWidth: width, imageHeight: height)
    }
}
