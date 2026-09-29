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
    private let context = CIContext()

    /// プロセッサを初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み DocumentImageProcessor
    /// - 処理: CIContext を生成する
    init() {}

    /// 指定フィルタを画像へ適用する。
    /// - 入力: filter … 適用する PageFilter、image … 入力画像（向きは内部で正規化する）
    /// - 出力: フィルタ適用後の UIImage。ピクセルサイズは入力と同一
    /// - 処理: 向き正規化 → CIImage 化 → フィルタ適用 → CGImage レンダリング
    func apply(_ filter: PageFilter, to image: UIImage) throws -> UIImage {
        let normalized = try normalizedCGImage(of: image)
        var ci = CIImage(cgImage: normalized)

        switch filter {
        case .original:
            break
        case .enhanced:
            // コントラスト +15%、彩度 +10% をかけ、シャープ化で文字をくっきりさせる
            guard let controls = CIFilter(name: "CIColorControls", parameters: [
                kCIInputImageKey: ci,
                kCIInputContrastKey: 1.15,
                kCIInputSaturationKey: 1.1
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CIColorControls")
            }
            guard let sharpened = CIFilter(name: "CISharpenLuminance", parameters: [
                kCIInputImageKey: controls,
                kCIInputSharpnessKey: 0.4
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CISharpenLuminance")
            }
            ci = sharpened
        case .grayscale:
            guard let output = grayscaleFilter(for: ci) else {
                throw ImageProcessingError.filterFailed("CIColorControls")
            }
            ci = output
        case .blackAndWhite:
            // グレースケール化 → コントラスト強化 → 閾値で 2 値化
            guard let gray = grayscaleFilter(for: ci) else {
                throw ImageProcessingError.filterFailed("CIColorControls")
            }
            guard let contrast = CIFilter(name: "CIColorControls", parameters: [
                kCIInputImageKey: gray,
                kCIInputContrastKey: 1.4
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CIColorControls")
            }
            guard let threshold = CIFilter(name: "CIColorThreshold", parameters: [
                kCIInputImageKey: contrast,
                "inputThreshold": 0.5
            ])?.outputImage else {
                throw ImageProcessingError.filterFailed("CIColorThreshold")
            }
            ci = threshold
        }

        return try render(ci, scale: image.scale)
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

    /// グレースケール（彩度 0）フィルタの出力を返す。
    /// - 入力: input … 入力 CIImage
    /// - 出力: 彩度 0 の CIImage。フィルタ生成失敗時は nil
    /// - 処理: CIColorControls を saturation 0 で生成する
    private func grayscaleFilter(for input: CIImage) -> CIImage? {
        CIFilter(name: "CIColorControls", parameters: [
            kCIInputImageKey: input,
            kCIInputSaturationKey: 0.0
        ])?.outputImage
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
