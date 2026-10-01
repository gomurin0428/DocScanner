import PhotosUI
import SwiftUI
import UIKit

/// 写真取り込みと、撮影時の輪郭が固定されたカメラ画像を区別する。
enum PageSource {
    case photo(UIImage)
    case camera(UIImage, boundary: DocumentBoundary?)

    var image: UIImage {
        switch self {
        case .photo(let image), .camera(let image, _): return image
        }
    }
}

/// 写真インポート処理中に発生するエラー。
enum PageImporterError: LocalizedError {
    /// PhotosPickerItem からのデータ読み込みに失敗した（index と元エラーを保持）。
    case loadFailed(Int, String)
    /// 読み込んだデータを画像としてデコードできなかった。
    case decodeFailed(Int)

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .loadFailed(let index, let message):
            return "Photo at index \(index) could not be loaded: \(message)"
        case .decodeFailed(let index):
            return "Photo at index \(index) could not be decoded as an image."
        }
    }
}

/// 入力順を保った写真インポート結果。
struct ImportResult {
    /// 入力順の検出結果。
    enum Entry {
        /// 検出・補正済みページ。
        case detected(ScannedPage)
        /// 書類が検出できなかった元画像。
        case undetected(UIImage)
    }

    /// 入力と同じ順序の検出結果。
    let entries: [Entry]

    /// 検出・補正済みページを入力順で返す。
    var detectedPages: [ScannedPage] {
        entries.compactMap {
            guard case .detected(let page) = $0 else { return nil }
            return page
        }
    }

    /// 書類を検出できなかった元画像を入力順で返す。
    var undetectedImages: [UIImage] {
        entries.compactMap {
            guard case .undetected(let image) = $0 else { return nil }
            return image
        }
    }

    /// ユーザーの選択に従いページを入力順で再構成する。
    /// - 入力: includingUndetected … 未検出画像もページとして採用するか
    /// - 出力: 入力順に再構成された ScannedPage 配列
    /// - 処理: 検出済みは常に含め、未検出はフル画像採用時のみページ化する
    func pages(includingUndetected: Bool) -> [ScannedPage] {
        entries.compactMap { entry in
            switch entry {
            case .detected(let page):
                return page
            case .undetected(let image):
                return includingUndetected ? ScannedPage(baseImage: image) : nil
            }
        }
    }
}

/// 写真ライブラリからの画像読み込みと書類検出をまとめるインポータ。
struct PageImporter {

    /// 書類検出器。
    private let detector: DocumentDetector
    /// 画像プロセッサ（縮小に使用）。
    private let processor: DocumentImageProcessor

    /// インポータを初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み PageImporter
    /// - 処理: 検出器とプロセッサを生成する
    init() {
        self.detector = DocumentDetector()
        self.processor = DocumentImageProcessor()
    }

    /// PhotosPicker の選択アイテムを全て画像として読み込む。
    /// - 入力: items … 選択された PhotosPickerItem 配列
    /// - 出力: 選択順の UIImage 配列
    /// - 処理: 各アイテムを loadTransferable で Data 化して UIImage にデコードする。
    ///   失敗・デコード不能は暗黙スキップせずエラーにする
    /// - Throws: 読み込み失敗時 loadFailed(index)、デコード失敗時 decodeFailed(index)
    static func loadImages(from items: [PhotosPickerItem]) async throws -> [UIImage] {
        var images: [UIImage] = []
        for (index, item) in items.enumerated() {
            let data: Data
            do {
                guard let loaded = try await item.loadTransferable(type: Data.self) else {
                    throw PageImporterError.loadFailed(index, "no transferable data")
                }
                data = loaded
            } catch let error as PageImporterError {
                throw error
            } catch {
                throw PageImporterError.loadFailed(index, error.localizedDescription)
            }
            guard let image = UIImage(data: data) else {
                throw PageImporterError.decodeFailed(index)
            }
            images.append(image)
        }
        return images
    }

    /// 画像配列を縮小して書類検出を行い、結果を振り分ける。
    /// - 入力: images … 入力画像配列
    /// - 出力: ImportResult（元の入力順を保持する entries）
    /// - 処理: 各画像を最大辺 3000px へ縮小 → detectAndCorrect を試行。
    ///   noDocumentFound は undetected、成功は detected として順序通り記録し、
    ///   それ以外のエラーは throw
    /// - Throws: 縮小・検出・補正の失敗時に各エラー
    func makePages(from images: [UIImage]) throws -> ImportResult {
        try makePages(from: images.map { PageSource.photo($0) })
    }

    /// 入力順を保って補正する。カメラは固定輪郭を使い、枠なし撮影は確認に回す。
    /// - 入力: 写真またはカメラ撮影、出力: 検出済みと未検出を保持した結果
    func makePages(from sources: [PageSource]) throws -> ImportResult {
        var entries: [ImportResult.Entry] = []
        for source in sources {
            // メモリ削減のため検出前に長辺を抑える
            let downscaled = try processor.downscaled(source.image)
            do {
                let corrected: UIImage
                switch source {
                case .photo:
                    corrected = try detector.detectAndCorrect(downscaled)
                case .camera(_, let boundary):
                    guard let boundary else { throw DocumentDetectionError.noDocumentFound }
                    corrected = try detector.correct(downscaled, boundary: boundary)
                }
                entries.append(.detected(ScannedPage(baseImage: corrected)))
            } catch let error as DocumentDetectionError where error == .noDocumentFound {
                entries.append(.undetected(downscaled))
            }
        }
        return ImportResult(entries: entries)
    }
}
