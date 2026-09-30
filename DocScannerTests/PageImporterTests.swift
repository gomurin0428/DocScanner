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

    /// 実際の検出結果が混在画像の入力順を保持することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 未検出・検出・未検出・検出の画像を順に渡し、Entry の並びを確認する
    func testMakePagesPreservesSourceOrder() throws {
        let blank = TestImageFactory.solid(UIColor(white: 0.5, alpha: 1),
                                           size: CGSize(width: 400, height: 300))
        let document = Self.makeDocumentImage(size: CGSize(width: 1200, height: 1600))
        let result = try importer.makePages(from: [blank, document, blank, document])

        XCTAssertEqual(result.entries.count, 4)
        XCTAssertEqual(result.entries.map { entry in
            switch entry {
            case .detected(_): return "detected"
            case .undetected(_): return "undetected"
            }
        }, ["undetected", "detected", "undetected", "detected"])
    }

    /// フル画像採用時に交互の検出結果を入力順へ再構成することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: [未検出, 検出, 未検出, 検出] の Entry から色マーカー順を確認する
    func testImportResultAcceptsUndetectedPagesInInputOrder() throws {
        let result = makeInterleavedResult()
        let pages = result.pages(includingUndetected: true)
        let expected = [UIColor.red, .green, .blue, .yellow]

        XCTAssertEqual(pages.count, expected.count)
        for (page, color) in zip(pages, expected) {
            let actual = try XCTUnwrap(TestImageFactory.pixelColor(of: page.baseImage, x: 5, y: 5))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            actual.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            var expectedRed: CGFloat = 0, expectedGreen: CGFloat = 0
            var expectedBlue: CGFloat = 0, expectedAlpha: CGFloat = 0
            color.getRed(&expectedRed, green: &expectedGreen,
                         blue: &expectedBlue, alpha: &expectedAlpha)
            XCTAssertEqual(red, expectedRed, accuracy: 0.05)
            XCTAssertEqual(green, expectedGreen, accuracy: 0.05)
            XCTAssertEqual(blue, expectedBlue, accuracy: 0.05)
        }
    }

    /// キャンセル時は既存ページの後ろに検出済み項目だけを入力順で追加することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 交互結果の undetected を除外し、既存ページが先頭に残ることを確認する
    func testImportResultCancelKeepsDetectedPagesAfterExistingPages() {
        let result = makeInterleavedResult()
        let existing = ScannedPage(baseImage: TestImageFactory.solid(.black, size: CGSize(width: 10, height: 10)))
        let draft = DocumentDraft(pages: [existing])

        draft.append(result.pages(includingUndetected: false))

        XCTAssertEqual(draft.pages.map(\.id),
                       [existing.id, result.detectedPages[0].id, result.detectedPages[1].id])
    }

    private func makeInterleavedResult() -> ImportResult {
        let red = TestImageFactory.solid(.red, size: CGSize(width: 10, height: 10))
        let green = TestImageFactory.solid(.green, size: CGSize(width: 10, height: 10))
        let blue = TestImageFactory.solid(.blue, size: CGSize(width: 10, height: 10))
        let yellow = TestImageFactory.solid(.yellow, size: CGSize(width: 10, height: 10))
        return ImportResult(entries: [
            .undetected(red),
            .detected(ScannedPage(baseImage: green)),
            .undetected(blue),
            .detected(ScannedPage(baseImage: yellow))
        ])
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
