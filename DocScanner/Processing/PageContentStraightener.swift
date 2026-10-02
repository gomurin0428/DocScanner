import CoreGraphics
import CoreImage
import Vision

/// 輪郭補正後の紙面を文字列の並びから補正する。文字が不足する画像はそのまま返す。
struct PageContentStraightener {
    private let context = CIContext()

    func straighten(_ image: CGImage) throws -> CGImage {
        let ci = CIImage(cgImage: image)
        let scale = min(1, 1600 / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        for rotated in [false, true] {
            let analysis = rotated ? small.oriented(.right) : small
            guard let cg = context.createCGImage(analysis, from: analysis.extent),
                  let lines = try? textLines(in: cg),
                  let model = PageDewarpModel.fit(lines: lines) else { continue }
            return try render(image, model: model, rotated: rotated)
        }
        return image
    }

    private func textLines(in image: CGImage) throws -> [[PagePoint]] {
        let request = VNDetectTextRectanglesRequest()
        request.reportCharacterBoxes = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let characters = observation.characterBoxes, characters.count >= 8 else { return nil }
            return characters.map { character in
                let corners = [character.topLeft, character.topRight, character.bottomRight, character.bottomLeft]
                return PagePoint(x: corners.map(\.x).reduce(0, +) / 4,
                                 y: 1 - corners.map(\.y).reduce(0, +) / 4)
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
