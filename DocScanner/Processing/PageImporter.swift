import PhotosUI
import SwiftUI
import UIKit

/// 写真インポート処理中に発生するエラー。
enum PageImporterError: LocalizedError {
    /// PhotosPickerItem からのデータ読み込みに失敗した。
    case loadFailed(Int)
    /// 読み込んだデータを画像としてデコードできなかった。
    case decodeFailed(Int)

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .loadFailed(let index):
            return "Photo at index \(index) could not be loaded."
        case .decodeFailed(let index):
            return "Photo at index \(index) could not be decoded as an image."
        }
    }
}

/// インポート結果。書類検出できたページと、検出できなかった元画像に分けて保持する。
struct ImportResult {
    /// 検出・台形補正済みのページ。
    var detectedPages: [ScannedPage]
    /// 書類が検出できなかった元画像（UI が「Use Full Image / Cancel」を確認する）。
    var undetectedImages: [UIImage]
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
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                throw PageImporterError.loadFailed(index)
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
    /// - 出力: ImportResult（detectedPages / undetectedImages）
    /// - 処理: 各画像を最大辺 3000px へ縮小 → detectAndCorrect を試行。
    ///   noDocumentFound は undetectedImages へ、それ以外のエラーは throw
    /// - Throws: 縮小・検出・補正の失敗時に各エラー
    func makePages(from images: [UIImage]) throws -> ImportResult {
        var result = ImportResult(detectedPages: [], undetectedImages: [])
        for image in images {
            // メモリ削減のため検出前に長辺を抑える
            let downscaled = try processor.downscaled(image)
            do {
                let corrected = try detector.detectAndCorrect(downscaled)
                result.detectedPages.append(ScannedPage(baseImage: corrected))
            } catch let error as DocumentDetectionError where error == .noDocumentFound {
                result.undetectedImages.append(downscaled)
            }
        }
        return result
    }
}
