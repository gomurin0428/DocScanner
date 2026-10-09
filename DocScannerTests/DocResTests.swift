import CoreML
import Foundation
import XCTest
@testable import DocScanner

final class DocResTests: XCTestCase {
    func testBundledModelAndDocumentRestoration() throws {
        executionTimeAllowance = 180
        let model = try DocResEnhancer.loadModel()
        XCTAssertEqual(model.modelDescription.inputDescriptionsByName["image"]?.multiArrayConstraint?.shape,
                       [1, 6, 512, 512])
        XCTAssertEqual(model.modelDescription.outputDescriptionsByName["restored"]?.multiArrayConstraint?.shape,
                       [1, 3, 512, 512])
        let image = document()
        let source = try XCTUnwrap(image.cgImage)
        let enhancer = DocResEnhancer(model: model)
        XCTAssertNil(try enhancer.flattened(XCTUnwrap(TestImageFactory.solid(.white, size: CGSize(width: 64, height: 64)).cgImage)))
        XCTAssertNil(try enhancer.flattened(XCTUnwrap(TestImageFactory.solid(.white, size: CGSize(width: 512, height: 768)).cgImage)))
        let result = try XCTUnwrap(enhancer.flattened(source))
        XCTAssertEqual(result.width, source.width)
        XCTAssertEqual(result.height, source.height)
        XCTAssertTrue(try enhancer.flattened(source) === result)
        let bitmap = try PageBitmap(result)
        XCTAssertLessThan(bitmap.data[(700 * 512 + 50) * 4], 20, "Solid ink must remain dark")
        XCTAssertGreaterThan(bitmap.data[(100 * 512 + 470) * 4], 210, "Paper should be illuminated")
    }

    func testMissingModelUsesExistingFilterAndOriginalStaysUnchanged() throws {
        let enhancer = DocResEnhancer(model: nil)
        let image = document()
        XCTAssertNil(try enhancer.flattened(XCTUnwrap(image.cgImage)))
        let processor = DocumentImageProcessor(enhancer: enhancer)
        let original = try processor.apply(.original, to: image)
        XCTAssertEqual(try PageBitmap(XCTUnwrap(original.cgImage)).data,
                       try PageBitmap(XCTUnwrap(image.cgImage)).data)
        for filter in [PageFilter.enhanced, .grayscale, .blackAndWhite] {
            let result = try processor.apply(filter, to: image)
            XCTAssertEqual(result.size, image.size)
        }
    }

    func testThumbnailMatchesDownscaledFinalFilteredResult() throws {
        let processor = DocumentImageProcessor(enhancer: DocResEnhancer(model: nil))
        let page = ScannedPage(
            baseImage: TestImageFactory.solid(.red, size: CGSize(width: 4000, height: 3000)),
            filter: .grayscale,
            quarterTurns: 1
        )

        let thumbnail = try page.thumbnailImage(using: processor)
        XCTAssertEqual(TestImageFactory.pixelSize(of: thumbnail), CGSize(width: 168, height: 224))
        let expected = try processor.downscaled(page.renderedImage(using: processor), maxPixelDimension: 224)
        XCTAssertEqual(try PageBitmap(XCTUnwrap(thumbnail.cgImage)).data,
                       try PageBitmap(XCTUnwrap(expected.cgImage)).data)
        let color = try XCTUnwrap(TestImageFactory.pixelColor(
            of: thumbnail, x: Int(thumbnail.size.width / 2), y: Int(thumbnail.size.height / 2)))
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
        XCTAssertEqual(red, green, accuracy: 2.0 / 255)
        XCTAssertEqual(green, blue, accuracy: 2.0 / 255)
    }

    func testModelLoadFailureRequiresRestartAndDoesNotRetry() throws {
        var loadCount = 0
        let enhancer = DocResEnhancer(modelLoader: {
            loadCount += 1
            throw ImageProcessingError.invalidImage
        })
        let processor = DocumentImageProcessor(enhancer: enhancer)
        let image = document()

        for _ in 0..<2 {
            XCTAssertThrowsError(try processor.apply(.enhanced, to: image)) { error in
                XCTAssertTrue(error is DocResModelLoadingError)
                XCTAssertEqual(error.localizedDescription,
                               DocResModelLoadingError.restartRequired.localizedDescription)
            }
        }
        XCTAssertEqual(loadCount, 1)

        let original = try processor.apply(.original, to: image)
        XCTAssertEqual(try PageBitmap(XCTUnwrap(original.cgImage)).data,
                       try PageBitmap(XCTUnwrap(image.cgImage)).data)
    }

    func testCancelledProcessorCallSkipsEnhancer() async throws {
        var loadCount = 0
        let enhancer = DocResEnhancer(modelLoader: {
            loadCount += 1
            throw DocResModelLoadingError.restartRequired
        })
        let processor = DocumentImageProcessor(enhancer: enhancer)
        let image = document()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let task = Task {
            entered.signal()
            release.wait()
            return try processor.apply(.enhanced, to: image)
        }

        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        task.cancel()
        release.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled processing should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(loadCount, 0)
    }

    func testCancelledPredictionCachesGainForNextRequest() async throws {
        executionTimeAllowance = 30
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var predictionCount = 0
        var inputBuildCount = 0
        let enhancer = DocResEnhancer(prediction: { input in
            predictionCount += 1
            entered.signal()
            release.wait()
            let output = try MLMultiArray(shape: [1, 3, 512, 512], dataType: .float32)
            let inputStrides = input.strides.map(\.intValue)
            let outputStrides = output.strides.map(\.intValue)
            for channel in 0..<3 {
                for y in 0..<512 {
                    for x in 0..<512 {
                        let inputIndex = channel * inputStrides[1] + y * inputStrides[2] + x * inputStrides[3]
                        let outputIndex = channel * outputStrides[1] + y * outputStrides[2] + x * outputStrides[3]
                        output[outputIndex] = input[inputIndex]
                    }
                }
            }
            return output
        }, inputBuilder: { _, small in
            inputBuildCount += 1
            let input = try MLMultiArray(shape: [1, 6, 512, 512], dataType: .float32)
            let strides = input.strides.map(\.intValue)
            for channel in 0..<3 {
                for y in 0..<512 {
                    for x in 0..<512 {
                        let pixelIndex = (y * 512 + x) * 3 + channel
                        let inputIndex = channel * strides[1] + y * strides[2] + x * strides[3]
                        input[inputIndex] = NSNumber(value: Float(small[pixelIndex]) / 255)
                    }
                }
            }
            return input
        })
        let image = try XCTUnwrap(TestImageFactory.gradient(
            size: CGSize(width: 256, height: 256)).cgImage)
        let cancelled = Task.detached(priority: .userInitiated) { try enhancer.flattened(image) }
        XCTAssertEqual(entered.wait(timeout: .now() + 15), .success)
        cancelled.cancel()
        release.signal()

        do {
            _ = try await cancelled.value
            XCTFail("Cancelled prediction should not render a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNotNil(try enhancer.flattened(image))
        let source = UIImage(cgImage: image)
        let processor = DocumentImageProcessor(enhancer: enhancer)
        _ = try processor.apply(.enhanced, to: source)
        _ = try ScannedPage(baseImage: source, filter: .enhanced, quarterTurns: 1)
            .renderedImage(using: processor)
        XCTAssertEqual(predictionCount, 1)
        XCTAssertEqual(inputBuildCount, 1)
    }

    func testUnsafePredictionsAreRejected() throws {
        let size = DocResEnhancer.side
        let input = [UInt8](repeating: 200, count: size * size * 3)
        let prediction = try MLMultiArray(shape: [1, 3, 512, 512], dataType: .float32)
        for i in 0..<prediction.count { prediction[i] = 0.8 }
        XCTAssertNotNil(DocResEnhancer.gain(input: input, prediction: prediction))
        prediction[0] = NSNumber(value: Float.nan)
        XCTAssertNil(DocResEnhancer.gain(input: input, prediction: prediction))
        prediction[0] = NSNumber(value: Float.infinity)
        XCTAssertNil(DocResEnhancer.gain(input: input, prediction: prediction))
        for i in 0..<prediction.count { prediction[i] = 0 }
        XCTAssertNil(DocResEnhancer.gain(input: input, prediction: prediction))
        let wrongShape = try MLMultiArray(shape: [1, 3, 64, 64], dataType: .float32)
        XCTAssertNil(DocResEnhancer.gain(input: input, prediction: wrongShape))
    }

    func testGainPreservesPixelsAndOrientationInPortraitAndLandscape() throws {
        for size in [CGSize(width: 512, height: 768), CGSize(width: 768, height: 512)] {
            let source = try XCTUnwrap(TestImageFactory.gradient(size: size).cgImage)
            let bitmap = try PageBitmap(source, background: CGColor(gray: 1, alpha: 1))
            let result = try DocResEnhancer.render(bitmap, gain: [Float](repeating: 1, count: 512 * 512 * 3))
            XCTAssertEqual(try PageBitmap(result).data, bitmap.data)
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let transparent = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 512), format: format).image { _ in }
        let bitmap = try PageBitmap(XCTUnwrap(transparent.cgImage), background: CGColor(gray: 1, alpha: 1))
        let pixels = DocResPrompt.resized(bitmap, side: 512)
        XCTAssertTrue(pixels.allSatisfy { $0 == 255 })
        XCTAssertFalse(DocResPrompt.hasContrast(pixels))
        let result = try DocResEnhancer.render(bitmap, gain: [Float](repeating: 1, count: 512 * 512 * 3))
        XCTAssertTrue(try PageBitmap(result).data.allSatisfy { $0 == 255 })
    }

    func testPromptMorphologyMatchesIndependentWindowCalculation() {
        let side = 13
        let pixels = (0..<(side * side)).map { UInt8(($0 * 67 + $0 / side * 23) % 256) }
        let maximum = DocResPrompt.maximum(pixels, side: side, radius: 3)
        let median = DocResPrompt.median(pixels, side: side, radius: 5)
        for y in 0..<side {
            for x in 0..<side {
                var maximumWindow: [UInt8] = [], medianWindow: [UInt8] = []
                for dy in -5...5 {
                    for dx in -5...5 {
                        let pixel = pixels[min(side - 1, max(0, y + dy)) * side + min(side - 1, max(0, x + dx))]
                        medianWindow.append(pixel)
                        if abs(dx) <= 3 && abs(dy) <= 3 { maximumWindow.append(pixel) }
                    }
                }
                XCTAssertEqual(maximum[y * side + x], maximumWindow.max())
                XCTAssertEqual(median[y * side + x], medianWindow.sorted()[60])
            }
        }
    }

    private func document() -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 768), format: format).image { context in
            for y in 0..<768 {
                UIColor(white: 0.9 - CGFloat(y) / 768 * 0.3, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: y, width: 512, height: 1))
            }
            for y in stride(from: 80, to: 620, by: 45) {
                ("SCAN 0123456789 — Document" as NSString).draw(at: CGPoint(x: 30, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 19), .foregroundColor: UIColor.black
                ])
            }
            UIColor.black.setFill()
            context.fill(CGRect(x: 30, y: 650, width: 90, height: 90))
        }
    }
}
