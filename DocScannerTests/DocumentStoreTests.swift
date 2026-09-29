import XCTest
@testable import DocScanner

/// DocumentStore の保存・一覧・リネーム・削除のテスト。
final class DocumentStoreTests: XCTestCase {

    /// テストごとの一時ディレクトリ。
    private var tempDir: URL!
    /// テスト対象ストア。
    private var store: DocumentStore!

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 一時ディレクトリを作成し、その場所でストアを初期化する
    override func setUpWithError() throws {
        try super.setUpWithError()
        executionTimeAllowance = 60
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocScannerTests-\(UUID().uuidString)", isDirectory: true)
        store = try DocumentStore(directory: tempDir)
    }

    /// 各テストの後処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 一時ディレクトリを削除する
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// テスト用の 1 ページ PDF データを生成する。
    /// - 入力: なし
    /// - 出力: 1 ページの PDF Data
    /// - 処理: PDFBuilder で単色画像 1 枚から生成する
    private func makePDFData() throws -> Data {
        let image = TestImageFactory.solid(.white, size: CGSize(width: 100, height: 140))
        return try PDFBuilder().makePDF(from: [image], pageSize: .a4)
    }

    /// 保存でファイルが作成され documents に載ることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: save 後にファイル存在・一覧件数・pageCount を検査する
    func testSaveCreatesFileAndEntry() throws {
        let saved = try store.save(pdfData: makePDFData(), name: "Report")
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path))
        XCTAssertEqual(saved.url.pathExtension, "pdf")
        XCTAssertEqual(saved.pageCount, 1)
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(store.documents.first?.name, "Report")
    }

    /// 同名保存時に "(2)" 連番名になることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 同名で 2 回 save し、2 件目のファイル名を検査する
    func testDuplicateNamesGetSuffix() throws {
        _ = try store.save(pdfData: makePDFData(), name: "Report")
        let second = try store.save(pdfData: makePDFData(), name: "Report")
        XCTAssertEqual(second.name, "Report (2)")
        XCTAssertEqual(store.documents.count, 2)
    }

    /// 削除でファイルと一覧エントリが消えることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: save → delete 後にファイル非存在と空一覧を検査する
    func testDeleteRemovesFileAndEntry() throws {
        let saved = try store.save(pdfData: makePDFData(), name: "Report")
        try store.delete(saved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path))
        XCTAssertTrue(store.documents.isEmpty)
    }

    /// リネームでファイルが移動することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: rename 後に旧パス非存在・新パス存在・一覧の名前を検査する
    func testRenameMovesFile() throws {
        let saved = try store.save(pdfData: makePDFData(), name: "Report")
        let renamed = try store.rename(saved, to: "Invoice")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.url.path))
        XCTAssertEqual(store.documents.first?.name, "Invoice")
    }

    /// reload で外部から追加したファイルが拾われることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: ストア経由せずファイルを書き込み reload して一覧を検査する
    func testReloadPicksUpExternalFiles() throws {
        let url = tempDir.appendingPathComponent("External.pdf")
        try makePDFData().write(to: url)
        try store.reload()
        XCTAssertEqual(store.documents.count, 1)
        XCTAssertEqual(store.documents.first?.name, "External")
    }

    /// PDF として読めない *.pdf ファイルがあると reload が unreadableDocument を投げることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 拡張子 pdf のゴミファイルを書き込み reload して DocumentStoreError.unreadableDocument を期待する
    func testGarbagePDFFileThrowsUnreadable() throws {
        let url = tempDir.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: url)
        XCTAssertThrowsError(try store.reload()) { error in
            XCTAssertEqual(error as? DocumentStoreError, .unreadableDocument("broken.pdf"))
        }
    }

    /// 一覧が新しい順に並ぶことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 2 件保存し documents の順序が createdAt 降順であることを検査する
    func testNewestFirstOrdering() throws {
        _ = try store.save(pdfData: makePDFData(), name: "First")
        // 作成日時が確実に変わるよう少し待つ
        Thread.sleep(forTimeInterval: 0.05)
        _ = try store.save(pdfData: makePDFData(), name: "Second")
        XCTAssertEqual(store.documents.count, 2)
        XCTAssertGreaterThanOrEqual(store.documents[0].createdAt, store.documents[1].createdAt)
    }
}
