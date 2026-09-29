import UIKit

/// テスト用画像を生成するヘルパー。
enum TestImageFactory {

    /// 単色塗りの画像を生成する。
    /// - 入力: color … 塗り色、size … ピクセルサイズ
    /// - 出力: 単色の UIImage（scale=1）
    /// - 処理: UIGraphicsImageRenderer で全面塗りつぶす
    static func solid(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 左から右への水平グレーグラデーション画像を生成する。
    /// - 入力: size … ピクセルサイズ
    /// - 出力: 左端 0・右端 255 のグレーグラデーション UIImage
    /// - 処理: 縦 1px 幅の帯を明度を変えながら描く
    static func gradient(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let width = Int(size.width)
            for x in 0..<width {
                let value = CGFloat(x) / CGFloat(max(width - 1, 1))
                UIColor(white: value, alpha: 1).setFill()
                ctx.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: size.height))
            }
        }
    }

    /// UIImage の指定位置のピクセル色を返す。
    /// - 入力: image … 対象画像、x / y … ピクセル座標
    /// - 出力: その位置の UIColor。取得失敗時は nil
    /// - 処理: 1x1 にクロップして CGImage を描画し dataProvider の生バイトを読む
    static func pixelColor(of image: UIImage, x: Int, y: Int) -> UIColor? {
        guard let cg = image.cgImage,
              let cropped = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
            return nil
        }
        guard let provider = cropped.dataProvider,
              let data = provider.data else { return nil }
        let bytes = CFDataGetBytePtr(data)!
        let components = cropped.bitsPerPixel / 8
        // アルファの有無で先頭バイトの意味が変わるため両対応する
        let hasAlpha = cropped.alphaInfo != .none &&
                       cropped.alphaInfo != .noneSkipLast &&
                       cropped.alphaInfo != .noneSkipFirst
        if components >= 4 && hasAlpha {
            return UIColor(red: CGFloat(bytes[0]) / 255,
                           green: CGFloat(bytes[1]) / 255,
                           blue: CGFloat(bytes[2]) / 255,
                           alpha: CGFloat(bytes[3]) / 255)
        }
        if components >= 3 {
            return UIColor(red: CGFloat(bytes[0]) / 255,
                           green: CGFloat(bytes[1]) / 255,
                           blue: CGFloat(bytes[2]) / 255,
                           alpha: 1)
        }
        if components == 1 {
            return UIColor(white: CGFloat(bytes[0]) / 255, alpha: 1)
        }
        return nil
    }

    /// UIImage のピクセルサイズを返す。
    /// - 入力: image … 対象画像
    /// - 出力: ピクセル単位の CGSize。cgImage が無い場合は size*scale
    /// - 処理: cgImage の width/height を優先して返す
    static func pixelSize(of image: UIImage) -> CGSize {
        if let cg = image.cgImage {
            return CGSize(width: cg.width, height: cg.height)
        }
        return CGSize(width: image.size.width * image.scale,
                      height: image.size.height * image.scale)
    }
}
