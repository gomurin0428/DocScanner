import AVFoundation
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
        }
    }
}

/// AVCaptureSession を使った手動シャッターカメラの制御。
/// VisionKit（VNDocumentCameraViewController）には撮影タイミングをユーザーへ
/// 委ねる API が無いため自前実装する。自動キャプチャは一切行わず、
/// プレビュー上の書類四角形検出（VNDetectRectanglesRequest）はオーバレイ表示のみに使う。
/// @Observable で UI 向け状態（検出四角形・撮影済み画像・エラー）を公開する。
@Observable
final class CameraController: NSObject {

    /// 直近フレームで検出された書類四角形（Vision 正規化座標 y-up、TL,TR,BR,BL の順）。
    /// 未検出時は nil。メインスレッドでのみ更新する。
    private(set) var detectedQuad: [CGPoint]?
    /// プレビューバッファを縦向きで見たときのピクセルサイズ（オーバレイ座標変換用）。
    private(set) var frameSize: CGSize = .zero
    /// 撮影済み画像（撮影順、imageOrientation は保持される）。
    private(set) var captures: [UIImage] = []
    /// 直前の撮影済みサムネイル。
    private(set) var lastCapture: UIImage?
    /// セッション構成・撮影で発生したエラー（UI でアラート表示する）。
    private(set) var error: CameraError?
    /// セッション構成が完了したかどうか。
    private(set) var isConfigured = false

    /// プレビュー用に公開するキャプチャセッション。
    let captureSession = AVCaptureSession()

    /// セッション構成・開始/停止・撮影を行う直列キュー（メインスレッドをブロックしない）。
    private let sessionQueue = DispatchQueue(label: "com.komurasoft.DocScanner.camera.session")
    /// ビデオフレーム解析用の直列キュー。
    private let videoQueue = DispatchQueue(label: "com.komurasoft.DocScanner.camera.video")
    /// 写真出力。
    private let photoOutput = AVCapturePhotoOutput()
    /// プレビュー解析用ビデオ出力。
    private let videoOutput = AVCaptureVideoDataOutput()
    /// ビデオバッファを Vision へ渡す際の向き（接続の回転可否に応じて設定する）。
    private var visionOrientation: CGImagePropertyOrientation = .right
    /// 検出間引き用フレームカウンタ（3 フレームに 1 回実行）。
    private var frameCounter = 0

    /// 四角形検出を行うフレーム間隔。
    private static let detectEveryNthFrame = 3

    /// コントローラを初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み CameraController
    /// - 処理: プロパティの既定値のみ設定する（セッション構成は configure() で行う）
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

    /// キャプチャセッションを構成する（バックグラウンドで呼ぶこと）。
    /// - 入力: なし
    /// - 出力: なし（isConfigured を更新する）
    /// - 処理: 背面広角カメラ入力 + AVCapturePhotoOutput + AVCaptureVideoDataOutput を
    ///   .photo プリセットのセッションへ追加し、写真出力の最大サイズと品質優先を設定する
    /// - Throws: デバイス不在・入出力追加失敗時に CameraError
    func configure() throws {
        guard !isConfigured else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera,
                                                   for: .video, position: .back) else {
            throw CameraError.noCameraDevice
        }
        let input = try AVCaptureDeviceInput(device: device)

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo
        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        captureSession.addInput(input)
        guard captureSession.canAddOutput(photoOutput) else {
            captureSession.commitConfiguration()
            throw CameraError.cannotAddPhotoOutput
        }
        captureSession.addOutput(photoOutput)
        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            throw CameraError.cannotAddVideoOutput
        }
        captureSession.addOutput(videoOutput)
        captureSession.commitConfiguration()

        // アクティブフォーマットが対応する最大寸法で撮影し、品質を優先する
        if let maxDims = device.activeFormat.supportedMaxPhotoDimensions
            .max(by: { $0.width * $0.height < $1.width * $1.height }) {
            photoOutput.maxPhotoDimensions = maxDims
        }
        photoOutput.maxPhotoQualityPrioritization = .quality

        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true

        // 縦向きの向き付け。接続がバッファ回転に対応していれば 90° にして
        // 縦向きバッファを受け取り Vision には .up を渡す。非対応なら
        // センサー横向きバッファのままなので .right で縦向き解釈する。
        if let connection = videoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
            visionOrientation = .up
        } else {
            visionOrientation = .right
        }
        isConfigured = true
    }

    /// セッションの入力・処理を開始する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: セッションキュー上で startRunning を呼ぶ（メインスレッド外）
    func start() {
        sessionQueue.async { [captureSession] in
            if !captureSession.isRunning { captureSession.startRunning() }
        }
    }

    /// セッションを停止する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: セッションキュー上で stopRunning を呼ぶ（メインスレッド外）
    func stop() {
        sessionQueue.async { [captureSession] in
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    /// シャッター: 写真を 1 枚撮影する。
    /// - 入力: なし
    /// - 出力: なし（完了時に captures / lastCapture / error が更新される）
    /// - 処理: 縦向き回転を写真接続へ設定してから撮影を依頼する
    func capture() {
        sessionQueue.async { [photoOutput] in
            if let connection = photoOutput.connection(with: .video),
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            let settings = AVCapturePhotoSettings()
            photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }
}

/// 写真撮影結果とプレビューフレーム解析のデリゲート実装。
extension CameraController: AVCapturePhotoCaptureDelegate,
                            AVCaptureVideoDataOutputSampleBufferDelegate {

    /// 撮影完了を受け取り画像を captures へ追加する。
    /// - 入力: output … 写真出力、photo … 撮影済み写真、error … 失敗時のエラー
    /// - 出力: なし（captures / lastCapture / error をメインスレッドで更新する）
    /// - 処理: fileDataRepresentation から UIImage を生成して保持する
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: (any Error)?) {
        if let error {
            Task { @MainActor in
                self.error = .captureFailed(error.localizedDescription)
            }
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            Task { @MainActor in
                self.error = .invalidPhotoData
            }
            return
        }
        Task { @MainActor in
            self.captures.append(image)
            self.lastCapture = image
        }
    }

    /// プレビューフレームを受け取り書類四角形を検出する。
    /// - 入力: output … ビデオ出力、sampleBuffer … フレームバッファ、connection … 接続
    /// - 出力: なし（detectedQuad / frameSize をメインスレッドで更新する）
    /// - 処理: 3 フレームに 1 回、DocumentDetector と同パラメータの
    ///   VNDetectRectanglesRequest を実行し正規化四角形を公開する。自動撮影は行わない
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        frameCounter += 1
        guard frameCounter % Self.detectEveryNthFrame == 0,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.3
        request.maximumObservations = 1
        request.quadratureTolerance = 30
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer,
                                            orientation: visionOrientation)
        // perform は Void なので結果は request.results から取る
        let quad: [CGPoint]?
        if (try? handler.perform([request])) != nil,
           let observation = request.results?.first as? VNRectangleObservation {
            quad = [observation.topLeft, observation.topRight,
                    observation.bottomRight, observation.bottomLeft]
        } else {
            quad = nil
        }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer),
                          height: CVPixelBufferGetHeight(buffer))
        let orientedSize = visionOrientation == .up
            ? size
            : CGSize(width: size.height, height: size.width)
        Task { @MainActor in
            self.detectedQuad = quad
            self.frameSize = orientedSize
        }
    }
}
