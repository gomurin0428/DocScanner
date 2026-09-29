import PDFKit
import SwiftUI

/// PDFView を SwiftUI で使うためのラッパー。
private struct PDFKitView: UIViewRepresentable {

    /// 表示する PDF の URL。
    let url: URL

    /// PDFView を生成する。
    /// - 入力: context … Representable コンテキスト
    /// - 出力: ドキュメントを読み込んだ PDFView
    /// - 処理: autoScales を有効化して PDFDocument を設定する
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.document = PDFDocument(url: url)
        return view
    }

    /// PDFView を更新する。
    /// - 入力: uiView … 対象、context … コンテキスト
    /// - 出力: なし
    /// - 処理: URL が変わった場合にドキュメントを再読込する
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.documentURL != url {
            uiView.document = PDFDocument(url: url)
        }
    }
}

/// 保存済み PDF のプレビュー・共有・削除を行うビュー。
struct PDFPreviewView: View {

    /// 表示対象のドキュメント。
    let document: SavedDocument
    /// 共有のドキュメントストア。
    @Environment(DocumentStore.self) private var store
    /// 画面を閉じるための dismiss アクション。
    @Environment(\.dismiss) private var dismiss
    /// エラーメッセージ。
    @State private var errorMessage: String?
    /// エラーアラート表示フラグ。
    @State private var showError = false

    /// プレビュー画面の本体を返す。
    /// - 入力: なし
    /// - 出力: PDFView + 共有/削除ボタンのビュー
    /// - 処理: ページ全体を PDFKit で表示し、ツールバーに ShareLink と Delete を置く
    var body: some View {
        PDFKitView(url: document.url)
            .navigationTitle(document.name)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: document.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        deleteDocument()
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .alert("DocScanner", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
    }

    /// ドキュメントを削除して画面を閉じる。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: store.delete を呼び、失敗時はエラーアラートを出す
    private func deleteDocument() {
        do {
            try store.delete(document)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            showError = true
        }
    }
}
