import CoreImage
import Foundation
import UIKit
import Vision

/// ドキュメント検出処理中に発生するエラー。
enum DocumentDetectionError: LocalizedError, Equatable {
    /// 画像内に四角形の書類が検出できなかった。
    case noDocumentFound
    /// 入力画像を解析可能な形式へ変換できなかった。
    case invalidImage
    /// Vision リクエストの実行に失敗した。
    case visionFailed(Error)
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

    static func == (lhs: DocumentDetectionError, rhs: DocumentDetectionError) -> Bool {
        switch (lhs, rhs) {
        case (.noDocumentFound, .noDocumentFound),
             (.invalidImage, .invalidImage),
             (.correctionFailed, .correctionFailed),
             (.renderFailed, .renderFailed),
             (.bitmapContextFailed, .bitmapContextFailed),
             (.singularHomography, .singularHomography):
            return true
        case (.visionFailed(let left), .visionFailed(let right)):
            return left.localizedDescription == right.localizedDescription
        case (.unexpectedMaskFormat(let left), .unexpectedMaskFormat(let right)):
            return left == right
        default:
            return false
        }
    }

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .noDocumentFound:
            return "No document edges were detected."
        case .invalidImage:
            return "The image could not be read."
        case .visionFailed(let underlying):
            return "Document detection failed: \(underlying.localizedDescription)"
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

    private let unwarper: UVDocUnwarper

    init(unwarper: UVDocUnwarper = .shared) {
        self.unwarper = unwarper
    }

    /// 撮影時に固定した輪郭だけを補正する。Vision による対象の再選択は行わない。
    /// - 入力: 撮影画像と正規化輪郭、出力: 同じ輪郭を矩形にした画像
    func correct(_ image: UIImage, boundary: DocumentBoundary, camera: DocumentCamera? = nil,
                 refineBoundary: Bool = false) throws -> UIImage {
        let cg = try normalizedCGImage(of: image)
        let detectedBoundary = boundary
        let boundary = refineBoundary ? try PageFlattener().refineBoundary(cg, boundary: boundary) : boundary
        Self.logBoundary(boundary, imageSize: CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height)),
                         source: refineBoundary && boundary != detectedBoundary ? "refined rectangle" : "rectangle")
        if let output = try unwarper.unwarp(cg, boundary: boundary, camera: camera) {
            return UIImage(cgImage: output, scale: image.scale, orientation: .up)
        }
        let flattened = try PageFlattener().flatten(cg, boundary: boundary, camera: camera)
        let output = try PageContentStraightener().straighten(flattened)
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }

    /// セグメンテーション結果を採用する最低信頼度。
    /// 無地画像は 0〜0.55、実書類は 0.99 程度のため 0.8 で弾く。
    private static let segConfidenceThreshold: VNConfidence = 0.8

    /// 画像内の書類を検出して台形補正済み画像を返す。
    /// - 入力: image … 書類を含む入力画像
    /// - 出力: 検出領域を正面から見た画像に補正した UIImage
    /// - 処理: 縮小画像で領域検出 → 元画像を輪郭・カメラ情報で補正
    /// - Throws: 検出失敗時 DocumentDetectionError.noDocumentFound など
    func detectAndCorrect(_ image: UIImage, camera: DocumentCamera? = nil) throws -> UIImage {
        let cg = try normalizedCGImage(of: image)
        let analysis = try DocumentImageProcessor().downscaled(UIImage(cgImage: cg), maxPixelDimension: 1600)
        guard let detectionImage = analysis.cgImage else { throw DocumentDetectionError.invalidImage }
        AppDiagnostics.selection("Photo detection: \(detectionImage.width)x\(detectionImage.height), source \(cg.width)x\(cg.height)")
        let ciImage = CIImage(cgImage: detectionImage)
        let width = CGFloat(detectionImage.width)
        let height = CGFloat(detectionImage.height)
        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])

        let request = DocumentRectangleDetector.makeRequest()
        do {
            try handler.perform([request])
        } catch {
            AppDiagnostics.error("Rectangle detection", error: error)
            throw DocumentDetectionError.visionFailed(error)
        }
        let rectangles = request.results ?? []
        let segRequest = VNDetectDocumentSegmentationRequest()
        do {
            try handler.perform([segRequest])
        } catch {
            AppDiagnostics.error("Document segmentation", error: error)
            throw DocumentDetectionError.visionFailed(error)
        }
        let segmentation = segRequest.results?.first
        let imageSize = CGSize(width: width, height: height)
        AppDiagnostics.selection("Photo candidates: rectangles=[\(Self.summary(rectangles))], " +
                                 "segmentation=\(Self.summary(segmentation))")
        let rectangle: VNRectangleObservation
        if let detected = DocumentRectangleDetector.liveDocument(
            in: rectangles, document: segmentation, size: imageSize) {
            rectangle = detected
        } else {
            let fallbackRequest = DocumentRectangleDetector.makePhotoFallbackRequest()
            do {
                try handler.perform([fallbackRequest])
            } catch {
                AppDiagnostics.error("Rectangle detection retry", error: error)
                throw DocumentDetectionError.visionFailed(error)
            }
            let fallbackRectangles = fallbackRequest.results ?? []
            AppDiagnostics.selection("Photo detection retry: strict=[\(Self.summary(rectangles))], " +
                                     "fallback=[\(Self.summary(fallbackRectangles))], " +
                                     "segmentation=\(Self.summary(segmentation))")
            guard let detected = DocumentRectangleDetector.liveDocument(
                in: fallbackRectangles, document: segmentation, size: imageSize,
                minimumConfidence: 0.35, minimumSize: 0.05,
                minimumDocumentConfidence: 0.6, minimumDocumentSize: 0.1) else {
                throw DocumentDetectionError.noDocumentFound
            }
            rectangle = detected
        }
        AppDiagnostics.selection("Photo selected paper: \(Self.summary([rectangle]))")
        let corrected: UIImage
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
                imageWidth: detectionImage.width,
                imageHeight: detectionImage.height
            )
            // Vision 正規化座標（左下原点）→ 左上原点ピクセル座標
            // （フラットナとマスクは行が上から順のため反転する）
            func toTopLeft(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * width, y: (1 - p.y) * height)
            }
            let boundary = try PageFlattener().traceBoundary(detectionImage, corners: [
                toTopLeft(observation.topLeft), toTopLeft(observation.topRight),
                toTopLeft(observation.bottomRight), toTopLeft(observation.bottomLeft)
            ], mask: mask)
            Self.logBoundary(boundary, imageSize: CGSize(width: CGFloat(cg.width), height: CGFloat(cg.height)),
                             source: "segmentation")
            if let output = try unwarper.unwarp(cg, boundary: boundary, camera: camera) {
                corrected = UIImage(cgImage: output, scale: image.scale, orientation: .up)
            } else {
                let flattened = try PageFlattener().flatten(cg, boundary: boundary, camera: camera)
                let straightened = try PageContentStraightener().straighten(flattened)
                corrected = UIImage(cgImage: straightened, scale: image.scale, orientation: .up)
            }
        } else {
            let detectedBoundary = DocumentBoundary(corners: [rectangle.topLeft,
                rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft])
            let flattener = PageFlattener()
            let locallyRefined = try flattener.refineBoundary(detectionImage, boundary: detectedBoundary)
            let localEdgesSupported = [locallyRefined.top, locallyRefined.right,
                                       locallyRefined.bottom, locallyRefined.left]
                .allSatisfy { $0.count > 2 }
            let boundary: DocumentBoundary
            if localEdgesSupported || locallyRefined.hasMeasuredCurvedEdges(in: imageSize) {
                boundary = locallyRefined
                AppDiagnostics.selection("Photo edge recovery skipped: local boundary samples retained")
            } else {
                guard let recovered = try flattener.recoverPhotoBoundary(
                    detectionImage, boundary: detectedBoundary) else {
                    throw DocumentDetectionError.noDocumentFound
                }
                boundary = recovered
            }
            corrected = try correct(image, boundary: boundary, camera: camera, refineBoundary: true)
        }
        guard let correctedCGImage = corrected.cgImage else { throw DocumentDetectionError.invalidImage }
        let upright = try PageTextOrientationCorrector().correct(correctedCGImage)
        return UIImage(cgImage: upright, scale: corrected.scale, orientation: .up)
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

    private static func summary(_ observations: [VNRectangleObservation]) -> String {
        observations.map { observation in
            let points = [observation.topLeft, observation.topRight,
                          observation.bottomRight, observation.bottomLeft]
            let corners = points.map { String(format: "%.3f,%.3f", $0.x, $0.y) }.joined(separator: ";")
            return String(format: "%.2f:[%@]", observation.confidence, corners)
        }.joined(separator: ";")
    }

    private static func summary(_ observation: VNRectangleObservation?) -> String {
        guard let observation else { return "none" }
        return summary([observation])
    }

    private static func logBoundary(_ boundary: DocumentBoundary, imageSize: CGSize, source: String) {
        let deviations: String
        if let values = boundary.edgeMaximumDeviationPixels(in: imageSize) {
            deviations = values.map { String(format: "%.1f", $0) }.joined(separator: ",")
        } else {
            deviations = "unmeasured"
        }
        let corners = boundary.corners.map { String(format: "%.3f,%.3f", $0.x, $0.y) }
            .joined(separator: ";")
        AppDiagnostics.selection("Photo crop boundary: source=\(source), corners=[\(corners)], " +
                                 "maxDeviationPx=[\(deviations)]")
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
