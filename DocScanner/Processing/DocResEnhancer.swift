import CoreGraphics
import CoreML
import Foundation
import os

/// DocRes failed to load and requires an app restart before retrying.
enum DocResModelLoadingError: LocalizedError {
    case restartRequired

    var errorDescription: String? {
        "The image enhancement model could not be loaded. Please close and reopen KDocScanner."
    }
}

final class DocResEnhancer {
    static let shared = DocResEnhancer()
    static let side = 512
    private let lock = NSLock()
    private var model: MLModel?
    private var modelLoader: (() throws -> MLModel)?
    private var modelLoadError: DocResModelLoadingError?
    private var cachedSource: CGImage?
    private var cachedResult: CGImage?

    private init() { modelLoader = Self.loadModel }

    init(model: MLModel?) { self.model = model }

    init(modelLoader: @escaping () throws -> MLModel) {
        self.modelLoader = modelLoader
    }

    static func loadModel() throws -> MLModel {
        guard let url = Bundle(for: DocResEnhancer.self).url(forResource: "DocResAppearance", withExtension: "mlmodelc") else {
            throw DocumentDetectionError.invalidImage
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    func flattened(_ image: CGImage) throws -> CGImage? {
        try Task.checkCancellation()
        guard min(image.width, image.height) >= 256,
              Double(min(image.width, image.height)) / Double(max(image.width, image.height)) >= 0.2 else { return nil }
        try Task.checkCancellation()
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        if cachedSource === image { return cachedResult }
        if let modelLoadError {
            throw modelLoadError
        }
        #if os(iOS) && !targetEnvironment(simulator)
        guard os_proc_available_memory() >= 2_200_000_000 else { return nil }
        #endif
        if let loader = modelLoader {
            modelLoader = nil
            do {
                model = try loader()
            } catch {
                let loadError = DocResModelLoadingError.restartRequired
                modelLoadError = loadError
                throw loadError
            }
        }
        guard let model else { return nil }
        let bitmap = try PageBitmap(image, background: CGColor(gray: 1, alpha: 1))
        let small = DocResPrompt.resized(bitmap, side: Self.side)
        guard DocResPrompt.hasContrast(small) else { return nil }
        let input = try DocResPrompt.input(bitmap: bitmap, small: small)
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
        try Task.checkCancellation()
        let prediction = try model.prediction(from: features)
        try Task.checkCancellation()
        guard let array = prediction.featureValue(for: "restored")?.multiArrayValue,
              let gain = Self.gain(input: small, prediction: array) else { return nil }
        let result = try Self.render(bitmap, gain: gain)
        cachedSource = image
        cachedResult = result
        return result
    }

    static func gain(input: [UInt8], prediction: MLMultiArray) -> [Float]? {
        let count = side * side
        guard input.count == count * 3, prediction.shape.map(\.intValue) == [1, 3, side, side],
              prediction.dataType == .float32 else { return nil }
        let strides = prediction.strides.map(\.intValue)
        let values = prediction.dataPointer.assumingMemoryBound(to: Float.self)
        var result = [Float](repeating: 0, count: count * 3)
        for channel in 0..<3 {
            var original = [Float](repeating: 0, count: count)
            var restored = original
            for y in 0..<side {
                for x in 0..<side {
                    let i = y * side + x
                    let value = values[(2 - channel) * strides[1] + y * strides[2] + x * strides[3]]
                    guard value.isFinite, value >= -1, value <= 2 else { return nil }
                    restored[i] = min(1, max(0, value))
                    original[i] = Float(input[i * 3 + channel]) / 255
                }
            }
            let numerator = smoothed(restored)
            let denominator = smoothed(original)
            var clipped = 0
            for i in 0..<count {
                let value = numerator[i] / max(0.02, denominator[i])
                if value < 0.75 || value > 4 { clipped += 1 }
                result[i * 3 + channel] = min(4, max(0.75, value))
            }
            guard clipped < count / 10 else { return nil }
        }
        return result
    }

    private static func smoothed(_ values: [Float]) -> [Float] {
        let radius = 9
        let weights = (-radius...radius).map { exp(-Float($0 * $0) / 18) }
        let sum = weights.reduce(0, +)
        let kernel = weights.map { $0 / sum }
        var horizontal = values, output = values
        for y in 0..<side {
            for x in 0..<side {
                var value: Float = 0
                for offset in -radius...radius {
                    value += values[y * side + min(side - 1, max(0, x + offset))] * kernel[offset + radius]
                }
                horizontal[y * side + x] = value
            }
        }
        for y in 0..<side {
            for x in 0..<side {
                var value: Float = 0
                for offset in -radius...radius {
                    value += horizontal[min(side - 1, max(0, y + offset)) * side + x] * kernel[offset + radius]
                }
                output[y * side + x] = value
            }
        }
        return output
    }

    static func render(_ bitmap: PageBitmap, gain: [Float]) throws -> CGImage {
        guard gain.count == side * side * 3,
              gain.allSatisfy({ $0.isFinite && $0 >= 0.75 && $0 <= 4 }) else {
            throw DocumentDetectionError.invalidImage
        }
        var pixels = bitmap.data
        for y in 0..<bitmap.height {
            let sy = min(Double(side - 1), max(0, (Double(y) + 0.5) * Double(side) / Double(bitmap.height) - 0.5))
            let y0 = min(side - 2, Int(sy)), fy = Float(sy - Double(y0))
            for x in 0..<bitmap.width {
                let sx = min(Double(side - 1), max(0, (Double(x) + 0.5) * Double(side) / Double(bitmap.width) - 0.5))
                let x0 = min(side - 2, Int(sx)), fx = Float(sx - Double(x0))
                let source = (y * bitmap.width + x) * 4
                let i = (y0 * side + x0) * 3
                for channel in 0..<3 {
                    let top = gain[i + channel] * (1 - fx) + gain[i + 3 + channel] * fx
                    let bottom = gain[i + side * 3 + channel] * (1 - fx) + gain[i + side * 3 + 3 + channel] * fx
                    let value = Float(bitmap.data[source + channel]) * (top * (1 - fy) + bottom * fy)
                    pixels[source + channel] = UInt8(min(255, max(0, value)))
                }
                pixels[source + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: bitmap.width, height: bitmap.height, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: bitmap.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw DocumentDetectionError.renderFailed
        }
        return image
    }
}
