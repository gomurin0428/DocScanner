import XCTest
import PDFKit
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

    /// 同じ名前（空白を含み sanitize 後に一致）へのリネームでは移動しないことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 保存後に空白付き同名を指定し、同一 SavedDocument とファイルを保つ
    func testRenameToSanitizedSameNameIsNoOp() throws {
        let saved = try store.save(pdfData: makePDFData(), name: "Report")
        let renamed = try store.rename(saved, to: "  Report  ")
        XCTAssertEqual(renamed, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path))
        XCTAssertEqual(store.documents.map(\.url.lastPathComponent), ["Report.pdf"])
    }

    /// 複数オフセット削除が reload による index 変化の影響を受けないことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 3 PDF の初期一覧で index 1,2 を削除し、初期 index 0 のみ残す
    func testDeleteAtOffsetsKeepsOnlyInitialIndexZero() throws {
        _ = try store.save(pdfData: makePDFData(), name: "First")
        _ = try store.save(pdfData: makePDFData(), name: "Second")
        _ = try store.save(pdfData: makePDFData(), name: "Third")
        let initialFirst = try XCTUnwrap(store.documents.first)

        try store.delete(at: IndexSet([1, 2]))

        XCTAssertEqual(store.documents.map(\.url.lastPathComponent),
                       [initialFirst.url.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: initialFirst.url.path))
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

    /// 読めない PDF は全体の reload を失敗させず issue entry として保持する。
    func testGarbagePDFIsPreservedAsUnreadableIssue() throws {
        let url = tempDir.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: url)
        try store.reload()
        let issue = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(issue.url, url)
        XCTAssertEqual(issue.pageCount, 0)
        XCTAssertEqual(issue.issue, DocumentStoreError.unreadableDocument("broken.pdf").localizedDescription)
    }

    func testLockedPDFIsPreservedAsUnreadableIssue() throws {
        let url = tempDir.appendingPathComponent("locked.pdf")
        let pdf = try XCTUnwrap(PDFDocument(data: makePDFData()))
        XCTAssertTrue(pdf.write(to: url, withOptions: [
            .ownerPasswordOption: "owner",
            .userPasswordOption: "user"
        ]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: url)).isLocked)

        try store.reload()

        let issue = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(issue.url, url)
        XCTAssertEqual(issue.pageCount, 0)
        XCTAssertEqual(issue.issue, DocumentStoreError.unreadableDocument("locked.pdf").localizedDescription)
    }

    func testHiddenPDFIsEnumeratedAndCanBeRenamed() throws {
        let hidden = tempDir.appendingPathComponent(".memo.pdf")
        try makePDFData().write(to: hidden)
        try store.reload()

        let entry = try XCTUnwrap(store.documents.first)
        XCTAssertEqual(entry.url.lastPathComponent, ".memo.pdf")
        XCTAssertTrue(entry.isReadable)

        let renamed = try store.rename(entry, to: "Visible")
        XCTAssertEqual(renamed.url.lastPathComponent, "Visible.pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: hidden.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.url.path))
    }

    func testLeadingDotSaveAndRenameRejectWithoutChangingFiles() throws {
        let saved = try store.save(pdfData: makePDFData(), name: "Report")
        let original = try Data(contentsOf: saved.url)

        XCTAssertThrowsError(try store.rename(saved, to: ".memo")) { error in
            XCTAssertEqual(error as? FileNameError, .hiddenName)
        }
        XCTAssertThrowsError(try store.save(pdfData: makePDFData(), name: ".memo")) { error in
            XCTAssertEqual(error as? FileNameError, .hiddenName)
        }

        XCTAssertEqual(try Data(contentsOf: saved.url), original)
        XCTAssertEqual(store.documents.map(\.url.lastPathComponent), ["Report.pdf"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: tempDir.path), ["Report.pdf"])
    }

    func testReloadAsyncPublishesScannedSnapshot() async throws {
        let external = tempDir.appendingPathComponent("External.pdf")
        try makePDFData().write(to: external)
        let unloaded = try DocumentStore(directory: tempDir, loadExisting: false)
        XCTAssertFalse(unloaded.isLoaded)

        try await unloaded.reloadAsync()

        XCTAssertTrue(unloaded.isLoaded)
        XCTAssertEqual(unloaded.documents.map(\.name), ["External"])
    }

    /// シンボリックリンク経由のディレクトリでも保存・リネームが機能することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 実ディレクトリへの symlink パスでストアを初期化し、
    ///   save 成功・同名リネームで " (2)" が付かない・別名リネーム成功を検査する。
    ///   実機では contentsOfDirectory が解決済みパス（/private/var 等）を返し
    ///   URL 等価比較が失敗するため、ファイル名比較の回帰テストとする
    func testSymlinkedDirectorySaveAndRename() throws {
        let fm = FileManager.default
        let realDir = fm.temporaryDirectory
            .appendingPathComponent("DocScannerTests-real-\(UUID().uuidString)", isDirectory: true)
        let linkDir = fm.temporaryDirectory
            .appendingPathComponent("DocScannerTests-link-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: realDir) }
        try fm.createSymbolicLink(at: linkDir, withDestinationURL: realDir)
        defer { try? fm.removeItem(at: linkDir) }

        // symlink を親に持つパスで初期化（実機の /private/var vs /var 相当を再現）
        let linkedStore = try DocumentStore(directory: linkDir.appendingPathComponent("Scans"))
        let saved = try linkedStore.save(pdfData: makePDFData(), name: "Report")
        XCTAssertEqual(saved.name, "Report")

        // 同名へのリネームは同一ファイルなので " (2)" にならない
        let same = try linkedStore.rename(saved, to: "Report")
        XCTAssertEqual(same.name, "Report")
        XCTAssertEqual(same, saved)
        XCTAssertTrue(fm.fileExists(atPath: saved.url.path))
        XCTAssertEqual(linkedStore.documents.count, 1)

        // 別名へのリネームは成功する
        let renamed = try linkedStore.rename(same, to: "Invoice")
        XCTAssertEqual(renamed.name, "Invoice")
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
