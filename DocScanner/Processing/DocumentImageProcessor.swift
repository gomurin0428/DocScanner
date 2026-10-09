import CoreImage
import UIKit

/// 画像処理中に発生するエラー。
enum ImageProcessingError: LocalizedError {
    /// UIImage から有効な CGImage/CIImage を取得できなかった。
    case invalidImage
    /// Core Image フィルタが出力画像を返さなかった。
    case filterFailed(String)
    /// CIContext が CGImage へのレンダリングに失敗した。
    case renderFailed

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return "The image could not be read."
        case .filterFailed(let name):
            return "The Core Image filter '\(name)' failed to produce an output image."
        case .renderFailed:
            return "The processed image could not be rendered."
        }
    }
}

/// Core Image を使ったページ画像のフィルタ適用・回転処理を行うプロセッサ。
struct DocumentImageProcessor {

    /// CI レンダリング用の共有コンテキスト。
    /// 陰影除去・レベル補正・閾値の定数はガンマエンコード済み sRGB で調整済みのため
    /// workingColorSpace を sRGB に固定する（デフォルトのリニア光だと除算・
    /// 閾値処理の定数がずれ、2値化にノイズ斑点が出る）。
    /// CGColorSpace.sRGB 生成は失敗しない定義名のため force unwrap する。
    private let context = ImageRendering.context

    private let enhancer: DocResEnhancer

    init(enhancer: DocResEnhancer = .shared) { self.enhancer = enhancer }

    /// 指定フィルタを画像へ適用する。
    /// - 入力: filter … 適用する PageFilter、image … 入力画像（向きは内部で正規化する）
    /// - 出力: フィルタ適用後の UIImage。ピクセルサイズは入力と同一
    /// - 処理: 向き正規化 → CIImage 化 → フィルタ適用 → CGImage レンダリング
    func apply(_ filter: PageFilter, to image: UIImage) throws -> UIImage {
        try Task.checkCancellation()
        let normalized = try normalizedCGImage(of: image)
        var ci = CIImage(cgImage: normalized)
        let learned: CGImage?
        if filter == .original {
            learned = nil
        } else {
            do {
                learned = try enhancer.flattened(normalized)
            } catch let error as CancellationError {
                throw error
            } catch {
                AppDiagnostics.error("DocRes enhancement", error: error)
                throw error
            }
            try Task.checkCancellation()
        }

        switch filter {
        case .original:
            break
        case .enhanced:
            // 陰影除去で平坦化 → レベル補正 → 彩度 +15% → 輝度シャープ化
            let flat = try learned.map { CIImage(cgImage: $0) } ?? ShadingCorrector.flattened(ci)
            var output = try ShadingCorrector.levels(flat, black: 0.12, white: 0.92, gamma: 1.3)
            guard let saturated = CIFilter(name: "CIColorControls", parameters: [
                kCIInputImageKey: output,
                kCIInputSaturationKey: 1.15
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CIColorControls")
            }
            output = saturated
            guard let sharpened = CIFilter(name: "CISharpenLuminance", parameters: [
                kCIInputImageKey: output,
                kCIInputSharpnessKey: 0.5,
                kCIInputRadiusKey: 1.5
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CISharpenLuminance")
            }
            ci = sharpened
        case .grayscale:
            // 陰影除去で平坦化 → グレースケール → レベル補正
            let flat = try learned.map { CIImage(cgImage: $0) } ?? ShadingCorrector.flattened(ci)
            let gray = try ShadingCorrector.grayscale(flat)
            ci = try ShadingCorrector.levels(gray, black: 0.1, white: 0.92, gamma: 1.2)
        case .blackAndWhite:
            // 陰影除去で平坦化 → グレースケール → 適応閾値（局所比）と
            // グローバルランプの min 合成でアンチエイリアス付き 2 値化。
            // ハードなグローバル閾値だと細線・薄い線が消えるため、
            // g/local 比で文字を拾い、大きな黒領域のくり抜きはグローバル側で防ぐ
            let flat = try learned.map { CIImage(cgImage: $0) } ?? ShadingCorrector.flattened(ci)
            let gray = try ShadingCorrector.grayscale(flat)
            let extent = ci.extent
            let radius = 0.008 * max(extent.width, extent.height)
            guard let local = CIFilter(name: "CIGaussianBlur", parameters: [
                kCIInputImageKey: gray.clampedToExtent(),
                kCIInputRadiusKey: radius
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CIGaussianBlur")
            }
            guard let ratio = CIFilter(name: "CIDivideBlendMode", parameters: [
                kCIInputImageKey: local.cropped(to: extent),
                kCIInputBackgroundImageKey: gray
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CIDivideBlendMode")
            }
            let adaptive = try ShadingCorrector.ramp(ratio.cropped(to: extent), lo: 0.78, hi: 0.94)
            let global = try ShadingCorrector.ramp(gray, lo: 0.45, hi: 0.70)
            guard let combined = CIFilter(name: "CIMinimumCompositing", parameters: [
                kCIInputImageKey: adaptive,
                kCIInputBackgroundImageKey: global
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CIMinimumCompositing")
            }
            ci = combined.cropped(to: extent)
        }

        // 出力を入力 extent に合わせてピクセルサイズを保持する
        return try render(ci.cropped(to: CIImage(cgImage: normalized).extent), scale: image.scale)
    }

    /// 画像を 90 度単位で時計回りに回転する。
    /// - 入力: image … 入力画像、quarterTurns … 回転回数（4 で正規化、負値は反時計回り）
    /// - 出力: 回転後の UIImage。奇数回転で縦横が入れ替わる
    /// - 処理: 回転数を mod 4 して CIImage.oriented で回転後レンダリングする
    func rotate(_ image: UIImage, quarterTurns: Int) throws -> UIImage {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else {
            // 回転なしでも向きを正規化して返す
            let cg = try normalizedCGImage(of: image)
            return UIImage(cgImage: cg, scale: image.scale, orientation: .up)
        }
        let cg = try normalizedCGImage(of: image)
        let ci = CIImage(cgImage: cg)
        // EXIF 向き: 1=right(時計回り90°) 3=down(180°) 8=left(270°相当)
        let oriented: CIImage
        switch turns {
        case 1: oriented = ci.oriented(.right)
        case 2: oriented = ci.oriented(.down)
        default: oriented = ci.oriented(.left)
        }
        return try render(oriented, scale: image.scale)
    }

    /// 画像の長辺を指定ピクセル以下へ縮小する。
    /// - 入力: image … 入力画像、maxPixelDimension … 長辺の上限（既定 3000）
    /// - 出力: 縮小後の UIImage（アスペクト比保持、scale=1。既に上限内なら同一ピクセルサイズ）
    /// - 処理: 向き正規化後、長辺が上限を超える場合のみ再描画で縮小する
    /// - Throws: CGImage 取得失敗時 invalidImage
    func downscaled(_ image: UIImage, maxPixelDimension: CGFloat = 3000) throws -> UIImage {
        let cg = try normalizedCGImage(of: image)
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let longEdge = max(width, height)
        guard longEdge > maxPixelDimension else {
            return UIImage(cgImage: cg, scale: 1, orientation: .up)
        }
        let ratio = maxPixelDimension / longEdge
        let target = CGSize(width: (width * ratio).rounded(), height: (height * ratio).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: target, format: format).image { ctx in
            UIImage(cgImage: cg).draw(in: CGRect(origin: .zero, size: target))
        }
        guard rendered.cgImage != nil else {
            throw ImageProcessingError.renderFailed
        }
        return rendered
    }

    /// UIImage の向きを正規化した CGImage を返す。
    /// - 入力: image … 任意の imageOrientation を持つ UIImage
    /// - 出力: .up 向き相当の CGImage
    /// - 処理: orientation が .up かつ cgImage があればそのまま返し、それ以外は描画し直す
    private func normalizedCGImage(of image: UIImage) throws -> CGImage {
        if image.imageOrientation == .up, let cg = image.cgImage {
            return cg
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let rendered = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        guard let cg = rendered.cgImage else {
            throw ImageProcessingError.invalidImage
        }
        return cg
    }

    /// CIImage を CGImage へレンダリングし UIImage へ包む。
    /// - 入力: ciImage … レンダリング対象、scale … 出力 UIImage の scale
    /// - 出力: レンダリング済み UIImage（向き .up）
    /// - 処理: extent 全体を CIContext で CGImage に焼き付ける
    private func render(_ ciImage: CIImage, scale: CGFloat) throws -> UIImage {
        guard let cg = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw ImageProcessingError.renderFailed
        }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}
