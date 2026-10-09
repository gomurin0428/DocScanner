import AVFoundation
import PDFKit
import PhotosUI
import SwiftUI

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
    /// アラート回答待ちの順序付きインポート結果。
    @State private var pendingImportResult: ImportResult?
    /// 未検出画像の確認アラート表示状態。
    @State private var showUndetectedAlert = false
    /// リネーム対象のドキュメント。
    @State private var renameTarget: SavedDocument?
    /// リネーム入力文字列。
    @State private var renameText = ""
    /// エラー発生時のアラート表示フラグ。
    @State private var showError = false
    @State private var storeLoadError: String?
    @State private var deleteTarget: SavedDocument?
    @State private var showDeleteConfirmation = false

    /// 一覧画面の本体を返す。
    /// - 入力: なし
    /// - 出力: ドキュメント一覧ビュー
    /// - 処理: 空状態・リスト・ツールバー・各種シート/アラートを構成する
    var body: some View {
        NavigationStack {
            Group {
                if !store.isLoaded {
                    ContentUnavailableView {
                        Label("Storage Unavailable", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(storeLoadError ?? "Loading saved documents…")
                    } actions: {
                        Button("Retry", systemImage: "arrow.clockwise") {
                            Task { await loadStore() }
                        }
                    }
                } else if store.documents.isEmpty {
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
                        guard CameraController.isAvailable() else {
                            errorMessage = "The camera is not available on this device."
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
                CameraCaptureView(
                    onDone: { images in
                        showCamera = false
                        handleSources(images)
                    },
                    onCancel: { showCamera = false }
                )
                .ignoresSafeArea()
            }
            .photosPicker(isPresented: $showPicker, selection: $pickedItems,
                          maxSelectionCount: 20, selectionBehavior: .ordered,
                          matching: .images)
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
            .alert("No document edges were detected.", isPresented: $showUndetectedAlert) {
                Button("Use Full Image") { acceptUndetectedImages() }
                Button("Cancel", role: .cancel) { discardUndetectedImages() }
            }
            .alert("Rename", isPresented: renameAlertPresented) {
                TextField("File name", text: $renameText)
                Button("Rename") { performRename() }
                Button("Cancel", role: .cancel) { renameTarget = nil }
            }
            .confirmationDialog("Delete document?", isPresented: $showDeleteConfirmation,
                                presenting: deleteTarget) { document in
                Button("Delete", role: .destructive) { delete(document) }
                Button("Cancel", role: .cancel) { deleteTarget = nil }
            } message: { document in
                Text("Delete \(document.name)? This cannot be undone.")
            }
            .overlay {
                if isProcessing {
                    ProgressView("Processing…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task {
                if !store.isLoaded { await loadStore() }
            }
        }
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
        let readable = store.documents.filter(\.isReadable)
        let unreadable = store.documents.filter { !$0.isReadable }
        return List {
            if !readable.isEmpty {
                Section("Documents") {
                    ForEach(readable) { document in
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
                                requestDelete(document)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            requestDelete(readable[index])
                        }
                    }
                }
            }
            if !unreadable.isEmpty {
                Section("Unreadable Documents") {
                    ForEach(unreadable) { document in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(document.name).font(.headline)
                            Text(document.issue ?? "This PDF could not be read.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .accessibilityLabel("Error: \(document.issue ?? "This PDF could not be read.")")
                            HStack {
                                ShareLink(item: document.url) {
                                    Label("Share", systemImage: "square.and.arrow.up")
                                }
                                Button {
                                    renameText = document.name
                                    renameTarget = document
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    requestDelete(document)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
        }
        .refreshable { await loadStore() }
    }

    /// PhotosPicker の選択アイテムを読み込み、書類検出を実行する。
    /// - 入力: items … 選択された PhotosPickerItem 配列
    /// - 出力: なし（draftPages または pendingImportResult を更新する）
    /// - 処理: バックグラウンドで画像ロード → 各画像に対して検出を試行し、
    ///   検出できたものはページ化、失敗したものは確認アラート用に保持する
    private func importItems(_ items: [PhotosPickerItem]) {
        isProcessing = true
        Task.detached {
            do {
                let images = try await PageImporter.loadImages(from: items)
                await MainActor.run { handleImages(images) }
            } catch {
                await MainActor.run {
                    isProcessing = false
                    self.present(error)
                }
            }
        }
    }

    /// UIImage 配列を書類検出パイプラインへ通し結果を反映する（カメラ・写真共通）。
    /// - 入力: images … 取り込み済み画像配列
    /// - 出力: なし（draftPages または pendingImportResult を更新する）
    /// - 処理: バックグラウンドで makePages を実行し、順序付き結果を保持して選択を確認する
    private func handleImages(_ images: [UIImage]) {
        handleSources(images.map { .photo($0) })
    }

    /// 写真と固定輪郭付き撮影を処理し、入力順で編集画面へ渡す。
    private func handleSources(_ sources: [PageSource]) {
        isProcessing = true
        Task.detached {
            do {
                let result = try PageImporter().makePages(from: sources)
                await MainActor.run {
                    isProcessing = false
                    if result.undetectedImages.isEmpty {
                        let pages = result.pages(includingUndetected: false)
                        if !pages.isEmpty { draftPages = pages }
                    } else {
                        pendingImportResult = result
                        showUndetectedAlert = true
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
    /// - 処理: 全 Entry を入力順にページ化して draftPages に設定する
    private func acceptUndetectedImages() {
        let all = pendingImportResult?.pages(includingUndetected: true) ?? []
        pendingImportResult = nil
        if !all.isEmpty { draftPages = all }
    }

    /// 未検出画像を破棄し、検出済み分のみでエディタを開く。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 検出済み Entry のみを入力順に draftPages へ設定する
    private func discardUndetectedImages() {
        let detected = pendingImportResult?.pages(includingUndetected: false) ?? []
        pendingImportResult = nil
        if !detected.isEmpty { draftPages = detected }
    }

    /// ドキュメントを削除する。
    /// - 入力: document … 削除対象
    /// - 出力: なし
    /// - 処理: store.delete を呼び、失敗時はエラーアラートを出す
    private func delete(_ document: SavedDocument) {
        do {
            try store.delete(document)
            deleteTarget = nil
        } catch {
            present(error)
        }
    }

    private func requestDelete(_ document: SavedDocument) {
        deleteTarget = document
        showDeleteConfirmation = true
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

    private func loadStore() async {
        storeLoadError = nil
        do {
            try await store.reloadAsync()
        } catch {
            storeLoadError = error.localizedDescription
            present(error)
        }
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
        .task(id: document.url) { await loadThumbnail() }
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
        thumbnail = nil
        let worker = Task.detached(priority: .background) { () -> UIImage? in
            try Task.checkCancellation()
            guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
            return page.thumbnail(of: CGSize(width: 88, height: 112), for: .mediaBox)
        }
        do {
            let image = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
            try Task.checkCancellation()
            guard document.url == url else { return }
            thumbnail = image
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.error("Saved document thumbnail", error: error)
        }
    }
}
