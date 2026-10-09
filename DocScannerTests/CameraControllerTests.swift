import AVFoundation
import XCTest
@testable import DocScanner

/// カメラ開始世代と写真状態の回帰テスト。
final class CameraControllerTests: XCTestCase {

    /// 構成が遅れて完了した場合、stop 後にセッションを開始しないことを検証する。
    func testStopDuringDelayedConfigurationPreventsSessionStart() {
        let lifecycle = CameraLifecycleState()
        let generation = lifecycle.activate()
        let configured = DispatchSemaphore(value: 0)
        let continueConfiguration = DispatchSemaphore(value: 0)
        let didStart = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "CameraControllerTests.configure")

        queue.async {
            configured.signal()
            continueConfiguration.wait()
            if lifecycle.canStart(generation, taskIsCancelled: false) {
                didStart.signal()
            }
        }
        configured.wait()
        lifecycle.deactivate()
        continueConfiguration.signal()
        queue.sync {}

        XCTAssertEqual(didStart.wait(timeout: .now()), .timedOut)
    }

    /// 画面終了後に完了した権限要求がセッション開始を許可しないことを検証する。
    func testDismissedPendingAuthorizationCannotStart() {
        let lifecycle = CameraLifecycleState()
        let generation = lifecycle.activate()
        lifecycle.deactivate()

        XCTAssertFalse(lifecycle.canStart(generation, taskIsCancelled: true))
        XCTAssertFalse(lifecycle.canStart(generation, taskIsCancelled: false))
    }

    /// 前の画像があっても次の撮影中は Done を無効化し、失敗完了で pending を解放する。
    func testCaptureFailureClearsPendingAndRestoresDoneForPriorImage() {
        let priorImage = TestImageFactory.solid(.white, size: CGSize(width: 10, height: 10))
        var state = CameraPhotoState(captures: [priorImage])

        XCTAssertTrue(state.canFinish)
        XCTAssertTrue(state.beginCapture())
        XCTAssertFalse(state.beginCapture())
        XCTAssertFalse(state.canFinish)

        state.finishCapture(image: nil, shouldAppend: true)

        XCTAssertFalse(state.isCapturing)
        XCTAssertTrue(state.canFinish)
        XCTAssertEqual(state.captures.count, 1)
        XCTAssertTrue(state.captures[0] === priorImage)
    }

    func testPhotoDimensionsChooseLargestResolutionWithinTwelveMegapixels() {
        let selected = CameraController.choosePhotoDimensions([
            CMVideoDimensions(width: 1920, height: 1080),
            CMVideoDimensions(width: 4000, height: 3000),
            CMVideoDimensions(width: 8000, height: 6000)
        ])
        XCTAssertEqual(selected?.width, 4000)
        XCTAssertEqual(selected?.height, 3000)
    }

    func testPhotoDimensionsFallBackToSmallestSupportedResolution() {
        let selected = CameraController.choosePhotoDimensions([
            CMVideoDimensions(width: 8000, height: 6000),
            CMVideoDimensions(width: 6000, height: 4000)
        ])
        XCTAssertEqual(selected?.width, 6000)
        XCTAssertEqual(selected?.height, 4000)
    }
}
