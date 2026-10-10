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
    @State private var saveTask: Task<Void, Never>?
    @State private var importTask: Task<Void, Never>?
    @State private var saveProgress = 0
    @State private var saveTotal = 0
    @State private var saveCommitted = false
    @State private var isCommittingSave = false
    @State private var isCancellingSave = false
    @State private var initialPageSignature: String
    @State private var initialFileName: String
    @State private var initialPageSize: String
    @State private var showDiscardConfirmation = false
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
        let defaultName = FileNameSanitizer.defaultName(for: Date())
        _draft = State(initialValue: DocumentDraft(pages: pages))
        _fileName = State(initialValue: defaultName)
        _initialPageSignature = State(initialValue: Self.pageSignature([]))
        _initialFileName = State(initialValue: defaultName)
        _initialPageSize = State(initialValue: PDFPageSize.a4.displayName)
    }

    /// 編集画面の本体を返す。
    /// - 入力: なし
    /// - 出力: ページ一覧 + 名前/用紙設定 + 保存ボタンのビュー
    /// - 処理: List（onMove 対応）でページを表示し、ツールバーに追加・フィルタ一括・保存を置く
    var body: some View {
        List {
            Section {
                ForEach(draft.pages) { page in
                    pageListRow(page)
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
        .disabled(isSaving || isImporting)
        .navigationTitle("New Document")
        .navigationBarBackButtonHidden(true)
        .navigationDestination(item: $editingPageID) { id in
            PageEditView(draft: draft, pageID: id)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Back") { requestBack() }
                    .disabled(isSaving || isImporting)
            }
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
                .disabled(isSaving || isImporting)
                Button { showFilterSheet = true } label: {
                    Label("Filter All", systemImage: "camera.filters")
                }
                .disabled(isSaving || isImporting)
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
            .disabled(draft.pages.isEmpty || isSaving || isImporting)
            .padding(.horizontal)
        }
        .confirmationDialog("Apply Filter to All Pages", isPresented: $showFilterSheet) {
            ForEach(PageFilter.allCases) { filter in
                Button(filter.displayName) { applyFilterToAll(filter) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Discard unsaved document?", isPresented: $showDiscardConfirmation) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your pages and edits will be lost.")
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
                VStack {
                    ProgressView(isSaving ? "Saving PDF…" : "Processing…")
                    if isSaving {
                        Text("Page \(saveProgress) of \(saveTotal)")
                        if isCancellingSave {
                            Text("Canceling… finishing current processing")
                        } else if isCommittingSave {
                            Text("Finishing save…")
                        } else {
                            Button("Cancel") {
                                isCancellingSave = true
                                saveTask?.cancel()
                            }
                            .disabled(isCancellingSave)
                        }
                    }
                }
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .onDisappear {
            if !saveCommitted { saveTask?.cancel() }
            importTask?.cancel()
        }
    }

    private func pageListRow(_ page: ScannedPage) -> some View {
        Button { editingPageID = page.id } label: {
            HStack {
                PageRow(draft: draft, pageID: page.id,
                        number: (draft.pages.firstIndex { $0.id == page.id } ?? 0) + 1,
                        active: !isSaving && !isImporting && editingPageID == nil &&
                            savedDocument == nil && !showCamera && !showPicker)
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
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
        importTask = Task.detached {
            do {
                let sources = try await PageImporter.loadSources(from: items)
                try Task.checkCancellation()
                await MainActor.run { handleSources(sources) }
            } catch is CancellationError {
                await MainActor.run { isImporting = false }
            } catch {
                await MainActor.run {
                    isImporting = false
                    self.present(error)
                }
            }
        }
    }

    /// 写真と固定輪郭付き撮影を処理し、入力順で下書きへ追加する。
    private func handleSources(_ sources: [PageSource]) {
        isImporting = true
        importTask = Task.detached {
            do {
                try Task.checkCancellation()
                let result = try PageImporter().makePages(from: sources)
                try Task.checkCancellation()
                await MainActor.run {
                    isImporting = false
                    importTask = nil
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
                    importTask = nil
                    if !(error is CancellationError) { self.present(error) }
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
        guard !isSaving, !isImporting else { return }
        let name: String
        do {
            name = try FileNameSanitizer.sanitize(fileName)
        } catch {
            present(error)
            return
        }
        isSaving = true
        isCommittingSave = false
        isCancellingSave = false
        saveCommitted = false
        let snapshot = draft.pages
        let size = pageSize
        saveProgress = 0
        saveTotal = snapshot.count
        let output = store.temporaryPDFURL()
        saveTask = Task.detached(priority: .userInitiated) {
            do {
                let processor = DocumentImageProcessor()
                try PDFBuilder.writePDF(pageCount: snapshot.count, to: output,
                                        pageSize: size, imageForPage: { index in
                                            try snapshot[index].renderedImage(using: processor)
                                        }, progress: { completed in
                                            Task { @MainActor in saveProgress = completed }
                                        })
                try Task.checkCancellation()
                let pageCount = try await DocumentStore.validatedPageCount(at: output)
                try Task.checkCancellation()
                let saved = try await MainActor.run {
                    try Task.checkCancellation()
                    isCommittingSave = true
                    return try store.commitValidatedPDF(at: output, name: name, pageCount: pageCount)
                }
                await MainActor.run {
                    isSaving = false
                    saveCommitted = true
                    isCancellingSave = false
                    initialPageSignature = Self.pageSignature(snapshot)
                    initialFileName = fileName
                    initialPageSize = size.displayName
                    saveTask = nil
                    savedDocument = saved
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    isCommittingSave = false
                    isCancellingSave = false
                    saveTask = nil
                    try? FileManager.default.removeItem(at: output)
                    if !(error is CancellationError) { self.present(error) }
                }
            }
        }
    }

    private var hasUnsavedChanges: Bool {
        SavedDraftComparison.needsDiscard(
            currentPageSignature: Self.pageSignature(draft.pages),
            savedPageSignature: initialPageSignature,
            currentFileName: fileName,
            savedFileName: initialFileName,
            currentPageSize: pageSize.displayName,
            savedPageSize: initialPageSize)
    }

    private func requestBack() {
        if hasUnsavedChanges {
            showDiscardConfirmation = true
        } else {
            dismiss()
        }
    }

    private static func pageSignature(_ pages: [ScannedPage]) -> String {
        pages.map { "\($0.id.uuidString):\($0.filter.rawValue):\($0.quarterTurns)" }
            .joined(separator: "|")
    }

    /// エラーをアラート表示する。
    /// - 入力: error … 表示するエラー
    /// - 出力: なし
    /// - 処理: localizedDescription をアラートへ渡す
    private func present(_ error: Error) {
        guard !(error is CancellationError) else { return }
        AppDiagnostics.error("Editor error presentation", error: error)
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
    let active: Bool
    /// サムネイル画像。
    @State private var thumbnail: UIImage?
    @State private var errorMessage: String?

    /// 行の本体を返す。
    /// - 入力: なし
    /// - 出力: サムネイル + ラベルの HStack
    /// - 処理: バックグラウンドでレンダリングして縮小表示する。失敗時は理由を表示
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFit()
                } else if errorMessage != nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Page preview failed: \(errorMessage ?? "")")
                } else {
                    ProgressView()
                }
            }
            .frame(width: 44, height: 56)
            VStack(alignment: .leading) {
                Text("Page \(number)").font(.headline)
                Text(draft.page(id: pageID)?.filter.displayName ?? "-")
                    .font(.caption).foregroundStyle(.secondary)
                if let errorMessage {
                    Text("Preview unavailable: \(errorMessage)")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .accessibilityLabel("Page preview error: \(errorMessage). Open this page to view the full error.")
                }
            }
        }
        .task(id: "\(thumbnailKey)-\(active)") { await loadThumbnail() }
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
        guard active else {
            thumbnail = nil
            errorMessage = nil
            return
        }
        guard let snapshot = draft.page(id: pageID) else { return }
        thumbnail = nil
        errorMessage = nil
        let worker = Task.detached(priority: .background) {
            try Task.checkCancellation()
            return try snapshot.thumbnailImage()
        }
        do {
            let rendered = try await withTaskCancellationHandler(operation: {
                try await worker.value
            }, onCancel: {
                worker.cancel()
            })
            try Task.checkCancellation()
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
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.error("Page thumbnail rendering", error: error)
            errorMessage = error.localizedDescription
        }
    }
}
