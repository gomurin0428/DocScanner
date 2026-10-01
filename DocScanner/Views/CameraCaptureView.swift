import AVFoundation
import SwiftUI

/// 手動シャッター式の書類スキャン用カメラビュー。
/// VisionKit（VNDocumentCameraViewController）には撮影タイミングをユーザーへ
/// 委ねる API が無いため、AVCaptureSession + 自前 UI で置き換えている。
/// フルスクリーンプレビュー上に検出四角形の緑オーバレイを重ね、
/// シャッターボタンで任意タイミングの撮影（複数ページ蓄積）を行う。
struct CameraCaptureView: View {

    /// Done 押下時に撮影済み画像配列を返すコールバック。
    let onDone: ([UIImage]) -> Void
    /// キャンセル時のコールバック。
    let onCancel: () -> Void

    /// カメラ制御（セッション・撮影・四角形検出）。
    @State private var controller = CameraController()
    /// 撮影時の白フラッシュ表示フラグ。
    @State private var flash = false
    /// カメラ権限拒否/制限時のアラート表示フラグ。
    @State private var showPermissionAlert = false
    /// セッション/撮影エラーのアラート表示フラグ。
    @State private var showCameraErrorAlert = false
    /// カメラ画面の本体を返す。
    /// - 入力: なし
    /// - 出力: プレビュー + 四角形オーバレイ + シャッター/Done/Cancel のビュー
    /// - 処理: 表示時に権限確認→セッション構成・開始、非表示時に停止する
    var body: some View {
        ZStack {
            GeometryReader { geometry in
                CameraPreviewView(session: controller.captureSession,
                                  isConfigured: controller.isConfigured)
                if let quad = controller.detectedQuad, controller.frameSize != .zero {
                    let points = Self.overlayPoints(
                        normalized: quad,
                        bufferSize: controller.frameSize,
                        viewSize: geometry.size)
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                        path.closeSubpath()
                    }
                    .stroke(.green, lineWidth: 3)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // 撮影時の白フラッシュ
            if flash {
                Color.white.ignoresSafeArea().allowsHitTesting(false)
            }

            VStack {
                Spacer()
                bottomBar
            }
        }
        .task { await startIfAuthorized() }
        .onDisappear { controller.stop() }
        .onChange(of: controller.error) { _, error in
            if error != nil { showCameraErrorAlert = true }
        }
        .alert("Camera access is required to scan documents.", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
                onCancel()
            }
            Button("Cancel", role: .cancel) { onCancel() }
        }
        .alert("Camera Error", isPresented: $showCameraErrorAlert) {
            Button("OK", role: .cancel) { controller.clearError() }
        } message: {
            Text(controller.error?.localizedDescription ?? "")
        }
    }

    /// 下部バー（Cancel・シャッター・カウント/サムネイル・Done）を返す。
    /// - 入力: なし
    /// - 出力: 下部操作バーのビュー
    /// - 処理: 撮影枚数と直前サムネイルを表示し、撮影 pending 中は Done を無効化する
    private var bottomBar: some View {
        HStack {
            Button("Cancel") { onCancel() }
                .foregroundStyle(.white)
            Spacer()
            shutterButton
            Spacer()
            VStack(spacing: 4) {
                if let last = controller.lastCapture {
                    Image(uiImage: last)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 56)
                        .clipped()
                        .cornerRadius(4)
                } else {
                    Color.clear
                        .frame(width: 44, height: 56)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(.white.opacity(0.4), lineWidth: 1)
                        )
                }
                Text("\(controller.captures.count)")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
            Button("Done") {
                guard controller.canFinish else { return }
                onDone(controller.captures)
            }
                .disabled(!controller.canFinish)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    /// 大きなシャッターボタンを返す。
    /// - 入力: なし
    /// - 出力: シャッターボタンのビュー
    /// - 処理: 押下で白フラッシュを短時間表示して撮影する
    private var shutterButton: some View {
        Button {
            guard controller.isConfigured, !controller.isCapturing else { return }
            flash = true
            controller.capture()
            Task {
                try? await Task.sleep(for: .milliseconds(150))
                flash = false
            }
        } label: {
            Circle()
                .fill(.white)
                .frame(width: 72, height: 72)
                .overlay(Circle().stroke(.white.opacity(0.6), lineWidth: 4).padding(-6))
        }
        .disabled(!controller.isConfigured || controller.isCapturing)
    }

    /// 権限状態に応じてセッションを開始する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: authorized → 構成+開始。notDetermined → 要求して許可なら開始。
    ///   denied/restricted → 設定画面を開けるアラートを表示する
    private func startIfAuthorized() async {
        let generation = controller.beginActivation()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            guard controller.isCurrent(generation, taskIsCancelled: Task.isCancelled) else { return }
            controller.start(generation: generation)
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard controller.isCurrent(generation, taskIsCancelled: Task.isCancelled) else { return }
            if granted {
                controller.start(generation: generation)
            } else {
                controller.stop()
                showPermissionAlert = true
            }
        case .denied, .restricted:
            guard controller.isCurrent(generation, taskIsCancelled: Task.isCancelled) else { return }
            controller.stop()
            showPermissionAlert = true
        @unknown default:
            guard controller.isCurrent(generation, taskIsCancelled: Task.isCancelled) else { return }
            controller.stop()
            showPermissionAlert = true
        }
    }

    /// Vision 正規化座標（y-up）の四角形を aspect-fill プレビューのビュー座標へ変換する。
    /// - 入力: normalized … 正規化座標の点列（0〜1、左下原点）、
    ///   bufferSize … 縦向きバッファのサイズ、viewSize … プレビュービューのサイズ
    /// - 出力: ビュー座標（左上原点）の点列
    /// - 処理: aspect-fill のスケール max(vw/bw, vh/bh) を掛け、はみ出し分を中央
    ///   オフセットで補正し、y を反転する。ピュア関数として単体テスト可能
    static func overlayPoints(normalized: [CGPoint],
                              bufferSize: CGSize,
                              viewSize: CGSize) -> [CGPoint] {
        let scale = max(viewSize.width / bufferSize.width,
                        viewSize.height / bufferSize.height)
        let scaled = CGSize(width: bufferSize.width * scale,
                            height: bufferSize.height * scale)
        let offset = CGPoint(x: (viewSize.width - scaled.width) / 2,
                             y: (viewSize.height - scaled.height) / 2)
        return normalized.map { point in
            CGPoint(x: point.x * scaled.width + offset.x,
                    y: (1 - point.y) * scaled.height + offset.y)
        }
    }
}

/// AVCaptureVideoPreviewLayer を表示する UIViewRepresentable。
private struct CameraPreviewView: UIViewRepresentable {

    /// 表示対象のキャプチャセッション。
    let session: AVCaptureSession
    /// セッション構成後に接続の回転を再設定するための更新トリガー。
    let isConfigured: Bool

    /// プレビュー用 UIView を生成する。
    /// - 入力: context … Representable コンテキスト
    /// - 出力: プレビューレイヤを持つ UIView
    /// - 処理: aspectFill・縦向き回転を設定しセッションを接続する
    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.updateRotation()
        return view
    }

    /// プレビュー UIView を更新する。
    /// - 入力: uiView … 対象、context … コンテキスト
    /// - 出力: なし
    /// - 処理: セッション構成後に生成された接続へ縦向きの回転を設定する
    func updateUIView(_ uiView: PreviewView, context: Context) {
        if isConfigured { uiView.updateRotation() }
    }

    /// レイヤーが AVCaptureVideoPreviewLayer の UIView。
    final class PreviewView: UIView {
        /// 利用可能な接続に、解析フレームと同じ縦向きの回転を設定する。
        /// - 入力: なし
        /// - 出力: なし
        /// - 処理: 接続が 90 度の回転をサポートしている場合に適用する
        func updateRotation() {
            if let connection = previewLayer.connection,
               connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
        /// このビューの backing layer クラス（AVCaptureVideoPreviewLayer 固定）。
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        /// プレビューレイヤーを返す（layerClass で AVCaptureVideoPreviewLayer が保証される）。
        var previewLayer: AVCaptureVideoPreviewLayer {
            // layerClass で型が保証されるため force cast（失敗しない）
            layer as! AVCaptureVideoPreviewLayer // swiftlint:disable:this force_cast
        }
    }
}
