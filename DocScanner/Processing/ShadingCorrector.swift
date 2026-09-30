import CoreImage

/// 書類画像の照明ムラ（陰影）を除去して平坦化するユーティリティ。
/// 背景（紙の明るさ）を推定し、除算ブレンドで平坦化してからレベル補正を行う。
enum ShadingCorrector {

    /// 背景（紙の明るさ）を推定した画像を返す。
    /// - 入力: image … 入力 CIImage
    /// - 出力: 入力と同じ extent の背景推定画像
    /// - 処理: 長辺 512px へ縮小 → CIMorphologyMaximum(radius 6) で文字を消す →
    ///   CIGaussianBlur(radius 12) でぼかす → 元サイズへ戻してクロップする
    /// - Throws: いずれかのフィルタが出力を返さない場合 ImageProcessingError.filterFailed
    static func background(of image: CIImage) throws -> CIImage {
        let extent = image.extent
        let scale = 512 / max(extent.width, extent.height)
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let small = image.clampedToExtent()
            .transformed(by: transform)
            .cropped(to: extent.applying(transform))

        guard let maxed = CIFilter(name: "CIMorphologyMaximum", parameters: [
            kCIInputImageKey: small,
            kCIInputRadiusKey: 6
        ])?.outputImage else {
            throw ImageProcessingError.filterFailed("CIMorphologyMaximum")
        }
        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: maxed.clampedToExtent(),
            kCIInputRadiusKey: 12
        ])?.outputImage else {
            throw ImageProcessingError.filterFailed("CIGaussianBlur")
        }
        let bgSmall = blurred.cropped(to: small.extent)
        return bgSmall.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
            .cropped(to: extent)
    }

    /// 背景推定で除算し、照明ムラを除去した平坦画像を返す。
    /// - 入力: image … 入力 CIImage
    /// - 出力: 入力と同じ extent の平坦化画像（= image / background）
    /// - 処理: CIDivideBlendMode(inputImage: background, backgroundImage: image) を適用してクロップする
    /// - Throws: 背景推定または除算フィルタの失敗時に各エラー
    static func flattened(_ image: CIImage) throws -> CIImage {
        let bg = try background(of: image)
        guard let divided = CIFilter(name: "CIDivideBlendMode", parameters: [
            kCIInputImageKey: bg,
            kCIInputBackgroundImageKey: image
        ])?.outputImage else {
            throw ImageProcessingError.filterFailed("CIDivideBlendMode")
        }
        return divided.cropped(to: image.extent)
    }

    /// グレースケール（彩度 0）に変換する。
    /// - 入力: image … 入力 CIImage
    /// - 出力: 彩度 0 の CIImage
    /// - 処理: CIColorControls を saturation 0 で適用する
    /// - Throws: フィルタ失敗時 ImageProcessingError.filterFailed
    static func grayscale(_ image: CIImage) throws -> CIImage {
        guard let output = CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: image,
            kCIInputSaturationKey: 0.0
        ])?.outputImage else {
            throw ImageProcessingError.filterFailed("CIColorControls")
        }
        return output
    }

    /// 線形ランプ（clamp((x-lo)/(hi-lo))）を各チャンネルへ適用する。
    /// - 入力: image … 入力 CIImage、lo … 0 側の入力値、hi … 1 側の入力値
    /// - 出力: ランプ適用済みの CIImage
    /// - 処理: CIColorMatrix（スケール k=1/(hi-lo)、バイアス -lo*k）→ CIColorClamp を適用する
    /// - Throws: いずれかのフィルタが出力を返さない場合 ImageProcessingError.filterFailed
    static func ramp(_ image: CIImage, lo: Float, hi: Float) throws -> CIImage {
        let k = CGFloat(1 / (hi - lo))
        let bias = CGFloat(-lo) * k
        guard let matrix = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: image,
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
        ])?.outputImage else {
            throw ImageProcessingError.filterFailed("CIColorMatrix")
        }
        guard let clamped = CIFilter(name: "CIColorClamp", parameters: [
            kCIInputImageKey: matrix
        ])?.outputImage else {
            throw ImageProcessingError.filterFailed("CIColorClamp")
        }
        return clamped
    }

    /// レベル補正（黒点・白点・ガンマ）を適用する。
    /// - 入力: image … 入力 CIImage、black … 黒点、white … 白点、gamma … ガンマ値
    /// - 出力: レベル補正済みの CIImage
    /// - 処理: ramp(black, white) → CIGammaAdjust(power gamma) を順に適用する
    /// - Throws: いずれかのフィルタが出力を返さない場合 ImageProcessingError.filterFailed
    static func levels(_ image: CIImage, black: Float, white: Float, gamma: Float) throws -> CIImage {
        let ramped = try ramp(image, lo: black, hi: white)
        guard let gammaed = CIFilter(name: "CIGammaAdjust", parameters: [
            kCIInputImageKey: ramped,
            "inputPower": gamma
        ])?.outputImage else {
            throw ImageProcessingError.filterFailed("CIGammaAdjust")
        }
        return gammaed
    }
}
