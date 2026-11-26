import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

enum PageTextCurvature: Equatable {
    case insufficientText
    case straight
    case curved
}

/// 輪郭補正後の紙面を文字列の並びから補正する。文字が不足する画像はそのまま返す。
struct PageContentStraightener {
    private let context = ImageRendering.context

    func straighten(_ image: CGImage) throws -> CGImage {
        let ci = CIImage(cgImage: image)
        let scale = min(1, 1600 / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        for rotated in [false, true] {
            let analysis = rotated ? small.oriented(.right) : small
            guard let cg = context.createCGImage(analysis, from: analysis.extent) else {
                let error = DocumentDetectionError.renderFailed
                AppDiagnostics.error("Page content analysis rendering", error: error)
                throw error
            }
            let lines: [[PagePoint]]
            do {
                lines = try textLines(in: cg)
            } catch {
                AppDiagnostics.error("Page content text detection", error: error)
                throw error
            }
            guard let model = PageDewarpModel.fit(lines: lines) else {
                AppDiagnostics.selection("Page content straightening skipped: insufficient text")
                continue
            }
            return try render(image, model: model, rotated: rotated)
        }
        return image
    }

    func textCurvature(in image: CGImage) throws -> PageTextCurvature {
        let ci = CIImage(cgImage: image)
        let scale = min(1, 1600 / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var bestLines: [[PagePoint]] = []
        var bestScore = 0
        for orientation in [CGImagePropertyOrientation.up, .right, .left] {
            let analysis = orientation == .up
                ? small
                : small.oriented(forExifOrientation: Int32(orientation.rawValue))
            guard let cg = context.createCGImage(analysis, from: analysis.extent.integral) else {
                throw DocumentDetectionError.renderFailed
            }
            let lines: [[PagePoint]]
            do {
                lines = try textLines(in: cg)
            } catch {
                AppDiagnostics.error("UVDoc text curvature analysis", error: error)
                throw DocumentDetectionError.visionFailed(error)
            }
            guard Self.hasSufficientTextEvidence(lines) else { continue }
            let score = lines.reduce(0, { $0 + $1.count })
            if score > bestScore {
                bestLines = lines
                bestScore = score
            }
        }
        return Self.classifyTextCurvature(bestLines)
    }

    static func classifyTextCurvature(_ lines: [[PagePoint]]) -> PageTextCurvature {
        guard hasSufficientTextEvidence(lines) else { return .insufficientText }
        guard let curvature = baselineCurvature(lines) else { return .insufficientText }
        return curvature > 0.0015 ? .curved : .straight
    }

    private static func hasSufficientTextEvidence(_ lines: [[PagePoint]]) -> Bool {
        let rows = lines.filter { line in
            guard line.count >= 8, line.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
            }), let minX = line.map(\.x).min(), let maxX = line.map(\.x).max(),
               let minY = line.map(\.y).min(), let maxY = line.map(\.y).max() else { return false }
            return maxX - minX >= 0.18 && maxY - minY < 0.12
        }
        guard rows.count >= 3 else { return false }
        let points = rows.flatMap { $0 }
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX - minX >= 0.45, maxY - minY >= 0.25 else { return false }
        let rowCenters = rows.map { $0.map(\.y).reduce(0, +) / Double($0.count) }
        return Set(rowCenters.map { Int($0 * 6) }).count >= 3
    }

    private static func baselineCurvature(_ lines: [[PagePoint]]) -> Double? {
        let residuals = lines.compactMap { line -> [Double]? in
            guard let minX = line.map(\.x).min(), let maxX = line.map(\.x).max(), maxX > minX else { return nil }
            var bins = [[PagePoint]](repeating: [], count: 6)
            for point in line {
                let bin = min(5, Int((point.x - minX) / (maxX - minX) * 6))
                bins[bin].append(point)
            }
            let samples = bins.compactMap { values -> PagePoint? in
                guard !values.isEmpty else { return nil }
                let medianX = median(values.map(\.x))
                let medianY = median(values.map(\.y))
                return values.min { lhs, rhs in
                    let leftDistance = pow(lhs.x - medianX, 2) + pow(lhs.y - medianY, 2)
                    let rightDistance = pow(rhs.x - medianX, 2) + pow(rhs.y - medianY, 2)
                    return leftDistance < rightDistance
                }
            }
            guard samples.count >= 4 else { return nil }
            let meanX = samples.map(\.x).reduce(0, +) / Double(samples.count)
            let meanY = samples.map(\.y).reduce(0, +) / Double(samples.count)
            let variance = samples.reduce(0) { $0 + pow($1.x - meanX, 2) }
            guard variance > 0 else { return nil }
            let slope = samples.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) } / variance
            let intercept = meanY - slope * meanX
            return samples.map { abs($0.y - (slope * $0.x + intercept)) }
        }
        let values = residuals.flatMap { $0 }
        guard !values.isEmpty else { return nil }
        return median(values)
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    private func textLines(in image: CGImage) throws -> [[PagePoint]] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let characters = observation.characterBoxes, characters.count >= 8 else { return nil }
            return characters.map { character in
                let corners = [character.topLeft, character.topRight, character.bottomRight, character.bottomLeft]
                let ySum: CGFloat = corners.reduce(CGFloat.zero) { $0 + $1.y }
                let meanY: CGFloat = ySum / CGFloat(4)
                return PagePoint(x: corners.map(\.x).reduce(0, +) / 4,
                                 y: Double(CGFloat(1) - meanY))
            }
        }
    }

    func render(_ image: CGImage, model: PageDewarpModel, rotated: Bool) throws -> CGImage {
        let bitmap = try PageBitmap(image, background: CGColor(gray: 1, alpha: 1))
        let width = bitmap.width, height = bitmap.height
        let count = 64
        var grid: [PagePoint] = []
        for y in 0...count {
            for x in 0...count {
                let output = PagePoint(x: Double(x) / Double(count), y: Double(y) / Double(count))
                let oriented = rotated ? PagePoint(x: 1 - output.y, y: output.x) : output
                let source = model.sourcePoint(for: oriented)
                let point = rotated ? PagePoint(x: source.y, y: 1 - source.x) : source
                grid.append(PagePoint(x: point.x * Double(width) - 0.5,
                                      y: point.y * Double(height) - 0.5))
            }
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<height {
                let v = (Double(y) + 0.5) / Double(height) * Double(count)
                let row = min(Int(v), count - 1), ty = v - Double(row)
                for x in 0..<width {
                    let u = (Double(x) + 0.5) / Double(width) * Double(count)
                    let column = min(Int(u), count - 1), tx = u - Double(column)
                    let i = row * (count + 1) + column
                    let point = (grid[i] * (1 - tx) + grid[i + 1] * tx) * (1 - ty)
                        + (grid[i + count + 1] * (1 - tx) + grid[i + count + 2] * tx) * ty
                    bitmap.sampleRGB(atX: point.x, y: point.y,
                                     into: buffer.baseAddress! + (y * width + x) * 4)
                }
            }
        }
        guard let context = CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let result = context.makeImage() else {
            throw DocumentDetectionError.renderFailed
        }
        return result
    }
}

struct PageTextOrientationCorrector {
    private let context = ImageRendering.context
    private static let orientations: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
    private static let maximumAnalysisDimension: CGFloat = 1024

    func correct(_ image: CGImage) throws -> CGImage {
        let scores = try orientationScores(of: image)
        guard let orientation = Self.preferredOrientation(scores: scores) else {
            AppDiagnostics.selection("Photo text orientation unchanged: scores=\(Self.summary(scores))")
            return image
        }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation.rawValue))
        guard let result = context.createCGImage(oriented, from: oriented.extent.integral) else {
            throw DocumentDetectionError.renderFailed
        }
        AppDiagnostics.selection("Photo text orientation corrected: \(orientation), scores=\(Self.summary(scores))")
        return result
    }

    func orientationScores(of image: CGImage) throws -> [Double] {
        let source = CIImage(cgImage: image)
        let scale = min(1, Self.maximumAnalysisDimension / max(CGFloat(image.width), CGFloat(image.height)))
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let analysisImage = context.createCGImage(scaled, from: scaled.extent.integral) else {
            throw DocumentDetectionError.renderFailed
        }
        return try Self.orientations.map { orientation in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            do {
                try VNImageRequestHandler(cgImage: analysisImage, orientation: orientation, options: [:])
                    .perform([request])
            } catch {
                AppDiagnostics.error("Photo text orientation", error: error)
                throw DocumentDetectionError.visionFailed(error)
            }
            return (request.results ?? []).reduce(0.0) { total, observation in
                guard let candidate = observation.topCandidates(1).first else { return total }
                let characterCount = candidate.string.filter { !$0.isWhitespace }.count
                return total + Double(characterCount) * Double(candidate.confidence)
            }
        }
    }

    static func preferredOrientation(scores: [Double]) -> CGImagePropertyOrientation? {
        guard scores.count == orientations.count,
              scores.allSatisfy({ $0.isFinite && $0 >= 0 }),
              let best = scores.indices.max(by: { scores[$0] < scores[$1] }),
              best != 0 else { return nil }
        let bestScore = scores[best]
        let nextBest = scores.indices.filter { $0 != best }.map { scores[$0] }.max() ?? 0
        guard bestScore >= 12,
              bestScore >= scores[0] * 1.08 + 4,
              bestScore - nextBest >= max(4, bestScore * 0.08) else { return nil }
        return orientations[best]
    }

    private static func summary(_ scores: [Double]) -> String {
        scores.map { String(format: "%.1f", $0) }.joined(separator: ",")
    }
}
