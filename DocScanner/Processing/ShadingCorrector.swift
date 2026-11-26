import CoreImage

/// 書類画像の照明ムラ（陰影）を除去して平坦化するユーティリティ。
/// 背景（紙の明るさ）を推定し、上限付きの共通 RGB ゲインで平坦化する。
enum ShadingCorrector {
    private static let chromaticDifferenceKernel = CIColorKernel(source: """
    kernel vec4 chromaticDifference(__sample source, __sample background) {
        vec3 delta = source.rgb - background.rgb;
        float lumaDelta = dot(delta, vec3(0.299, 0.587, 0.114));
        float chromaticDifference = max(abs(delta.r - delta.g),
                                        max(abs(delta.g - delta.b), abs(delta.b - delta.r)));
        float brightTransition = clamp((lumaDelta - 0.02) / 0.08, 0.0, 1.0);
        float sourceMaximum = max(source.r, max(source.g, source.b));
        float sourceMinimum = min(source.r, min(source.g, source.b));
        float sourceSaturation = (sourceMaximum - sourceMinimum) / max(sourceMaximum, 0.0001);
        float neutralTransition = clamp((sourceSaturation - 0.08) / 0.32, 0.0, 1.0);
        float neutralInk = 1.0 - neutralTransition * neutralTransition * (3.0 - 2.0 * neutralTransition);
        float darkInk = 1.0 - brightTransition * neutralInk;
        float difference = chromaticDifference * darkInk;
        return vec4(difference, difference, difference, 1.0);
    }
    """)

    private static let correctionKernel = CIColorKernel(source: """
    kernel vec4 shadingCorrection(__sample source, __sample illumination) {
        float alpha = source.a;
        vec3 color = source.rgb / max(alpha, 0.00001);
        float light = dot(illumination.rgb, vec3(0.2126, 0.7152, 0.0722));
        float sourceLight = dot(color, vec3(0.2126, 0.7152, 0.0722));
        float maximum = max(color.r, max(color.g, color.b));
        float gain = min(2.4, 1.0 / max(light, 0.01));
        float transition = clamp((sourceLight - 0.08) / 0.12, 0.0, 1.0);
        float protection = transition * transition * (3.0 - 2.0 * transition);
        gain = 1.0 + (gain - 1.0) * protection;
        float correctedMaximum = maximum * gain;
        float scale = 1.0;
        if (gain > 1.0 && correctedMaximum > 0.9) {
            float gainIncrease = maximum * (gain - 1.0);
            float beforeKnee = min(gainIncrease, max(0.0, 0.9 - maximum));
            float aboveKnee = max(0.0, gainIncrease - beforeKnee);
            float headroom = max(0.0, 1.0 - maximum - beforeKnee);
            float mappedMaximum = maximum + beforeKnee + headroom *
                (1.0 - exp(-aboveKnee / max(headroom, 0.00001)));
            scale = mappedMaximum / correctedMaximum;
        }
        return vec4(source.rgb * gain * scale, alpha);
    }
    """)

    /// 背景（紙の明るさ）を推定した画像を返す。
    /// - 入力: image … 入力 CIImage
    /// - 出力: 入力と同じ extent の背景推定画像
    /// - 処理: 長辺 512px 以下へ縮小 → CIMorphologyMaximum(radius 6) で文字を消す →
    ///   CIGaussianBlur(radius 12) でぼかす → 元サイズへ戻してクロップする
    /// - Throws: いずれかのフィルタが出力を返さない場合 ImageProcessingError.filterFailed
    static func background(of image: CIImage) throws -> CIImage {
        let extent = image.extent
        let scale = min(1, 512 / max(extent.width, extent.height))
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

    /// 背景の輝度から上限付きの共通 RGB ゲインを求め、照明ムラを平坦化する。
    /// - 入力: image … 入力 CIImage
    /// - 出力: 入力と同じ extent の平坦化画像
    /// - 処理: 輝度の背景マップから共通 RGB ゲインを求め、ハイライト圧縮で白飛びと色ずれを抑える
    /// - Throws: 背景推定または補正カーネルの失敗時に各エラー
    static func flattened(_ image: CIImage) throws -> CIImage {
        let illumination = try background(of: grayscale(image))
        return try applyingCorrection(to: image, using: illumination)
    }

    static func applyingCorrection(to image: CIImage, using illumination: CIImage) throws -> CIImage {
        guard let correctionKernel,
              let corrected = correctionKernel.apply(extent: image.extent,
                                                       arguments: [image, illumination]) else {
            throw ImageProcessingError.filterFailed("ShadingCorrection")
        }
        return corrected.cropped(to: image.extent)
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

    static func chromaticDifference(_ image: CIImage, from background: CIImage) throws -> CIImage {
        guard let chromaticDifferenceKernel,
              let output = chromaticDifferenceKernel.apply(extent: image.extent, arguments: [image, background]) else {
            throw ImageProcessingError.filterFailed("ChromaticDifference")
        }
        return output.cropped(to: image.extent)
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
