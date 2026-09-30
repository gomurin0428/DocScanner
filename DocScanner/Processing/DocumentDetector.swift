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
    /// セグメンテーションマスクのピクセル形式が想定外だった（形式識別子付き）。
    case unexpectedMaskFormat(String)
    /// ビットマップコンテキストの生成に失敗した。
    case bitmapContextFailed
    /// ホモグラフィ方程式が特異で解けなかった。
    case singularHomography

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
        case .unexpectedMaskFormat(let format):
            return "The document segmentation mask had an unexpected pixel format (\(format))."
        case .bitmapContextFailed:
            return "A bitmap context could not be created for the document image."
        case .singularHomography:
            return "The document boundary could not be mapped to a rectangle."
        }
    }
}

/// 写真画像から書類の四角形を検出し、台形補正して取り出す検出器。
struct DocumentDetector {

    /// CI レンダリング用の共有コンテキスト。
    private let context = CIContext()

    /// セグメンテーション結果を採用する最低信頼度。
    /// 無地画像は 0〜0.55、実書類は 0.99 程度のため 0.8 で弾く。
    private static let segConfidenceThreshold: VNConfidence = 0.8

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
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])

        // まず従来どおり四角形検出を行う（見つからなければ noDocumentFound）
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.3
        request.maximumObservations = 1
        request.quadratureTolerance = 30
        do {
            try handler.perform([request])
        } catch {
            throw DocumentDetectionError.visionFailed(error.localizedDescription)
        }
        guard let rectangle = request.results?.first else {
            throw DocumentDetectionError.noDocumentFound
        }

        // 四角形が取れた場合のみセグメンテーションを試す。
        // 信頼度・マスク有無・四角形との一致を全て満たす場合だけ
        // 輪郭追跡フラット化を使い、それ以外は従来の台形補正に留める
        let segRequest = VNDetectDocumentSegmentationRequest()
        do {
            try handler.perform([segRequest])
        } catch {
            throw DocumentDetectionError.visionFailed(error.localizedDescription)
        }
        if let observation = segRequest.results?.first,
           observation.confidence >= Self.segConfidenceThreshold,
           let maskBuffer = observation.globalSegmentationMask,
           Self.quadsAgree(
               [observation.topLeft, observation.topRight,
                observation.bottomRight, observation.bottomLeft],
               [rectangle.topLeft, rectangle.topRight,
                rectangle.bottomRight, rectangle.bottomLeft],
               width: width, height: height) {
            let mask = try SegmentationMask(
                pixelBuffer: maskBuffer.pixelBuffer,
                imageWidth: cg.width,
                imageHeight: cg.height
            )
            // Vision 正規化座標（左下原点）→ 左上原点ピクセル座標
            // （フラットナとマスクは行が上から順のため反転する）
            func toTopLeft(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * width, y: (1 - p.y) * height)
            }
            let flattened = try PageFlattener().flatten(cg, corners: [
                toTopLeft(observation.topLeft),
                toTopLeft(observation.topRight),
                toTopLeft(observation.bottomRight),
                toTopLeft(observation.bottomLeft)
            ], mask: mask)
            return UIImage(cgImage: flattened, scale: image.scale, orientation: .up)
        }
        return try perspectiveCorrect(
            ciImage, rectangle: rectangle, scale: image.scale)
    }

    /// セグメンテーション四角形と矩形検出四角形が十分一致するかを判定する。
    /// - 入力: a / b … 4 隅の正規化左下原点座標配列（TL, TR, BR, BL の順）、
    ///   width / height … 画像のピクセルサイズ
    /// - 出力: 全 4 隅の対応点距離が max(W,H) の 8% 以内なら true
    /// - 処理: 同じインデックス同士のピクセル距離を比較する。
    ///   プラットフォーム差で破綻した seg 四角形（全面/ストリップ範囲）を弾くためのゲート
    static func quadsAgree(_ a: [CGPoint], _ b: [CGPoint],
                           width: CGFloat, height: CGFloat) -> Bool {
        guard a.count == 4, b.count == 4 else { return false }
        let threshold = max(width, height) * 0.08
        for i in 0..<4 {
            let dx = (a[i].x - b[i].x) * width
            let dy = (a[i].y - b[i].y) * height
            if (dx * dx + dy * dy).squareRoot() > threshold { return false }
        }
        return true
    }

    /// 四角形観測結果で CIPerspectiveCorrection を適用し UIImage へ焼き付ける。
    /// - 入力: ciImage … 元画像、rectangle … Vision の四角形（正規化左下原点座標）、
    ///   scale … 出力 UIImage の scale
    /// - 出力: 台形補正済み UIImage（向き .up）
    /// - 処理: 正規化座標をピクセル座標へ変換しフィルタ適用 → レンダリング
    /// - Throws: フィルタ失敗 correctionFailed、レンダリング失敗 renderFailed
    private func perspectiveCorrect(
        _ ciImage: CIImage, rectangle: VNRectangleObservation, scale: CGFloat
    ) throws -> UIImage {
        let width = ciImage.extent.width
        let height = ciImage.extent.height

        // Vision の正規化座標（左下原点）を CIImage 座標へ変換する。
        // CIImage も左下原点のため y の反転は不要（反転すると上下ミラー + 歪み + 背景混入になる）
        func toImagePoint(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * width, y: p.y * height)
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
        return UIImage(cgImage: outputCG, scale: scale, orientation: .up)
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
