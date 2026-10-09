import XCTest
@testable import DocScanner

/// FileNameSanitizer のファイル名変換テスト。
final class FileNameSanitizerTests: XCTestCase {

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// 使用不可文字が "-" に置き換わることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: / \ : * ? " < > | を含む文字列を sanitize する
    func testIllegalCharactersReplaced() throws {
        let result = try FileNameSanitizer.sanitize("a/b\\c:d*e?f\"g<h>i|j")
        XCTAssertEqual(result, "a-b-c-d-e-f-g-h-i-j")
    }

    /// 末尾の ".pdf"/".PDF" が除去されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 大小両パターンで拡張子除去を確認する
    func testPDFExtensionStripped() throws {
        XCTAssertEqual(try FileNameSanitizer.sanitize("report.pdf"), "report")
        XCTAssertEqual(try FileNameSanitizer.sanitize("report.PDF"), "report")
    }

    /// 空白のみの入力でエラーが送出されることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 空白文字列を sanitize して FileNameError.empty を期待する
    func testWhitespaceOnlyThrows() {
        XCTAssertThrowsError(try FileNameSanitizer.sanitize("   ")) { error in
            XCTAssertEqual(error as? FileNameError, .empty)
        }
    }

    /// 先頭ピリオド付き拡張子だけの入力を隠し名として拒否する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 拡張子除去後に空となる入力で FileNameError.empty を期待する
    func testExtensionOnlyThrows() {
        XCTAssertThrowsError(try FileNameSanitizer.sanitize(".pdf")) { error in
            XCTAssertEqual(error as? FileNameError, .hiddenName)
        }
    }

    func testLeadingDotNamesAreRejected() {
        for name in [".memo", "..", " .PDF ", " .memo "] {
            XCTAssertThrowsError(try FileNameSanitizer.sanitize(name), name) { error in
                XCTAssertEqual(error as? FileNameError, .hiddenName)
            }
        }
    }

    /// 既定名が "Scan yyyy-MM-dd HH.mm.ss" 形式になることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 固定日時で生成し正規表現と先頭文字列を検査する
    func testDefaultNameFormat() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 29
        components.hour = 15
        components.minute = 4
        components.second = 7
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let name = FileNameSanitizer.defaultName(for: date)
        XCTAssertTrue(name.hasPrefix("Scan "))
        XCTAssertEqual(name.count, "Scan yyyy-MM-dd HH.mm.ss".count)
    }
}
