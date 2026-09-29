import SwiftUI
import VisionKit

/// VNDocumentCameraViewController を SwiftUI から使うためのラッパー。
struct DocumentCameraView: UIViewControllerRepresentable {

    /// スキャン完了時にページ画像配列を返すコールバック。
    let onScan: ([UIImage]) -> Void
    /// スキャン失敗時にエラーを返すコールバック。
    let onError: (Error) -> Void
    /// キャンセル時のコールバック。
    let onCancel: () -> Void

    /// カメラビューコントローラを生成する。
    /// - 入力: context … Representable コンテキスト
    /// - 出力: delegate 設定済みの VNDocumentCameraViewController
    /// - 処理: コーディネータを delegate に設定して返す
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    /// ビューコントローラを更新する。
    /// - 入力: uiViewController … 対象、context … コンテキスト
    /// - 出力: なし
    /// - 処理: 更新する状態は無いため何もしない
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    /// コーディネータを生成する。
    /// - 入力: なし
    /// - 出力: Coordinator インスタンス
    /// - 処理: コールバックを渡して生成する
    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan, onError: onError, onCancel: onCancel)
    }

    /// VNDocumentCameraViewControllerDelegate の実装。
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        /// スキャン完了コールバック。
        private let onScan: ([UIImage]) -> Void
        /// エラーコールバック。
        private let onError: (Error) -> Void
        /// キャンセルコールバック。
        private let onCancel: () -> Void

        /// コーディネータを初期化する。
        /// - 入力: onScan / onError / onCancel … 各コールバック
        /// - 出力: 初期化済み Coordinator
        /// - 処理: 各コールバックを保持する
        init(onScan: @escaping ([UIImage]) -> Void,
             onError: @escaping (Error) -> Void,
             onCancel: @escaping () -> Void) {
            self.onScan = onScan
            self.onError = onError
            self.onCancel = onCancel
        }

        /// スキャン完了を受け取る。
        /// - 入力: controller … カメラ VC、scan … スキャン結果
        /// - 出力: なし
        /// - 処理: 全ページを UIImage に変換して onScan へ渡す
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            var images: [UIImage] = []
            for index in 0..<scan.pageCount {
                images.append(scan.imageOfPage(at: index))
            }
            onScan(images)
        }

        /// キャンセルを受け取る。
        /// - 入力: controller … カメラ VC
        /// - 出力: なし
        /// - 処理: onCancel を呼ぶ
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            onCancel()
        }

        /// スキャン失敗を受け取る。
        /// - 入力: controller … カメラ VC、error … 発生したエラー
        /// - 出力: なし
        /// - 処理: onError へエラーを渡す
        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            onError(error)
        }
    }
}
