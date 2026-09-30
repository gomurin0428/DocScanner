import PDFKit
import UIKit

/// PDF 生成中に発生するエラー。
enum PDFBuilderError: LocalizedError {
    /// ページとなる画像が 0 件だった。
    case noPages
    /// 画像の JPEG 再エンコードに失敗した。
    case jpegEncodingFailed

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .noPages:
            return "There are no pages to export."
        case .jpegEncodingFailed:
            return "A page image could not be encoded as JPEG."
        }
    }
}

/// ページ画像群から PDF を生成するビルダー。
struct PDFBuilder {

    /// 用紙マージン（pt）。
    private let pageMargin: CGFloat = 18

    /// ビルダーを初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み PDFBuilder
    /// - 処理: 定数のみのため何もしない
    init() {}

    /// 画像配列から PDF データを生成する。
    /// - 入力: images … ページ順の画像配列、pageSize … 用紙サイズ、jpegQuality … JPEG 圧縮率（既定 0.8）
    /// - 出力: 生成された PDF の Data
    /// - 処理: UIGraphicsPDFRenderer で 1 画像 1 ページを描画する。
    ///   A4/Letter はマージン内に aspect-fit で中央配置、fitImage は画像サイズをそのままページにする。
    ///   ファイルサイズ削減のため各画像は JPEG へ再エンコードしてから描画する。
    /// - Throws: images が空なら PDFBuilderError.noPages
    func makePDF(from images: [UIImage], pageSize: PDFPageSize, jpegQuality: CGFloat = 0.8) throws -> Data {
        guard !images.isEmpty else {
            throw PDFBuilderError.noPages
        }

        // iOS 26 では一部サイズで beginPage(withBounds:) のページ境界が mediaBox に
        // 反映されずレンダラ初期値が残るため、先頭ページの実サイズで初期化する
        // pdfData クロージャは throw できないため、JPEG 再エンコードを先に済ませる。
        // エンコード・デコードに失敗した場合は元画像を描くのではなくエラーにする
        var encoded: [UIImage] = []
        for image in images {
            guard let jpeg = image.jpegData(compressionQuality: jpegQuality),
                  let jpegImage = UIImage(data: jpeg) else {
                throw PDFBuilderError.jpegEncodingFailed
            }
            encoded.append(jpegImage)
        }

        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds(for: encoded[0], pageSize: pageSize))
        let data = renderer.pdfData { context in
            for image in encoded {
                let bounds = pageBounds(for: image, pageSize: pageSize)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                // JPEG 再エンコードにより PDF 内の画像サイズを抑える
                image.draw(in: contentRect(for: image, in: bounds, pageSize: pageSize))
            }
        }
        return data
    }

    /// ページ境界を計算する。
    /// - 入力: image … ページ画像、pageSize … 用紙サイズ指定
    /// - 出力: ページの CGRect（原点 0）
    /// - 処理: 固定サイズはそのまま、fitImage は画像の pt サイズをページサイズにする
    private func pageBounds(for image: UIImage, pageSize: PDFPageSize) -> CGRect {
        if let fixed = pageSize.fixedSize {
            return CGRect(origin: .zero, size: fixed)
        }
        return CGRect(origin: .zero, size: image.size)
    }

    /// ページ内の画像描画領域を計算する。
    /// - 入力: image … ページ画像、bounds … ページ境界
    /// - 出力: 画像を描画する CGRect
    /// - 処理: fitImage のみ全領域、それ以外はマージン内へ aspect-fit で中央配置
    private func contentRect(for image: UIImage, in bounds: CGRect, pageSize: PDFPageSize) -> CGRect {
        if pageSize == .fitImage {
            return bounds
        }
        let available = bounds.insetBy(dx: pageMargin, dy: pageMargin)
        let scale = min(available.width / image.size.width, available.height / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(
            x: available.minX + (available.width - drawSize.width) / 2,
            y: available.minY + (available.height - drawSize.height) / 2
        )
        return CGRect(origin: origin, size: drawSize)
    }
}
