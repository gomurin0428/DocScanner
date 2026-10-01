import AVFoundation
import PhotosUI
import SwiftUI

/// 新規スキャンドキュメントのページ編集ビュー（サムネイル一覧・並べ替え・保存）。
struct EditorView: View {

    /// 共有のドキュメントストア。
    @Environment(DocumentStore.self) private var store
    /// 画面を閉じるための dismiss アクション。
    @Environment(\.dismiss) private var dismiss

    /// 編集中のページ一覧を保持する下書きモデル。
    /// （値型の配列を直接 @State にすると、子ビューが PageEditView の再生成で
    ///   状態を失うため @Observable の参照型で共有する）
    @State private var draft: DocumentDraft
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
    /// 追加取り込みのアラート回答待ち結果（入力順）。
    @State private var pendingImportResult: ImportResult?
    /// 未検出画像の確認アラート表示状態。
    @State private var showUndetectedAlert = false
    /// ページ詳細遷移先のページ id（item ベース遷移用）。
    /// （item ベースの navigationDestination と値ベース NavigationLink を
    ///   同一スタックで混在させると遷移が壊れるため全て item ベースで統一する）
    @State private var editingPageID: UUID?

    /// エディタを初期化する。
    /// - 入力: pages … 初期ページ配列
    /// - 出力: 初期化済み EditorView
    /// - 処理: ページを保持し、ファイル名に日時ベースの既定名を設定する
    init(pages: [ScannedPage]) {
        _draft = State(initialValue: DocumentDraft(pages: pages))
        _fileName = State(initialValue: FileNameSanitizer.defaultName(for: Date()))
    }

    /// 編集画面の本体を返す。
    /// - 入力: なし
    /// - 出力: ページ一覧 + 名前/用紙設定 + 保存ボタンのビュー
    /// - 処理: List（onMove 対応）でページを表示し、ツールバーに追加・フィルタ一括・保存を置く
    var body: some View {
        List {
            Section {
                ForEach(draft.pages) { page in
                    // item ベース遷移: editingPageID をセットして navigationDestination(item:) で遷移する
                    Button { editingPageID = page.id } label: {
                        HStack {
                            PageRow(draft: draft, pageID: page.id,
                                    number: (draft.pages.firstIndex { $0.id == page.id } ?? 0) + 1)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                }
                .onMove { source, destination in
                    draft.move(fromOffsets: source, toOffset: destination)
                }
                .onDelete { offsets in
                    offsets.map { draft.pages[$0].id }.forEach { draft.remove(id: $0) }
                }
            } header: {
                Text("Pages (\(draft.pages.count))")
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
        .navigationDestination(item: $editingPageID) { id in
            PageEditView(draft: draft, pageID: id)
        }
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
            .disabled(draft.pages.isEmpty || isSaving)
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
        .alert("No document edges were detected.", isPresented: $showUndetectedAlert) {
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

    /// カメラ対応可否を確認してシートを開く。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 非対応ならエラーアラートを出す
    private func showCameraOrAlert() {
        guard CameraController.isAvailable() else {
            errorMessage = "The camera is not available on this device."
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
        draft.applyFilterToAll(filter)
    }

    /// PhotosPicker の選択アイテムを読み込み検出処理を行う。
    /// - 入力: items … 選択された PhotosPickerItem 配列
    /// - 出力: なし（draft または pendingImportResult を更新する）
    /// - 処理: バックグラウンドで画像ロード → 各画像に検出を試行する
    private func importItems(_ items: [PhotosPickerItem]) {
        isImporting = true
        Task.detached {
            do {
                let images = try await PageImporter.loadImages(from: items)
                await MainActor.run { handleImages(images) }
            } catch {
                await MainActor.run {
                    isImporting = false
                    self.present(error)
                }
            }
        }
    }

    /// UIImage 配列を書類検出パイプラインへ通し結果を反映する（カメラ・写真共通）。
    /// - 入力: images … 取り込み済み画像配列
    /// - 出力: なし（draft または pendingImportResult を更新する）
    /// - 処理: バックグラウンドで makePages を実行し、検出済みは draft へ追加、
    ///   未検出は確認アラート用に保持する
    private func handleImages(_ images: [UIImage]) {
        handleSources(images.map { .photo($0) })
    }

    /// 写真と固定輪郭付き撮影を処理し、入力順で下書きへ追加する。
    private func handleSources(_ sources: [PageSource]) {
        isImporting = true
        Task.detached {
            do {
                let result = try PageImporter().makePages(from: sources)
                await MainActor.run {
                    isImporting = false
                    if result.undetectedImages.isEmpty {
                        draft.append(result.pages(includingUndetected: false))
                    } else {
                        pendingImportResult = result
                        showUndetectedAlert = true
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
        draft.append(pendingImportResult?.pages(includingUndetected: true) ?? [])
        pendingImportResult = nil
    }

    /// 未検出画像を破棄し検出済みのみ追加する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: pendingImportResult から検出済みページのみを再構成して追加する
    private func discardUndetected() {
        draft.append(pendingImportResult?.pages(includingUndetected: false) ?? [])
        pendingImportResult = nil
    }

    /// PDF を生成してストアへ保存し、プレビューへ遷移する。
    /// - 入力: なし
    /// - 出力: なし（savedDocument を更新して遷移する）
    /// - 処理: バックグラウンドで全ページをレンダリング → PDF 生成 → ストア保存
    private func save() {
        isSaving = true
        let snapshot = draft.pages
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

    /// 共有の下書きモデル（Filter All 等の変更が Observation 経由で反映されるように参照型で受け取る）。
    let draft: DocumentDraft
    /// 対象ページの識別子。
    let pageID: UUID
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
                Text(draft.page(id: pageID)?.filter.displayName ?? "-")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: thumbnailKey) { await loadThumbnail() }
    }

    /// サムネイル再生成トリガーとなるキーを返す。
    /// - 入力: なし
    /// - 出力: ページ id・フィルタ・回転数を結合した文字列
    /// - 処理: 編集状態が変わったら task を再実行させるためのキーを作る
    private var thumbnailKey: String {
        guard let page = draft.page(id: pageID) else { return "deleted-\(pageID)" }
        return "\(page.id)-\(page.filter.rawValue)-\(page.quarterTurns)"
    }

    /// ページ画像を縮小レンダリングする。
    /// - 入力: なし
    /// - 出力: なし（thumbnail を更新する）
    /// - 処理: フィルタ適用後の画像を 88x112 以内へ縮小する
    private func loadThumbnail() async {
        let key = thumbnailKey
        guard let snapshot = draft.page(id: pageID) else { return }
        do {
            let rendered = try await Task.detached {
                try snapshot.renderedImage()
            }.value
            // レンダリング中に編集が進んでいたら古い結果を捨てる
            guard thumbnailKey == key else { return }
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
