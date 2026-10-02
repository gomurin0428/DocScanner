import CoreML
import Foundation

enum DocResPrompt {
    static func resized(_ bitmap: PageBitmap, side: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            let sy = min(Double(bitmap.height - 1), max(0, (Double(y) + 0.5) * Double(bitmap.height) / Double(side) - 0.5))
            let y0 = min(bitmap.height - 2, Int(sy)), fy = sy - Double(y0)
            for x in 0..<side {
                let sx = min(Double(bitmap.width - 1), max(0, (Double(x) + 0.5) * Double(bitmap.width) / Double(side) - 0.5))
                let x0 = min(bitmap.width - 2, Int(sx)), fx = sx - Double(x0)
                for channel in 0..<3 {
                    let i = (y0 * bitmap.width + x0) * 4 + channel
                    let top = Double(bitmap.data[i]) * (1 - fx) + Double(bitmap.data[i + 4]) * fx
                    let bottom = Double(bitmap.data[i + bitmap.width * 4]) * (1 - fx)
                        + Double(bitmap.data[i + bitmap.width * 4 + 4]) * fx
                    output[(y * side + x) * 3 + channel] = UInt8((top * (1 - fy) + bottom * fy).rounded())
                }
            }
        }
        return output
    }

    static func hasContrast(_ pixels: [UInt8]) -> Bool {
        var histogram = [Int](repeating: 0, count: 256)
        for i in stride(from: 0, to: pixels.count, by: 3) {
            histogram[(Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])) / 3] += 1
        }
        let count = pixels.count / 3
        var cumulative = 0, low = 0
        for value in 0..<256 {
            cumulative += histogram[value]
            if cumulative < count / 100 { low = value }
            if cumulative >= count * 99 / 100 { return value - low > 12 }
        }
        return false
    }

    static func input(bitmap: PageBitmap, small: [UInt8]) throws -> MLMultiArray {
        let side = DocResEnhancer.side
        let promptSide = 1024
        let large = resized(bitmap, side: promptSide)
        let result = try MLMultiArray(shape: [1, 6, NSNumber(value: side), NSNumber(value: side)], dataType: .float32)
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        let count = side * side
        for channel in 0..<3 {
            let plane = stride(from: channel, to: large.count, by: 3).map { large[$0] }
            let background = median(maximum(plane, side: promptSide, radius: 3), side: promptSide, radius: 10)
            let difference = zip(plane, background).map { 255 - abs(Int($0) - Int($1)) }
            let low = difference.min()!, high = difference.max()!
            let prompt = difference.map { high > low ? UInt8((Double($0 - low) * 255 / Double(high - low)).rounded()) : 0 }
            for y in 0..<side {
                for x in 0..<side {
                    let i = y * side + x
                    let p = 2 * y * promptSide + 2 * x
                    let average = (Int(prompt[p]) + Int(prompt[p + 1]) + Int(prompt[p + promptSide]) + Int(prompt[p + promptSide + 1]) + 2) / 4
                    output[(2 - channel) * count + i] = Float(small[i * 3 + channel]) / 255
                    output[(5 - channel) * count + i] = Float(average) / 255
                }
            }
        }
        return result
    }

    static func maximum(_ values: [UInt8], side: Int, radius: Int) -> [UInt8] {
        var horizontal = values, output = values
        for y in 0..<side {
            for x in 0..<side {
                var value: UInt8 = 0
                for offset in -radius...radius {
                    value = max(value, values[y * side + min(side - 1, max(0, x + offset))])
                }
                horizontal[y * side + x] = value
            }
        }
        for y in 0..<side {
            for x in 0..<side {
                var value: UInt8 = 0
                for offset in -radius...radius {
                    value = max(value, horizontal[min(side - 1, max(0, y + offset)) * side + x])
                }
                output[y * side + x] = value
            }
        }
        return output
    }

    static func median(_ values: [UInt8], side: Int, radius: Int) -> [UInt8] {
        var output = values
        let middle = (radius * 2 + 1) * (radius * 2 + 1) / 2
        for y in 0..<side {
            var histogram = [Int](repeating: 0, count: 256)
            for dy in -radius...radius {
                let row = min(side - 1, max(0, y + dy)) * side
                for dx in -radius...radius {
                    histogram[Int(values[row + min(side - 1, max(0, dx))])] += 1
                }
            }
            var value = 0, below = 0
            for x in 0..<side {
                while below > middle { value -= 1; below -= histogram[value] }
                while below + histogram[value] <= middle { below += histogram[value]; value += 1 }
                output[y * side + x] = UInt8(value)
                guard x + 1 < side else { continue }
                for dy in -radius...radius {
                    let row = min(side - 1, max(0, y + dy)) * side
                    let removed = Int(values[row + max(0, x - radius)])
                    let added = Int(values[row + min(side - 1, x + radius + 1)])
                    histogram[removed] -= 1
                    histogram[added] += 1
                    if removed < value { below -= 1 }
                    if added < value { below += 1 }
                }
            }
        }
        return output
    }
}
