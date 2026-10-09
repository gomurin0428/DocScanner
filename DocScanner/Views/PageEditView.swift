import SwiftUI

/// 1 ページ分のプレビュー・フィルタ・回転・削除を行う編集ビュー。
struct PageEditView: View {

    /// 共有の下書きモデル（@Observable でページ変更がこのビューへ伝播する）。
    let draft: DocumentDraft
    /// 編集対象ページの識別子。
    let pageID: UUID
    /// 画面を閉じるための dismiss アクション。
    @Environment(\.dismiss) private var dismiss
    /// 現在のフィルタ・回転を反映した表示画像。
    @State private var rendered: UIImage?
    /// エラーメッセージ。
    @State private var errorMessage: String?
    /// エラーアラート表示フラグ。
    @State private var showError = false

    /// 下書きモデルと対象ページ id 付きで初期化する。
    /// - 入力: draft … 共有下書き、pageID … 編集対象ページの識別子
    /// - 出力: 初期化済み PageEditView
    /// - 処理: プロパティへ代入する
    ///   （ページ値を入力にすると親の状態変化で遷移先が再生成され
    ///   表示中ビューが状態を失うため、参照型モデル + id の安定入力にする）
    init(draft: DocumentDraft, pageID: UUID) {
        self.draft = draft
        self.pageID = pageID
    }

    /// 編集画面の本体を返す。
    /// - 入力: なし
    /// - 出力: プレビュー + フィルタピッカー + 回転/削除ボタンのビュー
    /// - 処理: draft から現在のページを読み、編集操作は draft のメソッドへ委譲する
    var body: some View {
        Group {
            if draft.page(id: pageID) == nil {
                // 削除済みページへのアクセス（dismiss 中の一瞬）は空表示にする。
                // ここで dismiss すると削除ボタン側の dismiss と二重になり親まで pop されるため呼ばない
                ContentUnavailableView("Page Deleted", systemImage: "trash")
            } else {
                editContent
            }
        }
        .navigationTitle("Edit Page")
        .task(id: renderKey) { await renderPage() }
        .alert("DocScanner", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// 編集対象が存在する場合の本体ビューを返す。
    /// - 入力: なし
    /// - 出力: プレビュー + 操作ボタンの VStack
    /// - 処理: フィルタは draft への読み書きバインディング、回転は draft.rotate へ委譲する
    private var editContent: some View {
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

            Picker("Filter", selection: filterSelection) {
                ForEach(PageFilter.allCases) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 24) {
                Button { draft.rotate(by: -1, for: pageID) } label: {
                    Label("Rotate Left", systemImage: "rotate.left")
                }
                Button { draft.rotate(by: 1, for: pageID) } label: {
                    Label("Rotate Right", systemImage: "rotate.right")
                }
                Button(role: .destructive) {
                    // 先に dismiss してから削除する（削除済み状態のまま再描画されるのを防ぐ）
                    dismiss()
                    draft.remove(id: pageID)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .padding(.bottom)
        }
        .padding()
    }

    /// フィルタピッカー用の読み書きバインディングを返す。
    /// - 入力: なし
    /// - 出力: draft の対象ページ filter への Binding
    /// - 処理: get は draft から読み、set は draft.setFilter へ書き込む
    private var filterSelection: Binding<PageFilter> {
        Binding(
            get: { draft.page(id: pageID)?.filter ?? .original },
            set: { draft.setFilter($0, for: pageID) }
        )
    }

    /// 再レンダリングのトリガーキーを返す。
    /// - 入力: なし
    /// - 出力: フィルタと回転数を結合した文字列
    /// - 処理: draft の現在ページからキーを作り、編集状態が変わったら task を再実行させる
    private var renderKey: String {
        guard let page = draft.page(id: pageID) else { return "deleted-\(pageID)" }
        return "\(page.filter.rawValue)-\(page.quarterTurns)"
    }

    /// ページを現在の編集状態でレンダリングする。
    /// - 入力: なし
    /// - 出力: なし（rendered を更新する）
    /// - 処理: バックグラウンドで renderedImage を呼び、失敗時はエラーアラートを出す。
    ///   レンダリング中に編集が進んだ場合は古い結果を捨てるため、
    ///   完了時の renderKey が開始時と同じときだけ rendered を更新する
    private func renderPage() async {
        let key = renderKey
        rendered = nil
        guard let snapshot = draft.page(id: pageID) else { return }
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try snapshot.renderedImage()
        }
        do {
            let image = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
            try Task.checkCancellation()
            if renderKey == key {
                rendered = image
            }
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.error("Page editor error presentation", error: error)
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
