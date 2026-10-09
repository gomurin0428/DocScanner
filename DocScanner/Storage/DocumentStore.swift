import Foundation
import PDFKit

/// ドキュメントストアの処理中に発生するエラー。
enum DocumentStoreError: LocalizedError, Equatable {
    /// PDF として読み込めないファイルが存在した。
    case unreadableDocument(String)
    /// ファイル属性（作成日時・サイズ）を取得できなかった。
    case missingFileAttributes(String)
    /// 保存後に一覧から保存ファイルを特定できなかった。
    case savedDocumentNotFound(String)
    /// リネーム後に一覧からリネーム先ファイルを特定できなかった。
    case renamedDocumentNotFound(String)
    case directoryAccessFailed(String)
    case invalidPDF

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .unreadableDocument(let fileName):
            return "The file '\(fileName)' could not be read as a PDF document."
        case .missingFileAttributes(let fileName):
            return "File attributes for '\(fileName)' could not be read."
        case .savedDocumentNotFound(let fileName):
            return "The saved file '\(fileName)' could not be found in the store."
        case .renamedDocumentNotFound(let fileName):
            return "The renamed file '\(fileName)' could not be found in the store."
        case .directoryAccessFailed(let message):
            return "DocScanner could not access the scan directory: \(message)"
        case .invalidPDF:
            return "The PDF could not be validated before saving."
        }
    }
}

/// 保存済み PDF 1 件の情報。
struct SavedDocument: Identifiable, Hashable, Sendable {
    /// ファイル URL。Identifiable の id としても使用する。
    let url: URL
    /// 拡張子を除いたファイル名。
    var name: String { url.deletingPathExtension().lastPathComponent }
    /// 作成日時。
    let createdAt: Date
    /// ファイルサイズ（バイト）。
    let fileSize: Int64
    /// PDF のページ数。
    let pageCount: Int
    /// 読み込み不能な個別ファイルの理由。nil は通常の保存済み PDF。
    let issue: String?

    /// Identifiable 準拠用の id。URL をそのまま使う。
    var id: URL { url }

    var isReadable: Bool { issue == nil && pageCount > 0 }
}

/// Documents/Scans 配下の PDF を管理するストア。
@Observable
final class DocumentStore {

    /// 保存先ディレクトリ（テストでは任意の一時ディレクトリを注入可能）。
    let directory: URL

    /// 保存済みドキュメント一覧（新しい順）。
    private(set) var documents: [SavedDocument] = []
    private(set) var isLoaded = false
    private var revision = 0
    private var loadGeneration = 0
    private let scanner: @Sendable (URL) async throws -> [SavedDocument]

    /// ストアを初期化する。
    /// - 入力: directory … 保存先ディレクトリ。nil なら Documents/Scans を使用
    /// - 出力: 初期化済み DocumentStore
    /// - 処理: ディレクトリを作成し、既存ファイルを読み込む
    /// - Throws: ディレクトリ作成・列挙・属性取得・PDF 読込の失敗時に各エラー
    init(
        directory: URL? = nil,
        loadExisting: Bool = true,
        scanner: @escaping @Sendable (URL) async throws -> [SavedDocument] = { directory in
            try await Task.detached(priority: .userInitiated) {
                try DocumentStore.readDocuments(in: directory)
            }.value
        }
    ) throws {
        self.scanner = scanner
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.directory = docs.appendingPathComponent("Scans", isDirectory: true)
        }
        if loadExisting {
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            try reload()
        }
    }

    /// ディレクトリを走査して documents を再構築する。
    /// - 入力: なし
    /// - 出力: なし（documents を更新する）
    /// - 処理: *.pdf を列挙し、作成日・サイズ・ページ数を取得して新しい順に並べる。
    ///   属性欠損や読み込めない PDF は個別の issue エントリとして保持する。
    /// - Throws: ディレクトリ列挙自体に失敗した場合
    func reload() throws {
        let snapshot = try Self.readDocuments(in: directory)
        loadGeneration &+= 1
        documents = snapshot
        isLoaded = true
    }

    @MainActor
    func reloadAsync() async throws {
        loadGeneration &+= 1
        let generation = loadGeneration
        let startingRevision = revision
        let scanDirectory = directory
        let scan = scanner
        let snapshot = try await Task.detached(priority: .userInitiated) {
            try await scan(scanDirectory)
        }.value
        guard generation == loadGeneration, startingRevision == revision else { return }
        documents = snapshot
        isLoaded = true
    }

    private func invalidateReloads() {
        revision &+= 1
        loadGeneration &+= 1
    }

    private static func readDocuments(in directory: URL) throws -> [SavedDocument] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: []
            )
        } catch {
            AppDiagnostics.error("Scan directory enumeration", error: error)
            throw DocumentStoreError.directoryAccessFailed(error.localizedDescription)
        }
        return files
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map { url in
                let values: URLResourceValues
                do {
                    values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                } catch {
                    let issue = DocumentStoreError.missingFileAttributes(url.lastPathComponent)
                    AppDiagnostics.error("Scan document attributes", error: error)
                    return SavedDocument(url: url, createdAt: Date.distantPast, fileSize: 0,
                                         pageCount: 0, issue: issue.localizedDescription)
                }
                guard let createdAt = values.creationDate, let fileSize = values.fileSize else {
                    let issue = DocumentStoreError.missingFileAttributes(url.lastPathComponent)
                    AppDiagnostics.error("Scan document attributes", error: issue)
                    return SavedDocument(url: url, createdAt: Date.distantPast, fileSize: 0,
                                         pageCount: 0, issue: issue.localizedDescription)
                }
                guard let pdf = PDFDocument(url: url), !pdf.isLocked, pdf.pageCount > 0 else {
                    let issue = DocumentStoreError.unreadableDocument(url.lastPathComponent)
                    AppDiagnostics.error("Scan document parsing", error: issue)
                    return SavedDocument(url: url, createdAt: createdAt, fileSize: Int64(fileSize),
                                         pageCount: 0, issue: issue.localizedDescription)
                }
                return SavedDocument(
                    url: url,
                    createdAt: createdAt,
                    fileSize: Int64(fileSize),
                    pageCount: pdf.pageCount,
                    issue: nil
                )
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    /// PDF データをユニーク名で保存する。
    /// - 入力: pdfData … 保存する PDF データ、name … 拡張子なしのファイル名
    /// - 出力: 保存された SavedDocument
    /// - 処理: 同名があれば "Name (2)" のように連番を付けて書き込み、一覧を再読込する
    /// - Throws: ファイル名不正時 FileNameError、書き込み失敗時 CocoaError
    @discardableResult
    func save(pdfData: Data, name rawName: String) throws -> SavedDocument {
        let base = try FileNameSanitizer.sanitize(rawName)
        guard let pdf = PDFDocument(data: pdfData), !pdf.isLocked, pdf.pageCount > 0 else {
            throw DocumentStoreError.invalidPDF
        }
        let url = uniqueURL(for: base)
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).pdf")
        do {
            try pdfData.write(to: temporary, options: .atomic)
            guard PDFDocument(url: temporary)?.pageCount == pdf.pageCount else {
                throw DocumentStoreError.invalidPDF
            }
            try FileManager.default.moveItem(at: temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        do {
            let saved = try metadata(for: url, pageCount: pdf.pageCount)
            invalidateReloads()
            documents.append(saved)
            documents.sort { $0.createdAt > $1.createdAt }
            return saved
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    @discardableResult
    func save(pdfURL source: URL, name rawName: String) throws -> SavedDocument {
        let pageCount = try Self.validatedPageCount(at: source)
        return try commitValidatedPDF(at: source, name: rawName, pageCount: pageCount)
    }

    static func validatedPageCount(at source: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            try Self.validatedPageCount(at: source)
        }.value
    }

    func temporaryPDFURL() -> URL {
        directory.appendingPathComponent(".pending-\(UUID().uuidString).pdf")
    }

    @discardableResult
    func commitValidatedPDF(at source: URL, name rawName: String, pageCount: Int) throws -> SavedDocument {
        let base = try FileNameSanitizer.sanitize(rawName)
        guard pageCount > 0 else {
            throw DocumentStoreError.invalidPDF
        }
        let url = uniqueURL(for: base)
        try FileManager.default.moveItem(at: source, to: url)
        do {
            let saved = try metadata(for: url, pageCount: pageCount)
            invalidateReloads()
            documents.append(saved)
            documents.sort { $0.createdAt > $1.createdAt }
            return saved
        } catch {
            try? FileManager.default.moveItem(at: url, to: source)
            throw error
        }
    }

    private static func validatedPageCount(at source: URL) throws -> Int {
        guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else {
            throw DocumentStoreError.invalidPDF
        }
        return pdf.pageCount
    }

    /// 保存済みドキュメントを削除する。
    /// - 入力: document … 削除対象
    /// - 出力: なし
    /// - 処理: ファイルを削除して一覧を再読込する
    /// - Throws: 削除失敗時に CocoaError
    func delete(_ document: SavedDocument) throws {
        try FileManager.default.removeItem(at: document.url)
        invalidateReloads()
        documents.removeAll { $0.url.lastPathComponent == document.url.lastPathComponent }
    }

    /// 一覧の選択オフセットに対応するドキュメントを削除する。
    /// - 入力: offsets … 削除対象の一覧インデックス
    /// - 出力: なし
    /// - 処理: reload で一覧が変わる前に対象を確定し、既存の単件削除へ委譲する
    /// - Throws: 削除失敗時に CocoaError
    func delete(at offsets: IndexSet) throws {
        let targets = offsets.map { documents[$0] }
        if !targets.isEmpty { invalidateReloads() }
        for document in targets {
            try FileManager.default.removeItem(at: document.url)
        }
        let names = Set(targets.map { $0.url.lastPathComponent })
        documents.removeAll { names.contains($0.url.lastPathComponent) }
    }

    /// 保存済みドキュメントの名前を変更する。
    /// - 入力: document … 対象、newName … 拡張子なしの新しい名前
    /// - 出力: リネーム後の SavedDocument
    /// - 処理: サニタイズしてユニーク名へ moveItem し、一覧を再読込する
    /// - Throws: ファイル名不正時 FileNameError、移動失敗時 CocoaError
    @discardableResult
    func rename(_ document: SavedDocument, to newName: String) throws -> SavedDocument {
        let base = try FileNameSanitizer.sanitize(newName)
        let url = uniqueURL(for: base, excluding: document.url)
        if url.lastPathComponent == document.url.lastPathComponent {
            return document
        }
        try FileManager.default.moveItem(at: document.url, to: url)
        invalidateReloads()
        let renamed = SavedDocument(url: url, createdAt: document.createdAt,
                                    fileSize: document.fileSize, pageCount: document.pageCount,
                                    issue: document.issue)
        documents.removeAll { $0.url.lastPathComponent == document.url.lastPathComponent }
        documents.append(renamed)
        documents.sort { $0.createdAt > $1.createdAt }
        return renamed
    }

    private func metadata(for url: URL, pageCount: Int) throws -> SavedDocument {
        let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
        guard let createdAt = values.creationDate, let fileSize = values.fileSize else {
            throw DocumentStoreError.missingFileAttributes(url.lastPathComponent)
        }
        return SavedDocument(url: url, createdAt: createdAt, fileSize: Int64(fileSize),
                             pageCount: pageCount, issue: nil)
    }

    /// 重複しないファイル URL を決定する。
    /// - 入力: base … 拡張子なしのベース名、excluding … 無視する既存 URL（リネーム元）
    /// - 出力: ユニークな "Base.pdf" または "Base (n).pdf" の URL
    /// - 処理: 同名ファイルが存在し続ける限り連番をインクリメントする
    private func uniqueURL(for base: String, excluding: URL? = nil) -> URL {
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("pdf")
        var index = 2
        let fm = FileManager.default
        // リネーム元と列挙結果で symlink 解決有無が異なり得るためファイル名で比較する
        while fm.fileExists(atPath: candidate.path),
              candidate.lastPathComponent != excluding?.lastPathComponent {
            candidate = directory.appendingPathComponent("\(base) (\(index))").appendingPathExtension("pdf")
            index += 1
        }
        return candidate
    }
}
