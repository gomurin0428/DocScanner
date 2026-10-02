import CoreGraphics
import UIKit
import XCTest
@testable import DocScanner

final class PageContentStraightenerTests: XCTestCase {
    func testCurvedRowsBecomeHorizontalDespiteOutliers() throws {
        let lines = curvedLines()
        let noisy = lines.enumerated().map { index, line in
            line.enumerated().map { column, point in
                PagePoint(x: point.x, y: point.y + (column == 5 && index.isMultiple(of: 2) ? 0.025 : 0))
            }
        }
        let model = try XCTUnwrap(PageDewarpModel.fit(lines: noisy))
        for line in lines {
            let corrected = line.map { $0.y - model.displacement(at: $0) }
            XCTAssertLessThan(corrected.max()! - corrected.min()!, 0.006)
        }
    }

    func testInsufficientStraightAndExtremeRowsAreNotWarped() {
        XCTAssertNil(PageDewarpModel.fit(lines: []))
        XCTAssertNil(PageDewarpModel.fit(lines: Array(curvedLines().prefix(3))))
        let straight = (0..<10).map { row in
            (0..<24).map { column in
                PagePoint(x: 0.1 + Double(column) * 0.8 / 23, y: 0.15 + Double(row) * 0.07)
            }
        }
        XCTAssertNil(PageDewarpModel.fit(lines: straight))
        let extreme = straight.map { line in
            line.map { PagePoint(x: $0.x, y: $0.y + 0.3 * ($0.x - 0.5)) }
        }
        XCTAssertNil(PageDewarpModel.fit(lines: extreme))
        var invalid = curvedLines()
        invalid[0][0].x = .nan
        XCTAssertNil(PageDewarpModel.fit(lines: Array(invalid.prefix(6))))
    }

    func testInverseMapKeepsEdgesAndDoesNotFoldOrCrop() throws {
        let model = try XCTUnwrap(PageDewarpModel.fit(lines: curvedLines()))
        for x in stride(from: 0.0, through: 1, by: 0.05) {
            XCTAssertEqual(model.sourcePoint(for: PagePoint(x: x, y: 0)).y, 0)
            XCTAssertEqual(model.sourcePoint(for: PagePoint(x: x, y: 1)).y, 1)
            var previous = -1.0
            for y in stride(from: 0.0, through: 1, by: 0.01) {
                let target = PagePoint(x: x, y: y)
                let source = model.sourcePoint(for: target)
                XCTAssertEqual(source.x, x)
                XCTAssertTrue((0...1).contains(source.y))
                XCTAssertGreaterThan(source.y, previous)
                XCTAssertEqual(source.y - model.displacement(at: source), y, accuracy: 0.00005)
                previous = source.y
            }
        }
    }

    func testRenderingStraightensMarksInBothCameraOrientations() throws {
        let lines = curvedLines()
        let model = try XCTUnwrap(PageDewarpModel.fit(lines: lines))
        let width = 600, height = 800
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for line in lines {
            for point in line {
                let x = Int(point.x * Double(width)), y = Int(point.y * Double(height))
                for dy in -2...2 {
                    for dx in -2...2 {
                        let offset = ((y + dy) * width + x + dx) * 4
                        for channel in 0..<3 { pixels[offset + channel] = 0 }
                    }
                }
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let rotated = try DocumentImageProcessor().rotate(UIImage(cgImage: image), quarterTurns: -1)
        for sideways in [false, true] {
            let source = sideways ? try XCTUnwrap(rotated.cgImage) : image
            let result = try PageContentStraightener().render(source, model: model, rotated: sideways)
            XCTAssertEqual(result.width, source.width)
            XCTAssertEqual(result.height, source.height)
            let bitmap = try PageBitmap(result)
            for line in lines {
                var positions: [Int] = []
                for point in line {
                    let y = point.y - model.displacement(at: point)
                    let output = sideways ? PagePoint(x: y, y: 1 - point.x) : PagePoint(x: point.x, y: y)
                    let px = Int(output.x * Double(bitmap.width))
                    let py = Int(output.y * Double(bitmap.height))
                    let found = (-5...5).first { offset in
                        let x = sideways ? px + offset : px
                        let y = sideways ? py : py + offset
                        return bitmap.luminance(atX: Double(x), y: Double(y)) < 100
                    }
                    XCTAssertNotNil(found, "mark disappeared in orientation \(sideways)")
                    positions.append((sideways ? px : py) + (found ?? 0))
                }
                XCTAssertLessThan(positions.max()! - positions.min()!, 6)
            }
        }
    }

    func testRenderingCompositesTransparentPixelsOntoWhite() throws {
        let model = try XCTUnwrap(PageDewarpModel.fit(lines: curvedLines()))
        let width = 200, height = 300
        let colors: [[UInt8]] = [[0, 0, 0, 0], [0, 0, 0, 255], [0, 0, 0, 128], [128, 0, 0, 128]]
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<4 {
                    pixels[(y * width + x) * 4 + channel] = colors[x / 50][channel]
                }
            }
        }
        let context = try XCTUnwrap(CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try XCTUnwrap(context.makeImage())
        let result = try PageContentStraightener().render(image, model: model, rotated: false)
        let bitmap = try PageBitmap(result)
        let expected = [[255, 255, 255], [0, 0, 0], [127, 127, 127], [255, 127, 127]]
        for band in 0..<4 {
            let offset = (150 * width + band * 50 + 25) * 4
            for channel in 0..<3 {
                XCTAssertEqual(Double(bitmap.data[offset + channel]), Double(expected[band][channel]), accuracy: 1)
            }
        }
    }

    func testBlankPageRemainsIdentical() throws {
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: CGSize(width: 300, height: 400)).cgImage)
        let result = try PageContentStraightener().straighten(image)
        XCTAssertTrue(result === image)
    }

    private func curvedLines() -> [[PagePoint]] {
        (0..<10).map { row in
            let y = 0.15 + Double(row) * 0.07
            return (0..<24).map { column in
                let x = 0.1 + Double(column) * 0.8 / 23
                let offset = 0.055 * (x - 0.5) * (0.6 + y) + 0.06 * pow(x - 0.5, 2)
                return PagePoint(x: x, y: y + offset)
            }
        }
    }
}
