import CoreGraphics
import CoreML
import Foundation
import os

/// DocRes failed to load and requires an app restart before retrying.
enum DocResModelLoadingError: LocalizedError {
    case restartRequired
    case failed(underlying: Error)
    case missingResource

    var underlyingError: Error? {
        if case .failed(let underlying) = self { return underlying }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .missingResource:
            return "The DocScanner image enhancement model is missing. Repair, reinstall, or update the app."
        case .restartRequired, .failed:
            return "The image enhancement model could not be loaded. Please close and reopen DocScanner."
        }
    }
}

enum DocResProcessingError: LocalizedError {
    case invalidModelOutput
    case predictionFailed(Error)
    case insufficientMemory(UInt64)
    case renderFailed(Error)

    var underlyingError: Error? {
        if case .predictionFailed(let error) = self { return error }
        if case .renderFailed(let error) = self { return error }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidModelOutput:
            return "The DocScanner image enhancement model returned invalid output."
        case .predictionFailed:
            return "The DocScanner image enhancement model could not process this image."
        case .insufficientMemory:
            return "DocScanner does not have enough memory to enhance this image. Close other apps or reopen DocScanner, or choose Original."
        case .renderFailed:
            return "The DocScanner image enhancement result could not be rendered."
        }
    }
}

final class DocResEnhancer {
    private struct GainCacheEntry {
        let source: CGImage
        let gain: [Float]
    }

    static let shared = DocResEnhancer()
    static let side = 512
    private static let maxGainCacheEntries = 8
    private let lock = NSLock()
    private var model: MLModel?
    private var modelLoader: (() throws -> MLModel)?
    private var inputBuilder: ((PageBitmap, [UInt8]) throws -> MLMultiArray)?
    private var predictionOverride: ((MLMultiArray) throws -> MLMultiArray)?
    private var modelLoadError: DocResModelLoadingError?
    private var cachedSource: CGImage?
    private var cachedResult: CGImage?
    private var gainCache: [GainCacheEntry] = []

    private init() { modelLoader = Self.loadModel }

    init(model: MLModel?) { self.model = model }

    init(modelLoader: @escaping () throws -> MLModel) {
        self.modelLoader = modelLoader
    }

    init(
        prediction: @escaping (MLMultiArray) throws -> MLMultiArray,
        inputBuilder: ((PageBitmap, [UInt8]) throws -> MLMultiArray)? = nil
    ) {
        predictionOverride = prediction
        self.inputBuilder = inputBuilder
    }

    static func loadModel() throws -> MLModel {
        guard let url = Bundle(for: DocResEnhancer.self).url(forResource: "DocResAppearance", withExtension: "mlmodelc") else {
            throw DocResModelLoadingError.missingResource
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    func flattened(_ image: CGImage) throws -> CGImage? {
        try Task.checkCancellation()
        guard min(image.width, image.height) >= 256,
              Double(min(image.width, image.height)) / Double(max(image.width, image.height)) >= 0.2 else {
            AppDiagnostics.selection("DocRes skipped: small image or extreme aspect ratio")
            return nil
        }
        lock.lock()
        defer { lock.unlock() }
        try Task.checkCancellation()
        if let modelLoadError { throw modelLoadError }
        if cachedSource === image {
            return cachedResult
        }
        if let index = gainCache.firstIndex(where: { $0.source === image }) {
            let entry = gainCache.remove(at: index)
            gainCache.insert(entry, at: 0)
            let result = try Self.render(image, gain: entry.gain)
            cachedSource = image
            cachedResult = result
            return result
        }
        let bitmap = try PageBitmap(image, background: CGColor(gray: 1, alpha: 1),
                                    maximumPixelDimension: DocResPrompt.promptSide)
        let small = DocResPrompt.resized(bitmap, side: Self.side)
        guard DocResPrompt.hasContrast(small) else {
            AppDiagnostics.selection("DocRes skipped: low contrast image")
            return nil
        }
        #if os(iOS) && !targetEnvironment(simulator)
        let available = os_proc_available_memory()
        guard available >= 2_200_000_000 else {
            let error = DocResProcessingError.insufficientMemory(UInt64(available))
            AppDiagnostics.error("DocRes enhancement skipped for insufficient memory", error: error)
            throw error
        }
        #endif
        if let loader = modelLoader {
            modelLoader = nil
            do {
                model = try loader()
            } catch {
                let loadError: DocResModelLoadingError
                if let typed = error as? DocResModelLoadingError {
                    loadError = typed
                } else {
                    loadError = .failed(underlying: error)
                }
                modelLoadError = loadError
                AppDiagnostics.error("DocRes model loading", error: loadError)
                throw loadError
            }
        }
        try Task.checkCancellation()
        guard model != nil || predictionOverride != nil else { return nil }
        let input: MLMultiArray
        if let inputBuilder {
            input = try inputBuilder(bitmap, small)
        } else {
            input = try DocResPrompt.input(bitmap: bitmap, small: small)
        }
        try Task.checkCancellation()
        let array: MLMultiArray
        do {
            if let predictionOverride {
                array = try predictionOverride(input)
            } else {
                let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
                let prediction = try model!.prediction(from: features)
                guard let output = prediction.featureValue(for: "restored")?.multiArrayValue else {
                    throw DocResProcessingError.invalidModelOutput
                }
                array = output
            }
        } catch {
            let predictionError = DocResProcessingError.predictionFailed(error)
            AppDiagnostics.error("DocRes prediction", error: predictionError)
            throw predictionError
        }
        guard let gain = Self.gain(input: small, prediction: array) else {
            let error = DocResProcessingError.invalidModelOutput
            AppDiagnostics.error("DocRes model output", error: error)
            throw error
        }
        let entry = GainCacheEntry(source: image, gain: gain)
        gainCache.insert(entry, at: 0)
        if gainCache.count > Self.maxGainCacheEntries {
            gainCache.removeLast()
        }
        try Task.checkCancellation()
        let result: CGImage
        do {
            result = try Self.render(image, gain: gain)
        } catch {
            let renderError = DocResProcessingError.renderFailed(error)
            AppDiagnostics.error("DocRes rendering", error: error)
            throw renderError
        }
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
        var original = [Float](repeating: 0, count: count)
        var restored = original
        for y in 0..<side {
            for x in 0..<side {
                let i = y * side + x
                let red = values[2 * strides[1] + y * strides[2] + x * strides[3]]
                let green = values[strides[1] + y * strides[2] + x * strides[3]]
                let blue = values[y * strides[2] + x * strides[3]]
                guard red.isFinite, green.isFinite, blue.isFinite,
                      (-1...2).contains(red), (-1...2).contains(green), (-1...2).contains(blue) else { return nil }
                let inputOffset = i * 3
                original[i] = (0.2126 * Float(input[inputOffset])
                                + 0.7152 * Float(input[inputOffset + 1])
                                + 0.0722 * Float(input[inputOffset + 2])) / 255
                restored[i] = 0.2126 * min(1, max(0, red))
                    + 0.7152 * min(1, max(0, green))
                    + 0.0722 * min(1, max(0, blue))
            }
        }
        let numerator = smoothed(restored)
        let denominator = smoothed(original)
        var result = [Float](repeating: 0, count: count)
        var clipped = 0
        for i in 0..<count {
            let value = numerator[i] / max(0.02, denominator[i])
            if value < 0.75 || value > 4 { clipped += 1 }
            result[i] = min(4, max(0.75, value))
        }
        guard clipped < count / 10 else { return nil }
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

    static func render(_ image: CGImage, gain: [Float]) throws -> CGImage {
        guard gain.count == side * side,
              gain.allSatisfy({ $0.isFinite && $0 >= 0.75 && $0 <= 4 }) else {
            throw DocResProcessingError.invalidModelOutput
        }
        let width = image.width
        let height = image.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DocResProcessingError.renderFailed(DocumentDetectionError.bitmapContextFailed)
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw DocResProcessingError.renderFailed(DocumentDetectionError.renderFailed)
        }
        for y in 0..<height {
            let sy = min(Double(side - 1), max(0, (Double(y) + 0.5) * Double(side) / Double(height) - 0.5))
            let y0 = min(side - 2, Int(sy)), fy = Float(sy - Double(y0))
            for x in 0..<width {
                let sx = min(Double(side - 1), max(0, (Double(x) + 0.5) * Double(side) / Double(width) - 0.5))
                let x0 = min(side - 2, Int(sx)), fx = Float(sx - Double(x0))
                let i = y0 * side + x0
                let top = gain[i] * (1 - fx) + gain[i + 1] * fx
                let bottom = gain[i + side] * (1 - fx) + gain[i + side + 1] * fx
                let factor = top * (1 - fy) + bottom * fy
                let offset = (y * width + x) * 4
                let sourceLight = (0.2126 * Float(pixels[offset]) + 0.7152 * Float(pixels[offset + 1])
                                   + 0.0722 * Float(pixels[offset + 2])) / 255
                let transition = min(1, max(0, (sourceLight - 0.08) / 0.32))
                let protection = transition * transition * (3 - 2 * transition)
                let appliedFactor = 1 + (factor - 1) * protection
                let red = Float(pixels[offset]) * appliedFactor
                let green = Float(pixels[offset + 1]) * appliedFactor
                let blue = Float(pixels[offset + 2]) * appliedFactor
                let maximum = max(red, max(green, blue)) / 255
                var scale: Float = 1
                if appliedFactor > 1 && maximum > 0.9 {
                    let excess = maximum - 0.9
                    let mappedMaximum = 0.9 + 0.1 * (1 - exp(-excess / 0.1))
                    scale = mappedMaximum / maximum
                }
                pixels[offset] = UInt8(min(255, max(0, red * scale)))
                pixels[offset + 1] = UInt8(min(255, max(0, green * scale)))
                pixels[offset + 2] = UInt8(min(255, max(0, blue * scale)))
                pixels[offset + 3] = 255
            }
        }
        guard let output = context.makeImage() else {
            throw DocResProcessingError.renderFailed(DocumentDetectionError.renderFailed)
        }
        return output
    }
}
