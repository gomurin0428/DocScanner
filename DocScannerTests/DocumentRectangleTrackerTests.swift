import XCTest
import Vision
@testable import DocScanner

/// 時系列の検出結果を使い、実カメラに依存せず枠の点滅・飛び移りを検証する。
final class DocumentRectangleTrackerTests: XCTestCase {
    private let paper = VNRectangleObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.35, height: 0.6))
    private let other = VNRectangleObservation(boundingBox: CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.5))

    /// 単発候補や交互に変わる矩形は表示せず、同じ紙が連続した場合だけ表示する。
    func testAlternatingCandidatesNeverFlash() {
        var tracker = DocumentRectangleTracker()
        for index in 0..<20 {
            XCTAssertNil(tracker.update(index.isMultiple(of: 2) ? paper : other,
                                        at: Double(index) * 0.2))
        }
        XCTAssertNil(tracker.update(paper, at: 4.0))
        XCTAssertNil(tracker.update(paper, at: 4.2))
        XCTAssertEqual(tracker.update(paper, at: 4.4)?.first, paper.topLeft)
    }

    /// 高フレームレートでも十分な時間が経つまでは枠を表示しない。
    func testAcquisitionRequiresElapsedTimeAsWellAsFrameCount() {
        var tracker = DocumentRectangleTracker()
        XCTAssertNil(tracker.update(paper, at: 0))
        XCTAssertNil(tracker.update(paper, at: 0.01))
        XCTAssertNil(tracker.update(paper, at: 0.02))
        XCTAssertNotNil(tracker.update(paper, at: 0.4))
    }

    /// 微小な位置揺れを平滑化し、1 回の未検出や遠方の誤検出で枠を飛ばさない。
    func testJitterAndBriefDropoutKeepTheTrackedPaper() throws {
        var tracker = acquiredTracker()
        let shifted = VNRectangleObservation(boundingBox: paper.boundingBox.offsetBy(dx: 0.01, dy: -0.01))
        let smoothed = try XCTUnwrap(tracker.update(shifted, at: 0.6))
        XCTAssertEqual(smoothed[0].x, paper.topLeft.x + 0.0035, accuracy: 0.0001)
        XCTAssertEqual(smoothed[0].y, paper.topLeft.y - 0.0035, accuracy: 0.0001)
        XCTAssertEqual(tracker.update(nil, at: 0.8), smoothed)
        XCTAssertEqual(tracker.update(other, at: 1.0), smoothed)
        XCTAssertNotNil(tracker.update(paper, at: 1.2))
    }

    /// 見失った枠は猶予時間後に消え、再表示には再確認を要求する。
    func testSustainedLossClearsOverlayAndRequiresReacquisition() {
        var tracker = acquiredTracker()
        XCTAssertNotNil(tracker.update(nil, at: 0.6))
        XCTAssertNotNil(tracker.update(nil, at: 0.8))
        XCTAssertNil(tracker.update(nil, at: 1.2))
        XCTAssertNil(tracker.update(paper, at: 1.4))
        XCTAssertNil(tracker.update(paper, at: 1.6))
        XCTAssertNotNil(tracker.update(paper, at: 1.8))
    }

    /// 別の紙へ移動した場合、旧候補の消失と新候補の連続確認後だけ切り替える。
    func testNewDocumentDoesNotReplaceOverlayImmediately() {
        var tracker = acquiredTracker()
        XCTAssertEqual(tracker.update(other, at: 0.6)?.first, paper.topLeft)
        XCTAssertEqual(tracker.update(other, at: 0.8)?.first, paper.topLeft)
        XCTAssertEqual(tracker.update(other, at: 1.0)?.first, paper.topLeft)
        XCTAssertEqual(tracker.update(other, at: 1.2)?.first, other.topLeft)
    }

    /// 中断・時刻巻き戻りの後に古い枠を引き継がず、不正時刻では消す。
    func testTimestampDiscontinuitiesResetTracking() {
        var tracker = acquiredTracker()
        XCTAssertNil(tracker.update(paper, at: 2))
        XCTAssertNil(tracker.update(paper, at: 1))
        XCTAssertNil(tracker.update(paper, at: .nan))
        XCTAssertNil(tracker.update(paper, at: 3))
    }

    /// 確認中の未検出が連続回数をリセットすることを検証する。
    func testMissingFrameInterruptsAcquisition() {
        var tracker = DocumentRectangleTracker()
        XCTAssertNil(tracker.update(paper, at: 0))
        XCTAssertNil(tracker.update(paper, at: 0.2))
        XCTAssertNil(tracker.update(nil, at: 0.4))
        XCTAssertNil(tracker.update(paper, at: 0.6))
        XCTAssertNil(tracker.update(paper, at: 0.8))
        XCTAssertNotNil(tracker.update(paper, at: 1.0))
    }

    /// 書類領域の裏付けがない矩形や別候補との一致を表示対象にしない。
    func testLiveGateRequiresSegmentationToAgreeWithPreferredRectangle() {
        let size = CGSize(width: 1000, height: 1400)
        XCTAssertNil(DocumentRectangleDetector.confirmedDocument(in: [paper], document: nil, size: size))
        XCTAssertNil(DocumentRectangleDetector.confirmedDocument(in: [paper], document: other, size: size))
        let background = VNRectangleObservation(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertNil(DocumentRectangleDetector.confirmedDocument(in: [paper, background], document: paper, size: size))
        XCTAssertEqual(DocumentRectangleDetector.confirmedDocument(in: [paper], document: paper, size: size)?.uuid, paper.uuid)
    }

    /// 矩形がなくても書類領域が連続していれば表示し、単発では表示しない。
    func testSegmentationOnlyDocumentRequiresStableFrames() throws {
        let candidate = try XCTUnwrap(DocumentRectangleDetector.liveDocument(
            in: [], document: paper, size: CGSize(width: 1000, height: 1400)))
        var tracker = DocumentRectangleTracker()
        XCTAssertNil(tracker.update(candidate, at: 0))
        XCTAssertNil(tracker.update(candidate, at: 0.2))
        XCTAssertEqual(tracker.update(candidate, at: 0.4)?.first, paper.topLeft)
    }

    /// 背景矩形との不一致で書類を捨てず、切り抜きにも使う書類領域を返す。
    func testUnrelatedRectangleDoesNotVetoDocument() {
        let background = VNRectangleObservation(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))
        let size = CGSize(width: 1000, height: 1400)
        XCTAssertEqual(DocumentRectangleDetector.liveDocument(
            in: [background], document: paper, size: size)?.uuid, paper.uuid)
        XCTAssertEqual(DocumentRectangleDetector.liveDocument(
            in: [paper], document: paper, size: size)?.uuid, paper.uuid)
        XCTAssertNil(DocumentRectangleDetector.liveDocument(
            in: [background], document: nil, size: size))
    }

    /// 書類領域だけの候補が交互に変わっても枠を点滅させない。
    func testAlternatingSegmentationOnlyDocumentsNeverFlash() {
        var tracker = DocumentRectangleTracker()
        for index in 0..<20 {
            let candidate = DocumentRectangleDetector.liveDocument(
                in: [], document: index.isMultiple(of: 2) ? paper : other,
                size: CGSize(width: 1000, height: 1400))
            XCTAssertNotNil(candidate)
            XCTAssertNil(tracker.update(candidate, at: Double(index) * 0.2))
        }
    }

    /// 全画面・画面端の帯・潰れた領域・画素寸法不正は矩形なしで採用しない。
    func testSegmentationOnlyRejectsDegenerateRegions() {
        for box in [CGRect(x: 0, y: 0, width: 1, height: 1),
                    CGRect(x: 0, y: 0, width: 1, height: 0.25),
                    CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.02)] {
            XCTAssertNil(DocumentRectangleDetector.liveDocument(
                in: [], document: VNRectangleObservation(boundingBox: box),
                size: CGSize(width: 1000, height: 1400)))
        }
        XCTAssertNil(DocumentRectangleDetector.liveDocument(in: [], document: paper, size: .zero))
        XCTAssertNil(DocumentRectangleDetector.liveDocument(
            in: [], document: nil, size: CGSize(width: 1000, height: 1400)))
    }

    /// 共通の紙を 3 回確認済みの追跡状態を生成する。
    private func acquiredTracker() -> DocumentRectangleTracker {
        var tracker = DocumentRectangleTracker()
        _ = tracker.update(paper, at: 0)
        _ = tracker.update(paper, at: 0.2)
        _ = tracker.update(paper, at: 0.4)
        return tracker
    }
}
