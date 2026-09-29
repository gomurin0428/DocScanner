import CoreImage
import UIKit
import Vision

/// ドキュメント検出処理中に発生するエラー。
enum DocumentDetectionError: LocalizedError, Equatable {
    /// 画像内に四角形の書類が検出できなかった。
    case noDocumentFound
    /// 入力画像を解析可能な形式へ変換できなかった。
    case invalidImage
    /// Vision リクエストの実行に失敗した。
    case visionFailed(String)
    /// 台形補正フィルタの出力が得られなかった。
    case correctionFailed
    /// 補正後画像のレンダリングに失敗した。
    case renderFailed

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .noDocumentFound:
            return "No document edges were detected."
        case .invalidImage:
            return "The image could not be read."
        case .visionFailed(let message):
            return "Document detection failed: \(message)"
        case .correctionFailed:
            return "The detected document could not be perspective-corrected."
        case .renderFailed:
            return "The corrected image could not be rendered."
        }
    }
}

/// 写真画像から書類の四角形を検出し、台形補正して取り出す検出器。
struct DocumentDetector {

    /// CI レンダリング用の共有コンテキスト。
    private let context = CIContext()

    /// 検出器を初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み DocumentDetector
    /// - 処理: CIContext を生成する
    init() {}

    /// 画像内の書類を検出して台形補正済み画像を返す。
    /// - 入力: image … 書類を含む入力画像
    /// - 出力: 検出領域を正面から見た画像に補正した UIImage
    /// - 処理: 向き正規化 → VNDetectRectanglesRequest → CIPerspectiveCorrection → レンダリング
    /// - Throws: 検出失敗時 DocumentDetectionError.noDocumentFound など
    func detectAndCorrect(_ image: UIImage) throws -> UIImage {
        let cg = try normalizedCGImage(of: image)
        let ciImage = CIImage(cgImage: cg)

        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.3
        request.maximumObservations = 1
        request.quadratureTolerance = 30

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw DocumentDetectionError.visionFailed(error.localizedDescription)
        }
        guard let rectangle = request.results?.first else {
            throw DocumentDetectionError.noDocumentFound
        }

        // Vision の正規化座標（左下原点）を画像ピクセル座標へ変換する
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        func toImagePoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * width, y: (1 - p.y) * height)
        }

        guard let corrected = CIFilter(name: "CIPerspectiveCorrection", parameters: [
            kCIInputImageKey: ciImage,
            "inputTopLeft": CIVector(cgPoint: toImagePoint(rectangle.topLeft)),
            "inputTopRight": CIVector(cgPoint: toImagePoint(rectangle.topRight)),
            "inputBottomLeft": CIVector(cgPoint: toImagePoint(rectangle.bottomLeft)),
            "inputBottomRight": CIVector(cgPoint: toImagePoint(rectangle.bottomRight))
        ])?.outputImage else {
            throw DocumentDetectionError.correctionFailed
        }

        guard let outputCG = context.createCGImage(corrected, from: corrected.extent) else {
            throw DocumentDetectionError.renderFailed
        }
        return UIImage(cgImage: outputCG, scale: image.scale, orientation: .up)
    }

    /// UIImage の向きを正規化した CGImage を返す。
    /// - 入力: image … 任意の imageOrientation を持つ UIImage
    /// - 出力: .up 向き相当の CGImage
    /// - 処理: .up なら cgImage をそのまま返し、それ以外は描画し直す
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
            throw DocumentDetectionError.invalidImage
        }
        return cg
    }
}
