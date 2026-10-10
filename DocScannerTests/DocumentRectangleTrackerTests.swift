import XCTest
import Vision
@testable import DocScanner

/// 時系列の検出結果を使い、実カメラに依存せず枠の点滅・飛び移りを検証する。
final class DocumentRectangleTrackerTests: XCTestCase {
    private let paper = VNRectangleObservation(boundingBox: CGRect(x: 0.2, y: 0.2, width: 0.35, height: 0.6))
    private let other = VNRectangleObservation(boundingBox: CGRect(x: 0.6, y: 0.1, width: 0.3, height: 0.5))

    /// 湾曲紙の角が 4% を超えて揺れても、同じ紙の連続観測として取得する。
    func testCurvedCornerJitterAcquiresWithoutSwitchingToOtherPaper() throws {
        let shifted = VNRectangleObservation(requestRevision: 1,
            topLeft: CGPoint(x: paper.topLeft.x + 0.055, y: paper.topLeft.y),
            bottomLeft: paper.bottomLeft, bottomRight: paper.bottomRight, topRight: paper.topRight)
        var tracker = DocumentRectangleTracker()
        XCTAssertNil(tracker.update(paper, at: 0))
        XCTAssertNil(tracker.update(shifted, at: 0.2))
        let quad = try XCTUnwrap(tracker.update(paper, at: 0.4))
        XCTAssertTrue(tracker.didMatchObservation)
        XCTAssertEqual(tracker.update(other, at: 0.6), quad)
        XCTAssertFalse(tracker.didMatchObservation)
    }

    /// 中程度の信頼度でも安定した書類領域は採用し、低信頼度は拒否する。
    func testModerateConfidenceCurvedDocumentStillRequiresStability() throws {
        let document = ModerateConfidenceDocument(boundingBox: paper.boundingBox)
        let candidate = try XCTUnwrap(DocumentRectangleDetector.liveDocument(
            in: [], document: document, size: CGSize(width: 1000, height: 1400)))
        var tracker = DocumentRectangleTracker()
        XCTAssertNil(tracker.update(candidate, at: 0))
        XCTAssertNil(tracker.update(candidate, at: 0.2))
        XCTAssertNotNil(tracker.update(candidate, at: 0.4))
        XCTAssertNil(DocumentRectangleDetector.liveDocument(in: [],
            document: LowConfidenceDocument(boundingBox: paper.boundingBox),
            size: CGSize(width: 1000, height: 1400)))
    }

    /// 直線検出が出入りしても、曲線側と直線側の角を交互に選び直さない。
    func testRectangleAppearanceDoesNotChangeSegmentationCorners() {
        let shifted = VNRectangleObservation(boundingBox: paper.boundingBox.offsetBy(dx: 0.035, dy: 0))
        for rectangles in [[VNRectangleObservation](), [shifted], []] {
            XCTAssertEqual(DocumentRectangleDetector.liveDocument(in: rectangles,
                document: paper, size: CGSize(width: 1000, height: 1400))?.uuid, paper.uuid)
        }
    }

    /// 単発候補や交互に変わる矩形は表示せず、同じ紙が連続した場合だけ表示する。
    func testRectangleAcquiresWhenSegmentationIsMissingOrInvalid() throws {
        let size = CGSize(width: 1000, height: 1400)
        for document in [nil, LowConfidenceDocument(boundingBox: paper.boundingBox),
                         VNRectangleObservation(boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1))] {
            let candidate = try XCTUnwrap(DocumentRectangleDetector.liveDocument(
                in: [other, paper], document: document, size: size))
            XCTAssertEqual(candidate.uuid, paper.uuid)
            var tracker = DocumentRectangleTracker()
            XCTAssertNil(tracker.update(candidate, at: 0))
            XCTAssertNil(tracker.update(candidate, at: 0.2))
            XCTAssertNotNil(tracker.update(candidate, at: 0.4))
        }
    }

    func testCompletePaperWithinOnePercentOfFrameEdgesIsAccepted() throws {
        let size = CGSize(width: 1000, height: 1400)
        let nearEdge = VNRectangleObservation(boundingBox: CGRect(x: 0.003, y: 0.004, width: 0.994, height: 0.992))
        XCTAssertEqual(DocumentRectangleDetector.liveDocument(in: [], document: nearEdge, size: size)?.uuid, nearEdge.uuid)
        XCTAssertEqual(DocumentRectangleDetector.liveDocument(in: [nearEdge], document: nil, size: size)?.uuid, nearEdge.uuid)
        let touching = VNRectangleObservation(boundingBox: CGRect(x: 0, y: 0, width: 0.8, height: 0.9))
        XCTAssertEqual(DocumentRectangleDetector.liveDocument(in: [], document: touching, size: size)?.uuid, touching.uuid)
        let outside = VNRectangleObservation(boundingBox: CGRect(x: -0.01, y: 0.1, width: 0.9, height: 0.8))
        XCTAssertNil(DocumentRectangleDetector.liveDocument(in: [outside], document: nil, size: size))
        XCTAssertNil(DocumentRectangleDetector.liveDocument(in: [LowConfidenceDocument(boundingBox: paper.boundingBox)],
                                                           document: nil, size: size))
    }

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

private final class ModerateConfidenceDocument: VNRectangleObservation {
    override var confidence: VNConfidence { 0.65 }
}

private final class LowConfidenceDocument: VNRectangleObservation {
    override var confidence: VNConfidence { 0.4 }
}
