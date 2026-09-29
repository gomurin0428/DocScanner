import PhotosUI
import SwiftUI
import VisionKit

/// 新規スキャンドキュメントのページ編集ビュー（サムネイル一覧・並べ替え・保存）。
struct EditorView: View {

    /// 共有のドキュメントストア。
    @Environment(DocumentStore.self) private var store
    /// 画面を閉じるための dismiss アクション。
    @Environment(\.dismiss) private var dismiss

    /// 編集中のページ一覧。
    @State var pages: [ScannedPage]
    /// ファイル名（拡張子なし）。
    @State private var fileName: String
    /// PDF のページサイズ。
    @State private var pageSize: PDFPageSize = .a4
    /// PDF 生成・保存中フラグ。
    @State private var isSaving = false
    /// 追加ページ取り込み中フラグ。
    @State private var isImporting = false
    /// 保存済み PDF のプレビュー遷移先ドキュメント。
    @State private var savedDocument: SavedDocument?
    /// エラーメッセージ。
    @State private var errorMessage: String?
    /// エラーアラート表示フラグ。
    @State private var showError = false
    /// 追加スキャン用カメラシート表示フラグ。
    @State private var showCamera = false
    /// 追加インポート用 PhotosPicker 表示フラグ。
    @State private var showPicker = false
    /// PhotosPicker 選択アイテム。
    @State private var pickedItems: [PhotosPickerItem] = []
    /// 全ページへ適用するフィルタ選択シート表示フラグ。
    @State private var showFilterSheet = false
    /// 追加取り込み時に検出できなかった画像。
    @State private var undetectedImages: [UIImage] = []
    /// 追加取り込み時に検出できたページ。
    @State private var pendingDetectedPages: [ScannedPage] = []

    /// エディタを初期化する。
    /// - 入力: pages … 初期ページ配列
    /// - 出力: 初期化済み EditorView
    /// - 処理: ページを保持し、ファイル名に日時ベースの既定名を設定する
    init(pages: [ScannedPage]) {
        _pages = State(initialValue: pages)
        _fileName = State(initialValue: FileNameSanitizer.defaultName(for: Date()))
    }

    /// 編集画面の本体を返す。
    /// - 入力: なし
    /// - 出力: ページ一覧 + 名前/用紙設定 + 保存ボタンのビュー
    /// - 処理: List（onMove 対応）でページを表示し、ツールバーに追加・フィルタ一括・保存を置く
    var body: some View {
        List {
            Section {
                ForEach(pages) { page in
                    NavigationLink {
                        PageEditView(
                            page: page,
                            onChange: { update($0) },
                            onDelete: { remove(page.id) }
                        )
                    } label: {
                        PageRow(page: page, number: (pages.firstIndex { $0.id == page.id } ?? 0) + 1)
                    }
                }
                .onMove { source, destination in
                    pages.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    pages.remove(atOffsets: offsets)
                }
            } header: {
                Text("Pages (\(pages.count))")
            }
            Section {
                TextField("File name", text: $fileName)
                Picker("Page Size", selection: $pageSize) {
                    ForEach(PDFPageSize.allCases) { size in
                        Text(size.displayName).tag(size)
                    }
                }
            }
        }
        .navigationTitle("New Document")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button { showCameraOrAlert() } label: {
                        Label("Scan More Pages", systemImage: "doc.text.viewfinder")
                    }
                    Button { showPicker = true } label: {
                        Label("Import from Photos", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label("Add Pages", systemImage: "plus")
                }
                Button { showFilterSheet = true } label: {
                    Label("Filter All", systemImage: "camera.filters")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            // iOS 26 の bottomBar ツールバーではタイトルが出ないためフル幅ボタンで配置する
            Button {
                save()
            } label: {
                Label("Save PDF", systemImage: "square.and.arrow.down")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pages.isEmpty || isSaving)
            .padding(.horizontal)
        }
        .confirmationDialog("Apply Filter to All Pages", isPresented: $showFilterSheet) {
            ForEach(PageFilter.allCases) { filter in
                Button(filter.displayName) { applyFilterToAll(filter) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .navigationDestination(item: $savedDocument) { document in
            PDFPreviewView(document: document)
        }
        .fullScreenCover(isPresented: $showCamera) {
            DocumentCameraView(
                onScan: { images in
                    showCamera = false
                    do {
                        // メモリ削減のため取り込み時に長辺を抑える
                        let processor = DocumentImageProcessor()
                        pages.append(contentsOf: try images.map {
                            ScannedPage(baseImage: try processor.downscaled($0))
                        })
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
        .alert("No document edges were detected.", isPresented: undetectedAlertPresented) {
            Button("Use Full Image") { acceptUndetected() }
            Button("Cancel", role: .cancel) { discardUndetected() }
        }
        .alert("DocScanner", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if isSaving || isImporting {
                ProgressView(isSaving ? "Saving PDF…" : "Processing…")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    /// 未検出アラートの表示バインディングを返す。
    /// - 入力: なし
    /// - 出力: undetectedImages の空/非空を表す Binding
    /// - 処理: 配列の空/非空を Bool バインディングに変換する
    private var undetectedAlertPresented: Binding<Bool> {
        Binding(
            get: { !undetectedImages.isEmpty },
            set: { if !$0 { undetectedImages = [] } }
        )
    }

    /// ページ編集結果を id で pages へ書き戻す。
    /// - 入力: updated … 編集後のページ
    /// - 出力: なし
    /// - 処理: 同じ id の要素が残っていれば差し替える（削除済みなら何もしない）
    private func update(_ updated: ScannedPage) {
        if let index = pages.firstIndex(where: { $0.id == updated.id }) {
            pages[index] = updated
        }
    }

    /// ページを削除する。
    /// - 入力: id … 削除対象のページ識別子
    /// - 出力: なし
    /// - 処理: pages から該当要素を除去する
    private func remove(_ id: UUID) {
        pages.removeAll { $0.id == id }
    }

    /// カメラ対応可否を確認してシートを開く。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 非対応ならエラーアラートを出す
    private func showCameraOrAlert() {
        guard VNDocumentCameraViewController.isSupported else {
            errorMessage = "The document camera is not available on this device."
            showError = true
            return
        }
        showCamera = true
    }

    /// 全ページに同一フィルタを適用する。
    /// - 入力: filter … 適用するフィルタ
    /// - 出力: なし
    /// - 処理: pages の各要素の filter を書き換える
    private func applyFilterToAll(_ filter: PageFilter) {
        for index in pages.indices {
            pages[index].filter = filter
        }
    }

    /// PhotosPicker の選択アイテムを読み込み検出処理を行う。
    /// - 入力: items … 選択された PhotosPickerItem 配列
    /// - 出力: なし（pages / undetectedImages を更新する）
    /// - 処理: バックグラウンドで画像ロード → 各画像に検出を試行する
    private func importItems(_ items: [PhotosPickerItem]) {
        isImporting = true
        Task.detached {
            do {
                let images = try await PageImporter.loadImages(from: items)
                let result = try PageImporter().makePages(from: images)
                await MainActor.run {
                    isImporting = false
                    pendingDetectedPages = result.detectedPages
                    if result.undetectedImages.isEmpty {
                        pages.append(contentsOf: result.detectedPages)
                        pendingDetectedPages = []
                    } else {
                        undetectedImages = result.undetectedImages
                    }
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    self.present(error)
                }
            }
        }
    }

    /// 未検出画像をそのままページ追加する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 検出済み + 未検出を pages へ追加する
    private func acceptUndetected() {
        pages.append(contentsOf: pendingDetectedPages)
        pages.append(contentsOf: undetectedImages.map { ScannedPage(baseImage: $0) })
        undetectedImages = []
        pendingDetectedPages = []
    }

    /// 未検出画像を破棄し検出済みのみ追加する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: pendingDetectedPages のみ pages へ追加する
    private func discardUndetected() {
        pages.append(contentsOf: pendingDetectedPages)
        undetectedImages = []
        pendingDetectedPages = []
    }

    /// PDF を生成してストアへ保存し、プレビューへ遷移する。
    /// - 入力: なし
    /// - 出力: なし（savedDocument を更新して遷移する）
    /// - 処理: バックグラウンドで全ページをレンダリング → PDF 生成 → ストア保存
    private func save() {
        isSaving = true
        let snapshot = pages
        let name = fileName
        let size = pageSize
        Task.detached {
            do {
                let processor = DocumentImageProcessor()
                var images: [UIImage] = []
                for page in snapshot {
                    images.append(try page.renderedImage(using: processor))
                }
                let data = try PDFBuilder().makePDF(from: images, pageSize: size)
                let saved = try await MainActor.run { () -> SavedDocument in
                    try store.save(pdfData: data, name: name)
                }
                await MainActor.run {
                    isSaving = false
                    savedDocument = saved
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    self.present(error)
                }
            }
        }
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

/// ページ一覧の 1 行（縮小サムネイル + ページ番号 + フィルタ名）。
private struct PageRow: View {

    /// 対象ページ。
    let page: ScannedPage
    /// 表示用ページ番号。
    let number: Int
    /// サムネイル画像。
    @State private var thumbnail: UIImage?
    /// サムネイル生成失敗フラグ。
    @State private var failed = false

    /// 行の本体を返す。
    /// - 入力: なし
    /// - 出力: サムネイル + ラベルの HStack
    /// - 処理: バックグラウンドでレンダリングして縮小表示する。失敗時は警告アイコンを表示
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else if failed {
                    Image(systemName: "exclamationmark.triangle")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(width: 44, height: 56)
            VStack(alignment: .leading) {
                Text("Page \(number)").font(.headline)
                Text(page.filter.displayName).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: thumbnailKey) { await loadThumbnail() }
    }

    /// サムネイル再生成トリガーとなるキーを返す。
    /// - 入力: なし
    /// - 出力: ページ id・フィルタ・回転数を結合した文字列
    /// - 処理: 編集状態が変わったら task を再実行させるためのキーを作る
    private var thumbnailKey: String {
        "\(page.id)-\(page.filter.rawValue)-\(page.quarterTurns)"
    }

    /// ページ画像を縮小レンダリングする。
    /// - 入力: なし
    /// - 出力: なし（thumbnail を更新する）
    /// - 処理: フィルタ適用後の画像を 88x112 以内へ縮小する
    private func loadThumbnail() async {
        let snapshot = page
        do {
            let rendered = try await Task.detached {
                try snapshot.renderedImage()
            }.value
            let maxSize = CGSize(width: 88, height: 112)
            let scale = min(maxSize.width / rendered.size.width,
                            maxSize.height / rendered.size.height, 1)
            let target = CGSize(width: rendered.size.width * scale,
                                height: rendered.size.height * scale)
            thumbnail = UIGraphicsImageRenderer(size: target).image { _ in
                rendered.draw(in: CGRect(origin: .zero, size: target))
            }
            failed = false
        } catch {
            // 描画失敗時はスピナーを回し続けず警告アイコンを表示する
            failed = true
        }
    }
}
