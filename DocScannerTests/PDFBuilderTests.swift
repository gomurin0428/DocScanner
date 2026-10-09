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

    /// fitImage は画像のピクセル寸法を 300 DPI で pt に変換することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 1 ページ目の mediaBox を画像サイズと比較する
    func testFitImagePageBounds() throws {
        let image = TestImageFactory.solid(.white, size: CGSize(width: 320, height: 240))
        let data = try PDFBuilder().makePDF(from: [image], pageSize: .fitImage)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 320 * 72.0 / 300.0, accuracy: 1)
        XCTAssertEqual(bounds.height, 240 * 72.0 / 300.0, accuracy: 1)
    }

    /// A4/Letter 寸法と画像が一致しても固定用紙のマージンが適用されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 用紙と同寸の黒画像を PDF 化し、18pt 外周は白・内側は黒を確認する
    func testFixedPageSizesKeepMarginsForMatchingImageDimensions() throws {
        for pageSize in [PDFPageSize.a4, .letter] {
            let size = try XCTUnwrap(pageSize.fixedSize)
            let image = TestImageFactory.solid(.black, size: size)
            let data = try PDFBuilder().makePDF(from: [image], pageSize: pageSize)
            let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
            let rendered = page.thumbnail(of: size, for: .mediaBox)

            XCTAssertGreaterThan(try luminance(of: rendered, x: 5, y: 5), 0.9)
            XCTAssertLessThan(try luminance(of: rendered, x: 30, y: 30), 0.1)
        }
    }

    /// .fitImage は画像をページ端まで描くことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 黒画像を Fit to Image PDF にし、隅の画素が黒いことを確認する
    func testFitImageDrawsEdgeToEdge() throws {
        let image = TestImageFactory.solid(.black, size: CGSize(width: 320, height: 240))
        let data = try PDFBuilder().makePDF(from: [image], pageSize: .fitImage)
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        let rendered = page.thumbnail(of: page.bounds(for: .mediaBox).size, for: .mediaBox)
        XCTAssertLessThan(try luminance(of: rendered, x: 1, y: 1), 0.1)
    }

    func testFitImageUsesUprightOrientationAndPixelDimensions() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let up = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 120), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 60))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 60, width: 80, height: 60))
        }
        let rawRight = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 80))
            UIColor.white.setFill()
            context.fill(CGRect(x: 60, y: 0, width: 60, height: 80))
        }
        let right = UIImage(cgImage: try XCTUnwrap(rawRight.cgImage), scale: 1, orientation: .right)
        let pages = [up, right]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("orientation-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try PDFBuilder.writePDF(pageCount: pages.count, to: url, pageSize: .fitImage,
                                imageForPage: { pages[$0] }, progress: { _ in })
        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertEqual(document.pageCount, 2)
        let bounds = try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox)
        XCTAssertEqual(bounds.width, 80 * 72.0 / 300.0, accuracy: 1)
        XCTAssertEqual(bounds.height, 120 * 72.0 / 300.0, accuracy: 1)
        for index in pages.indices {
            let page = try XCTUnwrap(document.page(at: index))
            let rendered = page.thumbnail(of: CGSize(width: 200, height: 300), for: .mediaBox)
            XCTAssertLessThan(try luminance(of: rendered, x: 100, y: 30), 0.15, "page \(index) top")
            XCTAssertGreaterThan(try luminance(of: rendered, x: 100, y: 270), 0.85, "page \(index) bottom")
        }
    }

    func testStreamingProviderIsLazyAndRemovesPartialFileOnFailure() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocScanner-stream-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        var requested: [Int] = []
        var progressed: [Int] = []

        XCTAssertThrowsError(try PDFBuilder.writePDF(
            pageCount: 4,
            to: url,
            pageSize: .letter,
            imageForPage: { index in
                requested.append(index)
                if index == 2 { throw DocumentStoreError.invalidPDF }
                return TestImageFactory.solid(.white, size: CGSize(width: 80, height: 120))
            },
            progress: { progressed.append($0) }
        ))

        XCTAssertEqual(requested, [0, 1, 2])
        XCTAssertEqual(progressed, [1, 2])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testStreamingCancellationRemovesPartialFile() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocScanner-cancel-\(UUID().uuidString).pdf")
        let enteredProvider = DispatchSemaphore(value: 0)
        let releaseProvider = DispatchSemaphore(value: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = Task.detached {
            try PDFBuilder.writePDF(pageCount: 2, to: url, pageSize: .a4, imageForPage: { _ in
                enteredProvider.signal()
                releaseProvider.wait()
                return TestImageFactory.solid(.white, size: CGSize(width: 80, height: 120))
            }, progress: { _ in })
        }
        XCTAssertEqual(enteredProvider.wait(timeout: .now() + 5), .success)
        writer.cancel()
        releaseProvider.signal()

        do {
            try await writer.value
            XCTFail("Cancelled PDF generation should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
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

    private func luminance(of image: UIImage, x: Int, y: Int) throws -> CGFloat {
        let color = try XCTUnwrap(TestImageFactory.pixelColor(of: image, x: x, y: y))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red + green + blue) / 3
    }
}
