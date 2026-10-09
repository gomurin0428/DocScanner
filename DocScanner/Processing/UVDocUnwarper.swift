import CoreGraphics
import CoreImage
import CoreML
import Foundation

enum UVDocModelLoadingError: LocalizedError {
    case restartRequired(underlying: Error)
    case missingResource

    var underlyingError: Error? {
        if case .restartRequired(let error) = self { return error }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .missingResource:
            return "The DocScanner document geometry model is missing. Repair, reinstall, or update the app."
        case .restartRequired:
            return "The DocScanner document geometry model could not be loaded. Please close and reopen DocScanner."
        }
    }
}

enum UVDocProcessingError: LocalizedError {
    case invalidModelOutput
    case predictionFailed(Error)

    var errorDescription: String? {
        switch self {
        case .invalidModelOutput:
            return "The DocScanner document geometry model returned invalid output."
        case .predictionFailed:
            return "The DocScanner document geometry model could not process this image."
        }
    }
}

final class UVDocUnwarper {
    static let shared = UVDocUnwarper(production: true)
    private var model: MLModel?
    private var modelLoader: (() throws -> MLModel)?
    private var modelLoadError: UVDocModelLoadingError?
    private let lock = NSLock()
    private let context = ImageRendering.context

    init(model: MLModel? = nil) {
        self.model = model
    }

    init(modelLoader: @escaping () throws -> MLModel) {
        self.modelLoader = modelLoader
    }

    private init(production: Bool) {
        if production { modelLoader = Self.loadModel }
    }

    static func loadModel() throws -> MLModel {
        guard let url = Bundle(for: UVDocUnwarper.self).url(forResource: "UVDoc", withExtension: "mlmodelc") else {
            throw UVDocModelLoadingError.missingResource
        }
        let configuration = MLModelConfiguration()
        #if targetEnvironment(simulator) || os(macOS)
        configuration.computeUnits = .cpuOnly
        #else
        configuration.computeUnits = .cpuAndNeuralEngine
        #endif
        return try MLModel(contentsOf: url, configuration: configuration)
    }

    func unwarp(_ image: CGImage, boundary: DocumentBoundary) throws -> CGImage? {
        guard boundary.isValid else {
            throw DocumentDetectionError.invalidImage
        }
        let xs = boundary.outline.map(\.x), ys = boundary.outline.map(\.y)
        let bounds = CGRect(x: xs.min()! * Double(image.width), y: (1 - ys.max()!) * Double(image.height),
                            width: (xs.max()! - xs.min()!) * Double(image.width),
                            height: (ys.max()! - ys.min()!) * Double(image.height)).integral
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard min(bounds.width, bounds.height) >= 64 else {
            AppDiagnostics.selection("UVDoc skipped: small document crop")
            return nil
        }
        guard min(bounds.width, bounds.height) / max(bounds.width, bounds.height) >= 0.35 else {
            AppDiagnostics.selection("UVDoc skipped: extreme document aspect ratio")
            return nil
        }
        guard var crop = image.cropping(to: bounds) else {
            throw DocumentDetectionError.correctionFailed
        }
        var croppedBoundary = boundary.map { point in
            CGPoint(x: (point.x * Double(image.width) - bounds.minX) / bounds.width,
                    y: 1 - ((1 - point.y) * Double(image.height) - bounds.minY) / bounds.height)
        }
        let rotated = crop.width > crop.height
        if rotated {
            crop = try rotate(crop, right: true)
            croppedBoundary = Self.rotatedRight(croppedBoundary)
        }
        let input = try Self.input(for: crop)
        guard Self.hasContrast(input) else {
            AppDiagnostics.selection("UVDoc skipped: low contrast document crop")
            return nil
        }
        try ensureModel()
        guard model != nil else { return nil }
        guard let raw = try predict(input) else {
            let error = UVDocProcessingError.invalidModelOutput
            AppDiagnostics.error("UVDoc model output", error: error)
            throw error
        }
        guard let grid = raw.constrained(to: croppedBoundary) else {
            let error = UVDocProcessingError.invalidModelOutput
            AppDiagnostics.error("UVDoc model output", error: error)
            throw error
        }
        let corners = croppedBoundary.corners.map {
            PagePoint(x: $0.x * Double(crop.width), y: $0.y * Double(crop.height))
        }
        let width = ((corners[1] - corners[0]).length + (corners[2] - corners[3]).length) / 2
        let height = ((corners[3] - corners[0]).length + (corners[2] - corners[1]).length) / 2
        let scale = min(1, 4096 / max(width, height))
        let output = try grid.render(crop, width: Int((width * scale).rounded()), height: Int((height * scale).rounded()))
        return rotated ? try rotate(output, right: false) : output
    }

    func predict(_ input: MLMultiArray) throws -> UVDocGrid? {
        guard let model else { return nil }
        let features = try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(multiArray: input)])
        lock.lock()
        defer { lock.unlock() }
        let result: MLFeatureProvider
        do {
            result = try model.prediction(from: features)
        } catch {
            let predictionError = UVDocProcessingError.predictionFailed(error)
            AppDiagnostics.error("UVDoc prediction", error: predictionError)
            throw predictionError
        }
        guard let array = result.featureValue(for: "grid")?.multiArrayValue,
              array.shape.map(\.intValue) == [1, 2, 45, 31], array.dataType == .float32 else {
            let error = UVDocProcessingError.invalidModelOutput
            AppDiagnostics.error("UVDoc model output", error: error)
            throw error
        }
        let strides = array.strides.map(\.intValue)
        let values = array.dataPointer.assumingMemoryBound(to: Float.self)
        let points = (0..<45).flatMap { row in
            (0..<31).map { column in
                let i = row * strides[2] + column * strides[3]
                return PagePoint(x: (Double(values[i]) + 1) / 2, y: (Double(values[i + strides[1]]) + 1) / 2)
            }
        }
        return UVDocGrid(width: 31, height: 45, points: points)
    }

    private func ensureModel() throws {
        lock.lock()
        defer { lock.unlock() }
        if let modelLoadError { throw modelLoadError }
        if model != nil { return }
        guard let loader = modelLoader else { return }
        modelLoader = nil
        do {
            model = try loader()
        } catch {
            let loadError: UVDocModelLoadingError
            if let typed = error as? UVDocModelLoadingError {
                loadError = typed
            } else {
                loadError = .restartRequired(underlying: error)
            }
            modelLoadError = loadError
            AppDiagnostics.error("UVDoc model loading", error: loadError)
            throw loadError
        }
    }

    static func input(for image: CGImage) throws -> MLMultiArray {
        guard image.width >= 2, image.height >= 2 else { throw DocumentDetectionError.invalidImage }
        let bitmap = try PageBitmap(image, background: CGColor(gray: 1, alpha: 1))
        let result = try MLMultiArray(shape: [1, 3, 712, 488], dataType: .float32)
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        let strides = result.strides.map(\.intValue)
        for y in 0..<712 {
            let sy = min(Double(bitmap.height - 1), max(0, (Double(y) + 0.5) * Double(bitmap.height) / 712 - 0.5))
            let y0 = min(Int(sy), bitmap.height - 2), fy = sy - Double(y0)
            for x in 0..<488 {
                let sx = min(Double(bitmap.width - 1), max(0, (Double(x) + 0.5) * Double(bitmap.width) / 488 - 0.5))
                let x0 = min(Int(sx), bitmap.width - 2), fx = sx - Double(x0)
                for channel in 0..<3 {
                    let i = (y0 * bitmap.width + x0) * 4 + channel
                    let top = Double(bitmap.data[i]) * (1 - fx) + Double(bitmap.data[i + 4]) * fx
                    let bottom = Double(bitmap.data[i + bitmap.width * 4]) * (1 - fx)
                        + Double(bitmap.data[i + bitmap.width * 4 + 4]) * fx
                    output[channel * strides[1] + y * strides[2] + x * strides[3]] = Float((top * (1 - fy) + bottom * fy) / 255)
                }
            }
        }
        return result
    }

    static func rotatedRight(_ boundary: DocumentBoundary) -> DocumentBoundary {
        let b = boundary.map { CGPoint(x: $0.y, y: 1 - $0.x) }
        return DocumentBoundary(top: Array(b.left.reversed()), right: b.top,
                                bottom: Array(b.right.reversed()), left: b.bottom)
    }

    private static func hasContrast(_ input: MLMultiArray) -> Bool {
        let count = 488 * 712
        let pixels = input.dataPointer.assumingMemoryBound(to: Float.self)
        var histogram = [Int](repeating: 0, count: 256)
        for i in 0..<count {
            let value = (pixels[i] + pixels[count + i] + pixels[2 * count + i]) / 3
            histogram[min(255, max(0, Int(value * 255)))] += 1
        }
        var accumulated = 0, low = 0
        for value in 0..<256 {
            accumulated += histogram[value]
            if accumulated < count / 100 { low = value }
            if accumulated >= count * 99 / 100 { return value - low > 12 }
        }
        return false
    }

    private func rotate(_ image: CGImage, right: Bool) throws -> CGImage {
        let ci = CIImage(cgImage: image).oriented(right ? .right : .left)
        guard let result = context.createCGImage(ci, from: ci.extent) else { throw DocumentDetectionError.renderFailed }
        return result
    }
}
