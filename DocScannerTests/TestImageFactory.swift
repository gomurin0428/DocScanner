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

    /// 上下を区別できるマーカー付きの歪んだ書類画像を生成する。
    /// - 入力: なし
    /// - 出力: 暗背景 + 明るい歪んだ四角形（紙）で、紙の左上角付近に黒いマーカーブロックを持つ UIImage
    /// - 処理: 四角形をバイリニア補間のパラメータ (u,v) で扱い、
    ///   u,v ∈ 0.08〜0.20 の領域を黒で塗る（マーカーは上辺側のみ。上下反転検出用）
    static func markedSkewedDocument() -> UIImage {
        let size = CGSize(width: 1200, height: 1600)
        // 書類の四角形（UIKit 座標: 左上→右上→右下→左下、約 620x840）
        let quad: [CGPoint] = [
            CGPoint(x: 300, y: 400),
            CGPoint(x: 940, y: 370),
            CGPoint(x: 900, y: 1250),
            CGPoint(x: 260, y: 1210)
        ]
        /// 四角形内の (u,v) 位置をバイリニア補間で実座標へ変換する。
        func point(u: CGFloat, v: CGFloat) -> CGPoint {
            CGPoint(
                x: quad[0].x * (1 - u) * (1 - v) + quad[1].x * u * (1 - v)
                 + quad[3].x * (1 - u) * v + quad[2].x * u * v,
                y: quad[0].y * (1 - u) * (1 - v) + quad[1].y * u * (1 - v)
                 + quad[3].y * (1 - u) * v + quad[2].y * u * v
            )
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.15, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let path = UIBezierPath()
            path.move(to: quad[0])
            for point in quad.dropFirst() { path.addLine(to: point) }
            path.close()
            UIColor.white.setFill()
            path.fill()
            // 紙の左上角付近だけに黒マーカー（上下・左右の反転を検出する印）
            let marker = UIBezierPath()
            marker.move(to: point(u: 0.08, v: 0.08))
            marker.addLine(to: point(u: 0.20, v: 0.08))
            marker.addLine(to: point(u: 0.20, v: 0.20))
            marker.addLine(to: point(u: 0.08, v: 0.20))
            marker.close()
            UIColor.black.setFill()
            marker.fill()
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
