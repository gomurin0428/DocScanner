import XCTest
import Vision
@testable import DocScanner

/// DocumentDetector の書類検出・台形補正のテスト。
final class DocumentDetectorTests: XCTestCase {

    /// 対象検出器。
    private let detector = DocumentDetector(unwarper: UVDocUnwarper(model: nil))

    func testDetectsSmallDocumentWithoutLoadingModel() throws {
        try assertDetectedPaper(CGRect(x: 430, y: 600, width: 140, height: 200))
    }

    func testModelLoadFailureIsCachedAndPropagatedWithoutFallback() throws {
        let underlying = NSError(domain: "UVDocTests", code: 7)
        var loadCount = 0
        let unwarper = UVDocUnwarper(modelLoader: {
            loadCount += 1
            throw underlying
        })
        let detector = DocumentDetector(unwarper: unwarper)
        let image = TestImageFactory.gradient(size: CGSize(width: 512, height: 768))
        let boundary = DocumentBoundary(corners: [
            CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.9),
            CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.1)
        ])
        for _ in 0..<2 {
            XCTAssertThrowsError(try detector.correct(image, boundary: boundary)) { error in
                guard let loadingError = error as? UVDocModelLoadingError else {
                    XCTFail("Expected UVDoc loading error, got \(error)")
                    return
                }
                XCTAssertEqual((loadingError.underlyingError as NSError?)?.domain, underlying.domain)
                XCTAssertEqual((loadingError.underlyingError as NSError?)?.code, underlying.code)
            }
        }
        XCTAssertEqual(loadCount, 1)
    }

    /// 縦横比 0.18 のレシートを補正できることを検証する。
    /// - 入力: 細長い合成紙
    /// - 出力: なし
    /// - 処理: 検出後の寸法が紙領域と一致するか確認する
    func testDetectsNarrowReceipt() throws {
        try assertDetectedPaper(CGRect(x: 410, y: 200, width: 180, height: 1000))
    }

    /// 内側の小さな枠より紙全体を優先することを検証する。
    /// - 入力: 順番を入れ替えた二つの候補
    /// - 出力: なし
    /// - 処理: 入力順に依存せず紙を選び、候補なしなら nil となるか確認する
    func testSelectsPaperInsteadOfFirstInnerRectangle() {
        let paper = VNRectangleObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6))
        let inner = VNRectangleObservation(boundingBox: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
        for observations in [[inner, paper], [paper, inner]] {
            XCTAssertEqual(DocumentRectangleDetector.preferred(in: observations)?.boundingBox,
                           paper.boundingBox)
        }
        XCTAssertNil(DocumentRectangleDetector.preferred(in: []))
    }

    /// 合成紙の検出・補正結果を照合する。
    /// - 入力: 暗背景上の紙の矩形
    /// - 出力: なし（検出失敗は throw）
    /// - 処理: 1000×1400 画像を生成し、補正後寸法を 10px の誤差で比較する
    private func assertDetectedPaper(_ paper: CGRect) throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let size = CGSize(width: 1000, height: 1400)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.95, alpha: 1).setFill()
            context.fill(paper)
        }
        let corrected = try detector.detectAndCorrect(image)
        let pixels = TestImageFactory.pixelSize(of: corrected)
        XCTAssertEqual(pixels.width, paper.width, accuracy: 10)
        XCTAssertEqual(pixels.height, paper.height, accuracy: 10)
    }

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

    /// 補正結果が上下・左右反転せず書類領域のみに切り出されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 上辺側に黒マーカーを持つ歪んだ書類を補正し、
    ///   (a) 左上付近が暗い（マーカー）＝反転していない、
    ///   (b) 四隅 3% 内側が紙色＝背景が混入していない、を検査する。
    ///   Vision→CIImage 座標変換で y を反転させる旧実装ではこのテストは失敗する
    func testCorrectedImageIsNotMirroredAndCropsToDocument() throws {
        let image = TestImageFactory.markedSkewedDocument()
        let corrected = try detector.detectAndCorrect(image)
        let pixel = TestImageFactory.pixelSize(of: corrected)

        // 画像内の割合位置の明度をサンプリングする
        func brightness(_ fx: CGFloat, _ fy: CGFloat) -> CGFloat {
            let x = min(Int(pixel.width * fx), Int(pixel.width) - 1)
            let y = min(Int(pixel.height * fy), Int(pixel.height) - 1)
            guard let color = TestImageFactory.pixelColor(of: corrected, x: x, y: y) else {
                return -1
            }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return (red + green + blue) / 3
        }

        // (a) マーカー（左上付近）は暗く、左下・右下は紙の明るさ（＝上下/左右反転していない）
        XCTAssertLessThan(brightness(0.14, 0.14), 0.4, "marker should be dark at top-left")
        XCTAssertGreaterThan(brightness(0.14, 0.86), 0.7, "bottom-left should be paper")
        XCTAssertGreaterThan(brightness(0.86, 0.86), 0.7, "bottom-right should be paper")
        XCTAssertGreaterThan(brightness(0.86, 0.14), 0.7, "top-right should be paper")

        // (b) 四隅 3% 内側は紙色（背景が混ざらない切り出し）
        for (fx, fy) in [(0.03, 0.03), (0.97, 0.03), (0.03, 0.97), (0.97, 0.97)] {
            XCTAssertGreaterThan(brightness(fx, fy), 0.7,
                                 "corner (\(fx),\(fy)) should be paper, not background")
        }
    }

    /// quadsAgree の閾値判定を検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 同一四角形は true、1 角 5% 移動は true、1 角 12% 移動は false、
    ///   個数違いは false であることを検査する
    func testQuadsAgreeThreshold() {
        let a: [CGPoint] = [
            CGPoint(x: 0.2, y: 0.8), CGPoint(x: 0.8, y: 0.8),
            CGPoint(x: 0.8, y: 0.2), CGPoint(x: 0.2, y: 0.2)
        ]
        XCTAssertTrue(DocumentDetector.quadsAgree(a, a, width: 1000, height: 1000))
        // 1 角を 5% (max(W,H) の 5%) だけずらす → 閾値内で一致
        var near = a
        near[0] = CGPoint(x: 0.2 + 0.05, y: 0.8)
        XCTAssertTrue(DocumentDetector.quadsAgree(a, near, width: 1000, height: 1000))
        // 1 角を 12% ずらす → 閾値超過で不一致
        var far = a
        far[0] = CGPoint(x: 0.2 + 0.12, y: 0.8)
        XCTAssertFalse(DocumentDetector.quadsAgree(a, far, width: 1000, height: 1000))
        // 個数違いは不一致
        XCTAssertFalse(DocumentDetector.quadsAgree(Array(a.dropLast()), a,
                                                   width: 1000, height: 1000))
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
