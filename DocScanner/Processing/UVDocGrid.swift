import CoreGraphics
import Foundation

/// UVDoc の逆写像。各点は左上原点、入力画像の 0...1 座標。
struct UVDocGrid {
    let width: Int
    let height: Int
    let points: [PagePoint]

    func constrained(to boundary: DocumentBoundary) -> UVDocGrid? {
        guard boundary.isValid, width >= 2, height >= 2, points.count == width * height,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (-0.25...1.25).contains($0.x) && (-0.25...1.25).contains($0.y) }) else { return nil }
        func edge(_ values: [CGPoint]) -> [PagePoint] {
            values.map { PagePoint(x: $0.x, y: 1 - $0.y) }
        }
        let top = edge(boundary.top), bottom = edge(boundary.bottom)
        let left = edge(boundary.left), right = edge(boundary.right)
        func corrections(_ edge: [PagePoint], indices: [Int]) -> [PagePoint] {
            indices.enumerated().map { position, index in
                let target: PagePoint
                if position == 0 { target = edge[0] }
                else if position == indices.count - 1 { target = edge[edge.count - 1] }
                else { target = Self.nearestPoint(to: points[index], on: edge) }
                return target - points[index]
            }
        }
        let dt = corrections(top, indices: Array(0..<width))
        let db = corrections(bottom, indices: Array((height - 1) * width..<height * width))
        let dl = corrections(left, indices: (0..<height).map { $0 * width })
        let dr = corrections(right, indices: (0..<height).map { $0 * width + width - 1 })
        guard (dt + db + dl + dr).allSatisfy({ $0.length <= 0.18 }) else { return nil }
        func taper(_ distance: Double) -> Double {
            let t = min(1, max(0, distance / 0.15))
            return 1 - t * t * (3 - 2 * t)
        }
        var adjusted = points
        for row in 0..<height {
            let v = Double(row) / Double(height - 1)
            let a = taper(v), b = taper(1 - v)
            for column in 0..<width {
                let u = Double(column) / Double(width - 1)
                let c = taper(u), d = taper(1 - u)
                let edges = dt[column] * a + db[column] * b + dl[row] * c + dr[row] * d
                let corners = dt[0] * (a * c) + dt[width - 1] * (a * d)
                    + db[0] * (b * c) + db[width - 1] * (b * d)
                adjusted[row * width + column] = points[row * width + column] + edges - corners
            }
        }
        let result = UVDocGrid(width: width, height: height, points: adjusted)
        return result.isSafe ? result : nil
    }

    var isSafe: Bool {
        guard width >= 2, height >= 2, points.count == width * height,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (-0.000001...1.000001).contains($0.x) && (-0.000001...1.000001).contains($0.y) }) else { return false }
        let cellArea = 1 / Double((width - 1) * (height - 1))
        for row in 0..<height - 1 {
            for column in 0..<width - 1 {
                let i = row * width + column
                let a = points[i], b = points[i + 1], c = points[i + width], d = points[i + width + 1]
                let determinants = [Self.cross(b - a, c - a), Self.cross(b - a, d - b),
                                    Self.cross(d - c, c - a), Self.cross(d - c, d - b)]
                guard determinants.allSatisfy({ $0 > cellArea * 0.05 && $0 < cellArea * 8 }) else { return false }
            }
        }
        return true
    }

    func sourcePoint(u: Double, v: Double) -> PagePoint {
        let x = min(1, max(0, u)) * Double(width - 1)
        let y = min(1, max(0, v)) * Double(height - 1)
        let column = min(Int(x), width - 2), row = min(Int(y), height - 2)
        let tx = x - Double(column), ty = y - Double(row)
        let i = row * width + column
        return (points[i] * (1 - tx) + points[i + 1] * tx) * (1 - ty)
            + (points[i + width] * (1 - tx) + points[i + width + 1] * tx) * ty
    }

    func render(_ image: CGImage, width outputWidth: Int, height outputHeight: Int) throws -> CGImage {
        guard isSafe, image.width >= 2, image.height >= 2,
              (2...4096).contains(outputWidth), (2...4096).contains(outputHeight) else {
            throw DocumentDetectionError.invalidImage
        }
        let bitmap = try PageBitmap(image, background: CGColor(gray: 1, alpha: 1))
        var pixels = [UInt8](repeating: 255, count: outputWidth * outputHeight * 4)
        pixels.withUnsafeMutableBufferPointer { buffer in
            for y in 0..<outputHeight {
                for x in 0..<outputWidth {
                    let p = sourcePoint(u: Double(x) / Double(outputWidth - 1), v: Double(y) / Double(outputHeight - 1))
                    bitmap.sampleRGB(atX: p.x * Double(bitmap.width - 1), y: p.y * Double(bitmap.height - 1),
                                     into: buffer.baseAddress! + (y * outputWidth + x) * 4)
                }
            }
        }
        guard let context = CGContext(data: &pixels, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: outputWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let image = context.makeImage() else {
            throw DocumentDetectionError.renderFailed
        }
        return image
    }

    private static func cross(_ a: PagePoint, _ b: PagePoint) -> Double { a.x * b.y - a.y * b.x }

    private static func nearestPoint(to point: PagePoint, on edge: [PagePoint]) -> PagePoint {
        var best = edge[0], distance = Double.infinity
        for i in 0..<edge.count - 1 {
            let delta = edge[i + 1] - edge[i]
            let lengthSquared = delta.x * delta.x + delta.y * delta.y
            guard lengthSquared > 0 else { continue }
            let offset = point - edge[i]
            let t = min(1, max(0, (offset.x * delta.x + offset.y * delta.y) / lengthSquared))
            let candidate = edge[i] + delta * t
            let candidateDistance = (candidate - point).length
            if candidateDistance < distance { best = candidate; distance = candidateDistance }
        }
        return best
    }
}
