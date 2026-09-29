import PDFKit
import PhotosUI
import SwiftUI
import VisionKit

/// 保存済み PDF の一覧を表示するルートビュー。
struct DocumentListView: View {

    /// 共有のドキュメントストア。
    @Environment(DocumentStore.self) private var store

    /// カメラシート表示フラグ。
    @State private var showCamera = false
    /// 写真選択シート表示フラグ。
    @State private var showPicker = false
    /// PhotosPicker で選択されたアイテム。
    @State private var pickedItems: [PhotosPickerItem] = []
    /// エディタへ渡す新規ドラフトページ。非 nil でナビゲーション発火。
    @State private var draftPages: [ScannedPage]?
    /// 取り込み中のフルスクリーンプログレス表示フラグ。
    @State private var isProcessing = false
    /// エラーアラートに表示するメッセージ。
    @State private var errorMessage: String?
    /// 「ドキュメントが検出できなかった」確認アラート用の未検出画像。
    @State private var undetectedImages: [UIImage] = []
    /// 検出済みだがアラート回答待ちのページ。
    @State private var pendingDetectedPages: [ScannedPage] = []
    /// リネーム対象のドキュメント。
    @State private var renameTarget: SavedDocument?
    /// リネーム入力文字列。
    @State private var renameText = ""
    /// エラー発生時のアラート表示フラグ。
    @State private var showError = false

    /// 一覧画面の本体を返す。
    /// - 入力: なし
    /// - 出力: ドキュメント一覧ビュー
    /// - 処理: 空状態・リスト・ツールバー・各種シート/アラートを構成する
    var body: some View {
        NavigationStack {
            Group {
                if store.documents.isEmpty {
                    ContentUnavailableView(
                        "No Scanned Documents",
                        systemImage: "doc.text.viewfinder",
                        description: Text("Tap Scan or Import to add your first document.")
                    )
                } else {
                    documentList
                }
            }
            .navigationTitle("DocScanner")
            .safeAreaInset(edge: .bottom) {
                // iOS 26 の bottomBar ツールバーでは .titleAndIcon が効かないため
                // safeAreaInset でフル幅ボタンを直接配置する
                HStack(spacing: 12) {
                    Button {
                        guard VNDocumentCameraViewController.isSupported else {
                            errorMessage = "The document camera is not available on this device."
                            showError = true
                            return
                        }
                        showCamera = true
                    } label: {
                        Label("Scan", systemImage: "doc.text.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button {
                        showPicker = true
                    } label: {
                        Label("Import", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                .padding(.horizontal)
            }
            .navigationDestination(item: $draftPages) { pages in
                EditorView(pages: pages)
            }
            .fullScreenCover(isPresented: $showCamera) {
                DocumentCameraView(
                    onScan: { images in
                        showCamera = false
                        do {
                            // メモリ削減のため取り込み時に長辺を抑える
                            let processor = DocumentImageProcessor()
                            draftPages = try images.map {
                                ScannedPage(baseImage: try processor.downscaled($0))
                            }
                        } catch {
                            present(error)
                        }
                    },
                    onError: { error in
                        showCamera = false
                        present(error)
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPicker, selection: $pickedItems,
                          maxSelectionCount: 20, matching: .images)
            .onChange(of: pickedItems) { _, items in
                guard !items.isEmpty else { return }
                pickedItems = []
                importItems(items)
            }
            .alert("DocScanner", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .alert("No document edges were detected.", isPresented: undetectedAlertPresented) {
                Button("Use Full Image") { acceptUndetectedImages() }
                Button("Cancel", role: .cancel) { discardUndetectedImages() }
            }
            .alert("Rename", isPresented: renameAlertPresented) {
                TextField("File name", text: $renameText)
                Button("Rename") { performRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .overlay {
                if isProcessing {
                    ProgressView("Processing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    /// 未検出アラートの表示バインディングを返す。
    /// - 入力: なし
    /// - 出力: undetectedImages が空でないことを表す Binding
    /// - 処理: 配列の空/非空を Bool バインディングに変換する
    private var undetectedAlertPresented: Binding<Bool> {
        Binding(
            get: { !undetectedImages.isEmpty },
            set: { if !$0 { undetectedImages = [] } }
        )
    }

    /// リネームアラートの表示バインディングを返す。
    /// - 入力: なし
    /// - 出力: renameTarget の有無を表す Binding
    /// - 処理: renameTarget の nil/非 nil を Bool バインディングに変換する
    private var renameAlertPresented: Binding<Bool> {
        Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )
    }

    /// 保存済みドキュメントのリストを返す。
    /// - 入力: なし
    /// - 出力: 行・スワイプ削除・コンテキストメニュー付きの List
    /// - 処理: store.documents を描画し、タップで PDFPreviewView へ遷移する
    private var documentList: some View {
        List {
            ForEach(store.documents) { document in
                NavigationLink {
                    PDFPreviewView(document: document)
                } label: {
                    DocumentRow(document: document)
                }
                .contextMenu {
                    Button {
                        renameText = document.name
                        renameTarget = document
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    ShareLink(item: document.url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        delete(document)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
            .onDelete { offsets in
                for index in offsets {
                    delete(store.documents[index])
                }
            }
        }
    }

    /// PhotosPicker の選択アイテムを読み込み、書類検出を実行する。
    /// - 入力: items … 選択された PhotosPickerItem 配列
    /// - 出力: なし（draftPages または undetectedImages を更新する）
    /// - 処理: バックグラウンドで画像ロード → 各画像に対して検出を試行し、
    ///   検出できたものはページ化、失敗したものは確認アラート用に保持する
    private func importItems(_ items: [PhotosPickerItem]) {
        isProcessing = true
        Task.detached {
            do {
                let images = try await PageImporter.loadImages(from: items)
                let result = try PageImporter().makePages(from: images)
                await MainActor.run {
                    isProcessing = false
                    pendingDetectedPages = result.detectedPages
                    if result.undetectedImages.isEmpty {
                        if !result.detectedPages.isEmpty { draftPages = result.detectedPages }
                    } else {
                        undetectedImages = result.undetectedImages
                    }
                }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    self.present(error)
                }
            }
        }
    }

    /// 未検出画像をそのままページとして採用しエディタを開く。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: pendingDetectedPages と未検出画像を結合して draftPages に設定する
    private func acceptUndetectedImages() {
        let extra = undetectedImages.map { ScannedPage(baseImage: $0) }
        undetectedImages = []
        let all = pendingDetectedPages + extra
        pendingDetectedPages = []
        if !all.isEmpty { draftPages = all }
    }

    /// 未検出画像を破棄し、検出済み分のみでエディタを開く。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: undetectedImages をクリアし pendingDetectedPages を draftPages に設定する
    private func discardUndetectedImages() {
        undetectedImages = []
        if !pendingDetectedPages.isEmpty { draftPages = pendingDetectedPages }
        pendingDetectedPages = []
    }

    /// ドキュメントを削除する。
    /// - 入力: document … 削除対象
    /// - 出力: なし
    /// - 処理: store.delete を呼び、失敗時はエラーアラートを出す
    private func delete(_ document: SavedDocument) {
        do {
            try store.delete(document)
        } catch {
            present(error)
        }
    }

    /// リネームを実行する。
    /// - 入力: なし（renameTarget と renameText を参照）
    /// - 出力: なし
    /// - 処理: store.rename を呼び、失敗時はエラーアラートを出す
    private func performRename() {
        guard let target = renameTarget else { return }
        do {
            try store.rename(target, to: renameText)
        } catch {
            present(error)
        }
        renameTarget = nil
    }

    /// エラーをアラート表示する。
    /// - 入力: error … 表示するエラー
    /// - 出力: なし
    /// - 処理: localizedDescription をアラートへ渡す
    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}

/// 一覧の 1 行（サムネイル + 名前 + メタ情報）。
private struct DocumentRow: View {

    /// 対象ドキュメント。
    let document: SavedDocument
    /// サムネイル画像。
    @State private var thumbnail: UIImage?

    /// 行の本体を返す。
    /// - 入力: なし
    /// - 出力: サムネイル + テキストの HStack
    /// - 処理: バックグラウンドで PDF の 1 ページ目を描画してサムネイル化する
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "doc.richtext")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text(document.name).font(.headline).lineLimit(1)
                Text(metaText).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task { await loadThumbnail() }
    }

    /// メタ情報文字列（日時・ページ数・サイズ）を返す。
    /// - 入力: なし
    /// - 出力: "yyyy-MM-dd HH:mm · n pages · x.x MB" 形式の文字列
    /// - 処理: 各プロパティを整形して結合する
    private var metaText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let size = ByteCountFormatter.string(fromByteCount: document.fileSize, countStyle: .file)
        let pages = document.pageCount == 1 ? "1 page" : "\(document.pageCount) pages"
        return "\(formatter.string(from: document.createdAt)) · \(pages) · \(size)"
    }

    /// PDF の 1 ページ目からサムネイルを生成する。
    /// - 入力: なし
    /// - 出力: なし（thumbnail を更新する）
    /// - 処理: PDFKit で 1 ページ目を 88x112 に描画する
    private func loadThumbnail() async {
        let url = document.url
        let image = await Task.detached { () -> UIImage? in
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 88, height: 112), for: .mediaBox)
        }.value
        thumbnail = image
    }
}
