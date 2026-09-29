import SwiftUI

/// 1 ページ分のプレビュー・フィルタ・回転・削除を行う編集ビュー。
struct PageEditView: View {

    /// 編集対象ページ（親の配列要素へのバインディング）。
    @Binding var page: ScannedPage
    /// ページ削除時に呼ぶコールバック。
    let onDelete: () -> Void
    /// 画面を閉じるための dismiss アクション。
    @Environment(\.dismiss) private var dismiss
    /// 現在のフィルタ・回転を反映した表示画像。
    @State private var rendered: UIImage?
    /// エラーメッセージ。
    @State private var errorMessage: String?
    /// エラーアラート表示フラグ。
    @State private var showError = false

    /// ページを削除し画面を閉じるコールバック付きで初期化する。
    /// - 入力: page … 対象ページの Binding、onDelete … 削除コールバック
    /// - 出力: 初期化済み PageEditView
    /// - 処理: プロパティへ代入する
    init(page: Binding<ScannedPage>, onDelete: @escaping () -> Void) {
        _page = page
        self.onDelete = onDelete
    }

    /// 編集画面の本体を返す。
    /// - 入力: なし
    /// - 出力: プレビュー + フィルタピッカー + 回転/削除ボタンのビュー
    /// - 処理: 編集状態が変わるたびに再レンダリングして表示する
    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let rendered {
                    Image(uiImage: rendered)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Picker("Filter", selection: $page.filter) {
                ForEach(PageFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 24) {
                Button { page.quarterTurns -= 1 } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                Button { page.quarterTurns += 1 } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                Button(role: .destructive) {
                    onDelete()
                    dismiss()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .padding(.bottom)
        }
        .padding()
        .navigationTitle("Edit Page")
        .task(id: renderKey) { await renderPage() }
        .alert("DocScanner", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 再レンダリングのトリガーキーを返す。
    /// - 入力: なし
    /// - 出力: フィルタと回転数を結合した文字列
    /// - 処理: 編集状態が変わったら task を再実行させる
    private var renderKey: String {
        "\(page.filter.rawValue)-\(page.quarterTurns)"
    }

    /// ページを現在の編集状態でレンダリングする。
    /// - 入力: なし
    /// - 出力: なし（rendered を更新する）
    /// - 処理: バックグラウンドで renderedImage を呼び、失敗時はエラーアラートを出す
    private func renderPage() async {
        let snapshot = page
        do {
            let image = try await Task.detached {
                try snapshot.renderedImage()
            }.value
            rendered = image
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
