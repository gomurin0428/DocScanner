import XCTest
@testable import DocScanner

/// DocumentDraft のページ操作メソッドのテスト。
final class DocumentDraftTests: XCTestCase {

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// テスト用の小さなダミーページを生成する。
    /// - 入力: なし
    /// - 出力: 100x80 グレー画像の ScannedPage
    /// - 処理: TestImageFactory.solid で生成する
    private func makePage() -> ScannedPage {
        ScannedPage(baseImage: TestImageFactory.solid(.gray, size: CGSize(width: 100, height: 80)))
    }

    /// setFilter が指定 id のページだけ書き換えることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 2 ページの下書きで 1 枚目に grayscale を設定し、2 枚目が不変を確認する
    func testSetFilterUpdatesOnlyTargetPage() {
        let page1 = makePage(), page2 = makePage()
        let draft = DocumentDraft(pages: [page1, page2])
        draft.setFilter(.grayscale, for: page1.id)
        XCTAssertEqual(draft.page(id: page1.id)?.filter, .grayscale)
        XCTAssertEqual(draft.page(id: page2.id)?.filter, .original)
    }

    /// rotate が quarterTurns を加算することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: +1 → +1 → -1 で 1 になることを確認する
    func testRotateAccumulatesQuarterTurns() {
        let page = makePage()
        let draft = DocumentDraft(pages: [page])
        draft.rotate(by: 1, for: page.id)
        draft.rotate(by: 1, for: page.id)
        draft.rotate(by: -1, for: page.id)
        XCTAssertEqual(draft.page(id: page.id)?.quarterTurns, 1)
    }

    /// remove がページを削除し page(id:) が nil を返すことを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 削除後に count と検索結果を確認する
    func testRemoveDeletesPage() {
        let page1 = makePage(), page2 = makePage()
        let draft = DocumentDraft(pages: [page1, page2])
        draft.remove(id: page1.id)
        XCTAssertEqual(draft.pages.count, 1)
        XCTAssertNil(draft.page(id: page1.id))
        XCTAssertNotNil(draft.page(id: page2.id))
    }

    /// move が要素を並べ替えることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: [A,B,C] で index 0 を 3 へ移動し [B,C,A] になることを確認する
    func testMoveReordersPages() {
        let a = makePage(), b = makePage(), c = makePage()
        let draft = DocumentDraft(pages: [a, b, c])
        draft.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        XCTAssertEqual(draft.pages.map(\.id), [b.id, c.id, a.id])
    }

    /// append が末尾へページを追加することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 1 ページに 2 ページ追加し順序を確認する
    func testAppendAddsPagesAtEnd() {
        let a = makePage(), b = makePage(), c = makePage()
        let draft = DocumentDraft(pages: [a])
        draft.append([b, c])
        XCTAssertEqual(draft.pages.map(\.id), [a.id, b.id, c.id])
    }

    /// applyFilterToAll が全ページへフィルタを適用することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 3 ページへ enhanced を適用して全要素の filter を確認する
    func testApplyFilterToAllChangesEveryPage() {
        let draft = DocumentDraft(pages: [makePage(), makePage(), makePage()])
        draft.applyFilterToAll(.enhanced)
        XCTAssertTrue(draft.pages.allSatisfy { $0.filter == .enhanced })
    }

    /// 存在しない id への操作が no-op になることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 未知の UUID に setFilter / rotate / remove を実行し配列が不変を確認する
    func testUnknownIdOperationsAreNoOps() {
        let page = makePage()
        let draft = DocumentDraft(pages: [page])
        let unknown = UUID()
        draft.setFilter(.blackAndWhite, for: unknown)
        draft.rotate(by: 1, for: unknown)
        draft.remove(id: unknown)
        XCTAssertEqual(draft.pages.count, 1)
        XCTAssertEqual(draft.page(id: page.id)?.filter, .original)
        XCTAssertEqual(draft.page(id: page.id)?.quarterTurns, 0)
    }

    func testSavedDraftComparisonRequiresDiscardForNewAndChangedDrafts() {
        XCTAssertTrue(SavedDraftComparison.needsDiscard(
            currentPageSignature: "page-a", savedPageSignature: "",
            currentFileName: "Scan", savedFileName: "Scan",
            currentPageSize: "A4", savedPageSize: "A4"))
        XCTAssertFalse(SavedDraftComparison.needsDiscard(
            currentPageSignature: "page-a", savedPageSignature: "page-a",
            currentFileName: "Scan", savedFileName: "Scan",
            currentPageSize: "A4", savedPageSize: "A4"))
        XCTAssertTrue(SavedDraftComparison.needsDiscard(
            currentPageSignature: "page-a:rotated", savedPageSignature: "page-a",
            currentFileName: "Scan", savedFileName: "Scan",
            currentPageSize: "A4", savedPageSize: "A4"))
    }
}
