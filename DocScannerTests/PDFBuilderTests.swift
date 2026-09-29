import PDFKit
import XCTest
@testable import DocScanner

/// PDFBuilder のページ生成・ページサイズのテスト。
final class PDFBuilderTests: XCTestCase {

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// 3 枚の画像から 3 ページの PDF が生成されることを検証する。
    /// - 入力: なし
    /// - 出力: なし（失敗時は XCTFail）
    /// - 処理: PDF を生成して PDFDocument の pageCount を検査する
    func testMakePDFProducesThreePages() throws {
        let images = (0..<3).map { _ in
            TestImageFactory.solid(.white, size: CGSize(width: 100, height: 140))
        }
        let data = try PDFBuilder().makePDF(from: images, pageSize: .a4)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 3)
    }

    /// A4 指定時のページ境界が 595x842pt であることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 1 ページ目の mediaBox を検査する
    func testA4PageBounds() throws {
        let image = TestImageFactory.solid(.white, size: CGSize(width: 100, height: 140))
        let data = try PDFBuilder().makePDF(from: [image], pageSize: .a4)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 595, accuracy: 1)
        XCTAssertEqual(bounds.height, 842, accuracy: 1)
    }

    /// Letter 指定時のページ境界が 612x792pt であることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 1 ページ目の mediaBox を検査する
    func testLetterPageBounds() throws {
        let image = TestImageFactory.solid(.white, size: CGSize(width: 100, height: 140))
        let data = try PDFBuilder().makePDF(from: [image], pageSize: .letter)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 612, accuracy: 1, "bounds=\(bounds)")
        XCTAssertEqual(bounds.height, 792, accuracy: 1, "bounds=\(bounds)")
    }

    /// fitImage 指定時にページ境界が画像の pt サイズと一致することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 1 ページ目の mediaBox を画像サイズと比較する
    func testFitImagePageBounds() throws {
        let image = TestImageFactory.solid(.white, size: CGSize(width: 320, height: 240))
        let data = try PDFBuilder().makePDF(from: [image], pageSize: .fitImage)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 320, accuracy: 1)
        XCTAssertEqual(bounds.height, 240, accuracy: 1)
    }

    /// 空配列で noPages エラーが送出されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: makePDF を呼び PDFBuilderError.noPages が飛ぶことを検査する
    func testEmptyImagesThrowsNoPages() {
        XCTAssertThrowsError(try PDFBuilder().makePDF(from: [], pageSize: .a4)) { error in
            XCTAssertEqual(error as? PDFBuilderError, .noPages)
        }
    }
}
