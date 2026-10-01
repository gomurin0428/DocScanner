import SwiftUI
import UIKit

/// 実際に描画された輪郭を、SwiftUI の次の更新を待たずにシャッターへ渡す。
@MainActor
final class CameraPreviewSelection {
    struct Snapshot {
        let boundary: DocumentBoundary?
    }

    private(set) var snapshot = Snapshot(boundary: nil)

    /// 描画済みの輪郭（枠を消した場合は nil）を保存する。
    func display(_ boundary: DocumentBoundary?) {
        snapshot = Snapshot(boundary: boundary)
    }
}

/// 指が触れた瞬間の表示輪郭を固定し、離したときに手動撮影する。
struct CameraShutterButton: UIViewRepresentable {
    let selection: CameraPreviewSelection
    let isEnabled: Bool
    let onCapture: (DocumentBoundary?) -> Void

    /// プレビューと同じ選択状態を持つシャッターを生成する。
    func makeUIView(context: Context) -> Control {
        Control(selection: selection, onCapture: onCapture)
    }

    /// 撮影可否とコールバックを更新し、無効化時には押下状態を破棄する。
    func updateUIView(_ view: Control, context: Context) {
        view.onCapture = onCapture
        view.isEnabled = isEnabled
        if !isEnabled { view.cancelPress() }
    }

    final class Control: UIButton {
        private let selection: CameraPreviewSelection
        private var pressedSelection: CameraPreviewSelection.Snapshot?
        var onCapture: (DocumentBoundary?) -> Void

        /// タッチ開始・キャンセル・標準のボタン実行イベントを接続する。
        init(selection: CameraPreviewSelection, onCapture: @escaping (DocumentBoundary?) -> Void) {
            self.selection = selection
            self.onCapture = onCapture
            super.init(frame: .zero)
            backgroundColor = .white
            layer.cornerRadius = 36
            layer.borderWidth = 4
            layer.borderColor = UIColor.lightGray.cgColor
            accessibilityLabel = "Take photo"
            addTarget(self, action: #selector(beginPress), for: .touchDown)
            addTarget(self, action: #selector(cancelPress), for: [.touchCancel, .touchUpOutside])
            addTarget(self, action: #selector(capture), for: .primaryActionTriggered)
        }

        /// Storyboard 経由での生成は使用しない。
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        /// 指が触れた時点の枠を固定する。枠が無い状態も明示的に保持する。
        @objc func beginPress() {
            guard isEnabled else { return }
            pressedSelection = selection.snapshot
        }

        /// キャンセルした押下の輪郭を次の撮影へ持ち越さない。
        @objc func cancelPress() {
            pressedSelection = nil
        }

        /// タッチは押下開始時、キーボード等は実行時の表示輪郭で撮影する。
        @objc func capture() {
            guard isEnabled else { return }
            let snapshot = pressedSelection ?? selection.snapshot
            pressedSelection = nil
            onCapture(snapshot.boundary)
        }
    }
}
