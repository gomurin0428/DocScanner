import XCTest
import UIKit
@testable import DocScanner

/// 描画済みの輪郭を押下から撮影・取り込みまで保持する回帰テスト。
@MainActor
final class CameraShutterButtonTests: XCTestCase {
    private let first = DocumentBoundary(corners: [
        CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.3, y: 0.8),
        CGPoint(x: 0.3, y: 0.4), CGPoint(x: 0.1, y: 0.4)
    ])

    /// 指を離す前に未検出になっても、押下開始時の枠でページを作れる。
    func testVisibleBoundarySurvivesLossDuringPressAndImports() throws {
        executionTimeAllowance = 60
        let selection = CameraPreviewSelection()
        selection.display(first)
        var captures: [DocumentBoundary?] = []
        let button = CameraShutterButton.Control(selection: selection) { captures.append($0) }
        button.sendActions(for: .touchDown)
        selection.display(nil)
        button.sendActions(for: .primaryActionTriggered)

        XCTAssertEqual(captures.count, 1)
        let boundary = try XCTUnwrap(captures.first ?? nil)
        XCTAssertEqual(boundary, first)
        let image = TestImageFactory.solid(.white, size: CGSize(width: 600, height: 500))
        let result = try PageImporter().makePages(from: [PageSource.camera(image, boundary: boundary)])
        XCTAssertTrue(result.undetectedImages.isEmpty)
        let page = try XCTUnwrap(result.detectedPages.first)
        XCTAssertEqual(page.baseImage.size.width, 120, accuracy: 1)
        XCTAssertEqual(page.baseImage.size.height, 200, accuracy: 1)
    }

    /// 押下中に別の枠が描画されても切り替えず、次の撮影では新しい枠を使う。
    func testReplacementDuringPressAppliesOnlyToNextCapture() {
        let selection = CameraPreviewSelection()
        let second = first.map { CGPoint(x: $0.x + 0.4, y: $0.y) }
        selection.display(first)
        var captures: [DocumentBoundary?] = []
        let button = CameraShutterButton.Control(selection: selection) { captures.append($0) }
        button.sendActions(for: .touchDown)
        selection.display(second)
        button.sendActions(for: .primaryActionTriggered)
        button.sendActions(for: .touchDown)
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(captures, [first, second])
    }

    /// 枠なしで触れた場合は、その後の新候補を勝手に補正対象へ使わない。
    func testPressWithoutOutlineKeepsExplicitMissingBoundary() {
        let selection = CameraPreviewSelection()
        var captures: [DocumentBoundary?] = []
        let button = CameraShutterButton.Control(selection: selection) { captures.append($0) }
        button.sendActions(for: .touchDown)
        selection.display(first)
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(captures.count, 1)
        XCTAssertNil(captures[0])
    }

    /// キャンセル・領域外での指離しは撮影せず、固定した枠も破棄する。
    func testCancelledPressDoesNotCaptureOrRetainOldBoundary() {
        for event: UIControl.Event in [.touchCancel, .touchUpOutside] {
            let selection = CameraPreviewSelection()
            selection.display(first)
            var captures: [DocumentBoundary?] = []
            let button = CameraShutterButton.Control(selection: selection) { captures.append($0) }
            button.sendActions(for: .touchDown)
            selection.display(nil)
            button.sendActions(for: event)
            XCTAssertTrue(captures.isEmpty)
            button.sendActions(for: .primaryActionTriggered)
            XCTAssertEqual(captures.count, 1)
            XCTAssertNil(captures[0])
        }
    }

    /// タッチ以外の標準ボタン実行は表示枠を使い、無効状態では撮影しない。
    func testPrimaryActionUsesDisplayedBoundaryAndRespectsDisabledState() {
        let selection = CameraPreviewSelection()
        selection.display(first)
        var captures: [DocumentBoundary?] = []
        let button = CameraShutterButton.Control(selection: selection) { captures.append($0) }
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(captures, [first])
        button.isEnabled = false
        button.sendActions(for: .touchDown)
        button.sendActions(for: .primaryActionTriggered)
        XCTAssertEqual(captures, [first])
    }
}
