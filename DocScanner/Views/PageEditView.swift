import SwiftUI

/// 1 ページ分のプレビュー・フィルタ・回転・削除を行う編集ビュー。
struct PageEditView: View {

    /// 編集対象ページ（ローカル状態。変更は onChange で親へ通知する）。
    @State private var page: ScannedPage
    /// ページの編集内容が変わったときに呼ぶコールバック。
    let onChange: (ScannedPage) -> Void
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

    /// ページと変更・削除コールバック付きで初期化する。
    /// - 入力: page … 初期ページ値、onChange … 編集変更コールバック、onDelete … 削除コールバック
    /// - 出力: 初期化済み PageEditView
    /// - 処理: ローカル @State に初期値を保持しコールバックを代入する
    ///   （カスタム Binding の get/set では SwiftUI の依存解決が働かず
    ///   フィルタ変更時に body 再評価されないためローカル状態で編集する）
    init(page: ScannedPage,
         onChange: @escaping (ScannedPage) -> Void,
         onDelete: @escaping () -> Void) {
        _page = State(initialValue: page)
        self.onChange = onChange
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
        .onChange(of: renderKey) { _, _ in self.onChange(page) }
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
