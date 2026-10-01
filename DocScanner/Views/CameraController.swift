import AVFoundation
import CoreImage
import Observation
import UIKit
import Vision

/// カメラ撮影処理中に発生するエラー。
enum CameraError: LocalizedError, Equatable {
    /// 利用可能な背面カメラが存在しない。
    case noCameraDevice
    /// カメラ入力をセッションへ追加できなかった。
    case cannotAddInput
    /// 写真出力をセッションへ追加できなかった。
    case cannotAddPhotoOutput
    /// プレビュー解析用ビデオ出力をセッションへ追加できなかった。
    case cannotAddVideoOutput
    /// 撮影に失敗した（元エラーメッセージ付き）。
    case captureFailed(String)
    /// 撮影データから画像を生成できなかった。
    case invalidPhotoData
    /// カメラ入力を生成できなかった。
    case cannotCreateInput(String)
    case detectionFailed(String)

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .noCameraDevice:
            return "No camera device is available on this device."
        case .cannotAddInput:
            return "The camera input could not be added to the capture session."
        case .cannotAddPhotoOutput:
            return "The photo output could not be added to the capture session."
        case .cannotAddVideoOutput:
            return "The video output could not be added to the capture session."
        case .captureFailed(let message):
            return "The photo could not be captured: \(message)"
        case .invalidPhotoData:
            return "The captured photo data could not be decoded as an image."
        case .cannotCreateInput(let message):
            return "The camera input could not be created: \(message)"
        case .detectionFailed(let message):
            return "The document boundary could not be processed: \(message)"
        }
    }
}

/// AVCaptureSession を使った手動シャッターカメラの制御。
/// VisionKit（VNDocumentCameraViewController）には撮影タイミングをユーザーへ
/// 委ねる API が無いため自前実装する。自動キャプチャは一切行わず、
/// プレビューの輪郭は表示と撮影後の補正で共有する。
/// @Observable で UI 向け状態（検出四角形・撮影済み画像・エラー）を公開する。
@Observable
final class CameraController: NSObject {

    /// 連続検出で確認した書類四角形（Vision 正規化座標 y-up、TL,TR,BR,BL の順）。
    /// 未検出時は nil。メインスレッドでのみ更新する。
    private(set) var detectedQuad: [CGPoint]?
    private(set) var detectedBoundary: DocumentBoundary?
    private(set) var metadataBoundary: DocumentBoundary?
    /// プレビューバッファを縦向きで見たときのピクセルサイズ（オーバレイ座標変換用）。
    private(set) var frameSize: CGSize = .zero
    /// 撮影済み画像（撮影順、imageOrientation は保持される）。
    var captures: [UIImage] { photoState.captures }
    var capturedSources: [PageSource] { photoState.sources }
    /// 直前の撮影済みサムネイル。
    var lastCapture: UIImage? { photoState.captures.last }
    /// 撮影トランザクションが進行中かどうか。
    var isCapturing: Bool { photoState.isCapturing }
    /// 撮影済み画像があり、かつ撮影中でない場合に Done を有効化する。
    var canFinish: Bool { photoState.canFinish }
    /// セッション構成・撮影で発生したエラー（UI でアラート表示する）。
    private(set) var error: CameraError?
    /// セッション構成が完了したかどうか。
    private(set) var isConfigured = false
    /// メインスレッドで管理する撮影状態。
    private var photoState = CameraPhotoState()

    /// プレビュー用に公開するキャプチャセッション。
    let captureSession = AVCaptureSession()

    /// セッション構成・開始/停止・撮影を行う直列キュー（メインスレッドをブロックしない）。
    private let sessionQueue = DispatchQueue(label: "com.komurasoft.DocScanner.camera.session")
    /// 開始・停止世代を同期的に無効化するスレッドセーフな状態。
    private let lifecycle = CameraLifecycleState()
    /// ビデオフレーム解析用の直列キュー。
    private let videoQueue = DispatchQueue(label: "com.komurasoft.DocScanner.camera.video")
    /// 写真出力。
    private let photoOutput = AVCapturePhotoOutput()
    /// プレビュー解析用ビデオ出力。
    private let videoOutput = AVCaptureVideoDataOutput()
    /// セッションキューでのみ読み書きする構成済みフラグ。
    @ObservationIgnored
    private var isConfiguredOnQueue = false
    /// 撮影完了コールバックまで保持するデリゲート。
    @ObservationIgnored
    private var activePhotoDelegate: CameraPhotoCaptureDelegate?
    /// 解析キューとセッションキュー間で向き設定を共有するロック。
    private let orientationLock = NSLock()
    /// ビデオバッファを Vision へ渡す際の向き（接続の回転可否に応じて設定する）。
    @ObservationIgnored
    private var visionOrientation: CGImagePropertyOrientation = .right
    /// ビデオキュー内の検出時刻と追跡状態。
    @ObservationIgnored
    private var lastDetectionTime: TimeInterval?
    @ObservationIgnored
    private var trackingGeneration: UInt64?
    @ObservationIgnored
    private var trackingSize: CGSize = .zero
    @ObservationIgnored
    private var rectangleTracker = DocumentRectangleTracker()
    @ObservationIgnored
    private var trackedBoundary: DocumentBoundary?
    private let analysisContext = CIContext()

    /// コントローラを初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み CameraController
    /// - 処理: プロパティの既定値のみ設定する（権限許可後に start(generation:) が構成する）
    override init() {
        super.init()
    }

    /// カメラデバイスが利用可能かを返す。
    /// - 入力: なし
    /// - 出力: 背面広角カメラが存在すれば true（シミュレータは false）
    /// - 処理: AVCaptureDevice.default(.builtInWideAngleCamera) の有無を返す
    static func isAvailable() -> Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video,
                                position: .back) != nil
    }

    /// セッション開始用の世代を同期的に有効化する。
    /// - 入力: なし
    /// - 出力: 権限待ち・構成中の処理を照合する世代番号
    /// - 処理: UI 状態をリセットし、キャンセル判定用のトークンを発行する
    func beginActivation() -> UInt64 {
        let generation = lifecycle.activate()
        isConfigured = false
        detectedQuad = nil
        detectedBoundary = nil
        metadataBoundary = nil
        error = nil
        return generation
    }

    /// 指定世代が現在も有効かを返す。
    func isCurrent(_ generation: UInt64, taskIsCancelled: Bool = false) -> Bool {
        lifecycle.canStart(generation, taskIsCancelled: taskIsCancelled)
    }

    /// 現在表示中のエラーを消去する。
    func clearError() {
        error = nil
    }

    /// セッションを構成して開始する。
    /// - 入力: generation … beginActivation で発行した世代番号
    /// - 出力: なし（準備完了またはエラーをメインスレッドへ通知する）
    /// - 処理: セッションキュー上で構成と開始を連続して行い、構成後も世代を再検証する
    func start(generation: UInt64) {
        guard lifecycle.canStart(generation, taskIsCancelled: false) else { return }
        sessionQueue.async { [weak self] in
            guard let self,
                  self.lifecycle.canStart(generation, taskIsCancelled: false) else { return }
            do {
                try self.configureOnSessionQueue()
                guard self.lifecycle.canStart(generation, taskIsCancelled: false) else { return }
                if !self.captureSession.isRunning {
                    self.captureSession.startRunning()
                }
                guard self.lifecycle.canStart(generation, taskIsCancelled: false) else {
                    if self.captureSession.isRunning { self.captureSession.stopRunning() }
                    return
                }
                let running = self.captureSession.isRunning
                self.publishReady(running, error: running ? nil : .captureFailed(
                    "The capture session could not be started."), generation: generation)
            } catch let cameraError as CameraError {
                self.publishReady(false, error: cameraError, generation: generation)
            } catch {
                self.publishReady(false, error: .captureFailed(error.localizedDescription),
                                  generation: generation)
            }
        }
    }

    /// セッションを停止し、進行中の開始・UI 更新を同期的に無効化する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 世代を先に無効化してから同じキューに停止処理を積む
    func stop() {
        lifecycle.deactivate()
        isConfigured = false
        detectedQuad = nil
        detectedBoundary = nil
        metadataBoundary = nil
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    /// シャッター: 写真を 1 枚だけ撮影する。
    /// - 入力: boundary … シャッターボタンが固定した表示済み metadata 輪郭
    /// - 出力: なし（完了まで isCapturing を維持する）
    /// - 処理: MainActor で pending を同期設定してからセッションキューへ撮影を依頼する
    func capture(boundary: DocumentBoundary?) {
        guard isConfigured,
              !photoState.isCapturing,
              let generation = lifecycle.currentGeneration,
              photoState.beginCapture() else { return }
        error = nil
        let delegate = CameraPhotoCaptureDelegate(boundary: boundary) { [weak self] delegate, image, boundary, captureError in
            Task { @MainActor in
                self?.completeCapture(delegate: delegate, image: image,
                                      boundary: boundary, error: captureError, generation: generation)
            }
        }
        activePhotoDelegate = delegate
        sessionQueue.async { [weak self, delegate] in
            guard let self,
                  self.lifecycle.canStart(generation, taskIsCancelled: false),
                  self.captureSession.isRunning else {
                Task { @MainActor in
                    self?.completeCapture(
                        delegate: delegate,
                        image: nil,
                        boundary: nil,
                        error: .captureFailed("The capture session is not running."),
                        generation: generation
                    )
                }
                return
            }
            if let connection = self.photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            self.photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
        }
    }

    /// AVCaptureSession をセッションキュー上で構成する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 背面カメラ入力・写真出力・解析出力を追加し、写真品質と解析接続を設定する
    /// - Throws: デバイス・入出力の構成失敗時に CameraError
    private func configureOnSessionQueue() throws {
        guard !isConfiguredOnQueue else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back) else {
            throw CameraError.noCameraDevice
        }
        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw CameraError.cannotCreateInput(error.localizedDescription)
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        captureSession.sessionPreset = .photo
        guard captureSession.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        guard captureSession.canAddOutput(photoOutput) else {
            throw CameraError.cannotAddPhotoOutput
        }
        guard captureSession.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddVideoOutput
        }
        captureSession.addInput(input)
        captureSession.addOutput(photoOutput)
        captureSession.addOutput(videoOutput)

        if let maxDims = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = maxDims
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            setVisionOrientation(.up)
        } else {
            setVisionOrientation(.right)
        }
        videoOutput.connection(with: .video)?.preferredVideoStabilizationMode = .off
        isConfiguredOnQueue = true
    }

    /// セッション向きを同期的に保存する。
    private func setVisionOrientation(_ orientation: CGImagePropertyOrientation) {
        orientationLock.lock()
        visionOrientation = orientation
        orientationLock.unlock()
    }

    /// Vision 用の現在向きを同期的に読み取る。
    private func currentVisionOrientation() -> CGImagePropertyOrientation {
        orientationLock.lock()
        defer { orientationLock.unlock() }
        return visionOrientation
    }

    /// セッションキューの結果を世代確認後に UI 状態へ反映する。
    private func publishReady(_ ready: Bool, error: CameraError?, generation: UInt64) {
        Task { @MainActor [weak self] in
            guard let self, self.lifecycle.isActive(generation) else { return }
            self.isConfigured = ready
            self.error = error
        }
    }

    /// 写真撮影トランザクションの最終結果を一度に UI 状態へ反映する。
    @MainActor
    private func completeCapture(delegate: CameraPhotoCaptureDelegate,
                                 image: UIImage?,
                                 boundary: DocumentBoundary?,
                                 error captureError: CameraError?,
                                 generation: UInt64) {
        let shouldPublish = lifecycle.isActive(generation)
        photoState.finishCapture(image: image,
                                 shouldAppend: shouldPublish && captureError == nil,
                                 boundary: boundary)
        if activePhotoDelegate === delegate {
            activePhotoDelegate = nil
        }
        guard shouldPublish else { return }
        error = captureError ?? (image == nil ? .invalidPhotoData : nil)
    }
}

/// 写真撮影結果とプレビューフレーム解析のデリゲート実装。
extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {

    /// プレビューフレームを受け取り書類四角形を検出する。
    /// - 入力: output … ビデオ出力、sampleBuffer … フレームバッファ、connection … 接続
    /// - 出力: なし（detectedQuad / frameSize をメインスレッドで更新する）
    /// - 処理: 最大毎秒 5 回、書類領域を検証し、時間的に安定した枠だけ公開する
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let generation = lifecycle.currentGeneration,
              lifecycle.isActive(generation) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        guard time.isFinite,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if trackingGeneration != generation {
            trackingGeneration = generation
            rectangleTracker = DocumentRectangleTracker()
            trackedBoundary = nil
            lastDetectionTime = nil
        }
        if let lastDetectionTime, time >= lastDetectionTime, time - lastDetectionTime < 0.2 { return }
        lastDetectionTime = time
        let orientation = currentVisionOrientation()
        let size = CGSize(width: CVPixelBufferGetWidth(buffer),
                          height: CVPixelBufferGetHeight(buffer))
        let orientedSize = orientation == .up
            ? size
            : CGSize(width: size.height, height: size.width)
        if trackingSize != orientedSize {
            trackingSize = orientedSize
            rectangleTracker = DocumentRectangleTracker()
            trackedBoundary = nil
        }
        let request = DocumentRectangleDetector.makeRequest()
        let documentRequest = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: orientation)
        let candidate: VNRectangleObservation?
        if (try? handler.perform([request, documentRequest])) != nil {
            candidate = DocumentRectangleDetector.liveDocument(
                in: request.results ?? [], document: documentRequest.results?.first,
                size: orientedSize)
        } else {
            candidate = nil
        }
        let quad = rectangleTracker.update(candidate, at: time)
        var detectionError: CameraError?
        if quad == nil {
            trackedBoundary = nil
        } else if rectangleTracker.didMatchObservation, let candidate, let quad {
            do {
                let corners = [candidate.topLeft, candidate.topRight, candidate.bottomRight, candidate.bottomLeft]
                let boundary: DocumentBoundary
                if let maskBuffer = documentRequest.results?.first?.globalSegmentationMask?.pixelBuffer {
                    let ci = CIImage(cvPixelBuffer: buffer).oriented(orientation)
                    guard let cg = analysisContext.createCGImage(ci, from: ci.extent) else {
                        throw DocumentDetectionError.invalidImage
                    }
                    let mask = try SegmentationMask(pixelBuffer: maskBuffer,
                                                    imageWidth: cg.width, imageHeight: cg.height)
                    boundary = try PageFlattener().traceBoundary(cg, corners: corners.map {
                        CGPoint(x: $0.x * orientedSize.width, y: (1 - $0.y) * orientedSize.height)
                    }, mask: mask)
                } else {
                    boundary = DocumentBoundary(corners: corners)
                }
                let transform = try PageGeometry.homography(
                    from: corners.map { PagePoint(x: $0.x, y: $0.y) },
                    to: quad.map { PagePoint(x: $0.x, y: $0.y) })
                let smoothed = boundary.map {
                    let point = PageGeometry.apply(transform, to: PagePoint(x: $0.x, y: $0.y))
                    return CGPoint(x: point.x, y: point.y)
                }
                trackedBoundary = smoothed.isValid ? smoothed : nil
            } catch {
                trackedBoundary = nil
                detectionError = .detectionFailed(error.localizedDescription)
            }
        }
        let boundary = trackedBoundary
        func toMetadata(_ point: CGPoint) -> CGPoint {
            let pixel = orientation == .up
                ? CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)
                : CGPoint(x: (1 - point.y) * size.width, y: (1 - point.x) * size.height)
            return output.metadataOutputRectConverted(fromOutputRect: CGRect(origin: pixel, size: .zero)).origin
        }
        let transform = CameraCaptureGeometry.transform(
            origin: toMetadata(.zero), x: toMetadata(CGPoint(x: 1, y: 0)),
            y: toMetadata(CGPoint(x: 0, y: 1)))
        let metadata = boundary?.map { $0.applying(transform) }
        Task { @MainActor in
            guard self.lifecycle.isActive(generation), !self.isCapturing else { return }
            self.detectedQuad = quad
            self.detectedBoundary = boundary
            self.metadataBoundary = metadata
            self.frameSize = orientedSize
            if let detectionError, self.error == nil { self.error = detectionError }
        }
    }
}
