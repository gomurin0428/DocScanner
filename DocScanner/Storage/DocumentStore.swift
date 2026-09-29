import Foundation
import PDFKit

/// ドキュメントストアの処理中に発生するエラー。
enum DocumentStoreError: LocalizedError, Equatable {
    /// PDF として読み込めないファイルが存在した。
    case unreadableDocument(String)
    /// ファイル属性（作成日時・サイズ）を取得できなかった。
    case missingFileAttributes(String)

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .unreadableDocument(let fileName):
            return "The file '\(fileName)' could not be read as a PDF document."
        case .missingFileAttributes(let fileName):
            return "File attributes for '\(fileName)' could not be read."
        }
    }
}

/// 保存済み PDF 1 件の情報。
struct SavedDocument: Identifiable, Hashable {
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

    /// Identifiable 準拠用の id。URL をそのまま使う。
    var id: URL { url }
}

/// Documents/Scans 配下の PDF を管理するストア。
@Observable
final class DocumentStore {

    /// 保存先ディレクトリ（テストでは任意の一時ディレクトリを注入可能）。
    let directory: URL

    /// 保存済みドキュメント一覧（新しい順）。
    private(set) var documents: [SavedDocument] = []

    /// ストアを初期化する。
    /// - 入力: directory … 保存先ディレクトリ。nil なら Documents/Scans を使用
    /// - 出力: 初期化済み DocumentStore
    /// - 処理: ディレクトリを作成し、既存ファイルを読み込む
    /// - Throws: ディレクトリ作成・列挙・属性取得・PDF 読込の失敗時に各エラー
    init(directory: URL? = nil) throws {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.directory = docs.appendingPathComponent("Scans", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        try reload()
    }

    /// ディレクトリを走査して documents を再構築する。
    /// - 入力: なし
    /// - 出力: なし（documents を更新する）
    /// - 処理: *.pdf を列挙し、作成日・サイズ・ページ数を取得して新しい順に並べる。
    ///   属性欠損や読み込めない PDF は暗黙スキップせずエラーにする
    /// - Throws: 列挙失敗時 CocoaError、属性欠損時 missingFileAttributes、
    ///   PDF 読込失敗時 unreadableDocument
    func reload() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        documents = try files
            .filter { $0.pathExtension.lowercased() == "pdf" }
            .map { url in
                let values = try url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
                guard let createdAt = values.creationDate, let fileSize = values.fileSize else {
                    throw DocumentStoreError.missingFileAttributes(url.lastPathComponent)
                }
                guard let pageCount = PDFDocument(url: url)?.pageCount else {
                    throw DocumentStoreError.unreadableDocument(url.lastPathComponent)
                }
                return SavedDocument(
                    url: url,
                    createdAt: createdAt,
                    fileSize: Int64(fileSize),
                    pageCount: pageCount
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
        let url = uniqueURL(for: base)
        try pdfData.write(to: url, options: .atomic)
        try reload()
        guard let saved = documents.first(where: { $0.url == url }) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return saved
    }

    /// 保存済みドキュメントを削除する。
    /// - 入力: document … 削除対象
    /// - 出力: なし
    /// - 処理: ファイルを削除して一覧を再読込する
    /// - Throws: 削除失敗時に CocoaError
    func delete(_ document: SavedDocument) throws {
        try FileManager.default.removeItem(at: document.url)
        try reload()
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
        try FileManager.default.moveItem(at: document.url, to: url)
        try reload()
        guard let renamed = documents.first(where: { $0.url == url }) else {
            throw CocoaError(.fileReadUnknown)
        }
        return renamed
    }

    /// 重複しないファイル URL を決定する。
    /// - 入力: base … 拡張子なしのベース名、excluding … 無視する既存 URL（リネーム元）
    /// - 出力: ユニークな "Base.pdf" または "Base (n).pdf" の URL
    /// - 処理: 同名ファイルが存在し続ける限り連番をインクリメントする
    private func uniqueURL(for base: String, excluding: URL? = nil) -> URL {
        var candidate = directory.appendingPathComponent(base).appendingPathExtension("pdf")
        var index = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path), candidate != excluding {
            candidate = directory.appendingPathComponent("\(base) (\(index))").appendingPathExtension("pdf")
            index += 1
        }
        return candidate
    }
}
