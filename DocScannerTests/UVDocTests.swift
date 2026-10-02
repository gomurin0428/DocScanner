import CoreML
import UIKit
import XCTest
@testable import DocScanner

final class UVDocTests: XCTestCase {
    private var boundary: DocumentBoundary {
        DocumentBoundary(corners: [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
                                   CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)])
    }

    private func identity(width: Int = 31, height: Int = 45) -> UVDocGrid {
        UVDocGrid(width: width, height: height, points: (0..<height).flatMap { row in
            (0..<width).map { PagePoint(x: Double($0) / Double(width - 1), y: Double(row) / Double(height - 1)) }
        })
    }

    func testModelIsBundledAndPredictsFiniteXYGrid() throws {
        let model = try UVDocUnwarper.loadModel()
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: CGSize(width: 100, height: 150)).cgImage)
        let input = try UVDocUnwarper.input(for: image)
        XCTAssertEqual(input.shape.map(\.intValue), [1, 3, 712, 488])
        let grid = try XCTUnwrap(UVDocUnwarper(model: model).predict(input))
        XCTAssertEqual(grid.width, 31)
        XCTAssertEqual(grid.height, 45)
        XCTAssertTrue(grid.points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testConstrainedGridPreservesFrameAndInterior() throws {
        let source = identity()
        let inset = UVDocGrid(width: source.width, height: source.height,
            points: source.points.map { PagePoint(x: 0.03 + 0.94 * $0.x, y: 0.04 + 0.92 * $0.y) })
        let result = try XCTUnwrap(inset.constrained(to: boundary))
        for i in 0..<result.width {
            XCTAssertEqual(result.points[i].y, 0, accuracy: 0.000001)
            XCTAssertEqual(result.points[(result.height - 1) * result.width + i].y, 1, accuracy: 0.000001)
        }
        for row in 0..<result.height {
            XCTAssertEqual(result.points[row * result.width].x, 0, accuracy: 0.000001)
            XCTAssertEqual(result.points[row * result.width + result.width - 1].x, 1, accuracy: 0.000001)
        }
        let index = 20 * result.width + 12
        XCTAssertEqual(result.points[index].x, inset.points[index].x)
        XCTAssertEqual(result.points[index].y, inset.points[index].y)
        XCTAssertTrue(result.isSafe)
    }

    func testRejectsNonFiniteFoldedAndUnrelatedGrids() {
        let grid = identity()
        var invalid = grid.points
        invalid[100].x = .nan
        XCTAssertNil(UVDocGrid(width: grid.width, height: grid.height, points: invalid).constrained(to: boundary))
        var folded = grid.points
        folded[300].x = folded[302].x
        XCTAssertFalse(UVDocGrid(width: grid.width, height: grid.height, points: folded).isSafe)
        let inset = grid.points.map { PagePoint(x: 0.4 + $0.x * 0.2, y: 0.4 + $0.y * 0.2) }
        XCTAssertNil(UVDocGrid(width: grid.width, height: grid.height, points: inset).constrained(to: boundary))
    }

    func testSamplingKeepsOrientationAndCompositesAlpha() throws {
        let width = 80, height = 120
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                if x < width / 2 && y < height / 2 { pixels[i] = 128; pixels[i + 3] = 128 }
                if x >= width / 2 && y >= height / 2 { pixels[i + 2] = 255; pixels[i + 3] = 255 }
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let result = try identity().render(image, width: width, height: height)
        let bitmap = try PageBitmap(result)
        for (x, y, color) in [(10, 10, [255, 127, 127]), (60, 10, [255, 255, 255]), (60, 100, [0, 0, 255])] {
            for channel in 0..<3 {
                XCTAssertEqual(Int(bitmap.data[(y * width + x) * 4 + channel]), color[channel])
            }
        }
        let input = try UVDocUnwarper.input(for: image)
        XCTAssertEqual(input[[0, 0, 40, 40]], 1)
        XCTAssertEqual(input[[0, 1, 40, 40]].doubleValue, 127.0 / 255, accuracy: 0.00001)
        XCTAssertEqual(input[[0, 2, 650, 450]], 1)
    }

    func testBlankLandscapeAndPortraitFallBack() throws {
        for size in [CGSize(width: 200, height: 300), CGSize(width: 300, height: 200)] {
            let image = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
            XCTAssertNil(try UVDocUnwarper.shared.unwarp(image, boundary: boundary))
        }
        let skew = DocumentBoundary(corners: [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.8, y: 0.9),
                                              CGPoint(x: 0.9, y: 0.2), CGPoint(x: 0.2, y: 0.1)])
        var rotated = skew
        for _ in 0..<4 { rotated = UVDocUnwarper.rotatedRight(rotated) }
        for (a, b) in zip(rotated.outline, skew.outline) {
            XCTAssertEqual(a.x, b.x, accuracy: 0.000001)
            XCTAssertEqual(a.y, b.y, accuracy: 0.000001)
        }
    }
}
