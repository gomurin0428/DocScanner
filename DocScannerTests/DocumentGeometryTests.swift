import ImageIO
import simd
import UniformTypeIdentifiers
import XCTest
@testable import DocScanner

final class DocumentGeometryTests: XCTestCase {
    private let size = CGSize(width: 1600, height: 2400)
    private var camera: DocumentCamera {
        DocumentCamera(focalX: 2100, focalY: 2050, centerX: 810, centerY: 1190, referenceSize: size)
    }

    func testCalibratedA4RecoversAspectForBothTiltAxesAndLandscape() throws {
        for tilt in [0.0, 15, 25, 35, 45] {
            for angles in [(tilt, 0.0), (0.0, tilt), (tilt, tilt / 2)] {
                for landscape in [false, true] {
                    let boundary = projected(pitch: angles.0, yaw: angles.1, landscape: landscape)
                    let output = try PageGeometry.outputSize(boundary: boundary, imageSize: size, camera: camera)
                    XCTAssertEqual(output.height / output.width, landscape ? 210 / 297.0 : 297 / 210.0, accuracy: 0.005)
                }
            }
        }
    }

    func testUncalibratedFocalEstimateAndFrontalReceipt() throws {
        let centered = DocumentCamera(focalX: 2100, focalY: 2100, centerX: 800, centerY: 1200, referenceSize: size)
        let boundary = projected(pitch: 35, yaw: 25, calibration: centered)
        let output = try PageGeometry.outputSize(boundary: boundary, imageSize: size)
        XCTAssertEqual(output.height / output.width, 297 / 210.0, accuracy: 0.005)
        let receipt = DocumentBoundary(corners: [CGPoint(x: 0.4, y: 0.9), CGPoint(x: 0.6, y: 0.9),
                                                CGPoint(x: 0.6, y: 0.1), CGPoint(x: 0.4, y: 0.1)])
        let narrow = try PageGeometry.outputSize(boundary: receipt, imageSize: size)
        XCTAssertEqual(narrow.width, 320)
        XCTAssertEqual(narrow.height, 1920)
        let large = try PageGeometry.outputSize(boundary: receipt, imageSize: CGSize(width: 16000, height: 24000))
        XCTAssertEqual(large.height, 4096)
        XCTAssertEqual(large.height / large.width, 6, accuracy: 0.01)
    }

    func testCalibrationTracksOrientationAndResolution() throws {
        let oriented = camera.oriented(.right)
        XCTAssertEqual(oriented.referenceSize, CGSize(width: 2400, height: 1600))
        XCTAssertEqual(oriented.focalX, 2050)
        XCTAssertEqual(oriented.focalY, 2100)
        XCTAssertEqual(oriented.centerX, 1210)
        XCTAssertEqual(oriented.centerY, 810)
        let boundary = projected(pitch: 35, yaw: 20)
        let high = try PageGeometry.outputSize(boundary: boundary, imageSize: size, camera: camera)
        let low = try PageGeometry.outputSize(boundary: boundary, imageSize: CGSize(width: 800, height: 1200), camera: camera)
        XCTAssertEqual(high.height / high.width, low.height / low.width, accuracy: 0.005)
    }

    func testCurvedEdgesPreserveUnfoldedResolutionAspectAndOutputLimit() throws {
        let top = [CGPoint(x: 0.1, y: 0.8), CGPoint(x: 0.3, y: 0.97),
                   CGPoint(x: 0.5, y: 0.8), CGPoint(x: 0.7, y: 0.97), CGPoint(x: 0.9, y: 0.8)]
        let bottom = top.map { CGPoint(x: $0.x, y: $0.y - 0.6) }
        let boundary = DocumentBoundary(top: top, right: [top.last!, bottom.last!],
                                        bottom: bottom, left: [top[0], bottom[0]])
        let size = CGSize(width: 1000, height: 1000)
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
        let expectedArcWidth = 4 * hypot(200.0, 170.0)
        let output = try PageFlattener().flatten(image, boundary: boundary)
        XCTAssertGreaterThanOrEqual(Double(output.width), expectedArcWidth - 1)
        XCTAssertEqual(Double(output.height) / Double(output.width), 0.75, accuracy: 0.002)
        let large = try PageGeometry.outputSize(boundary: boundary, imageSize: CGSize(width: 5000, height: 5000))
        XCTAssertEqual(large.width, 4096)
        XCTAssertEqual(large.height / large.width, 0.75, accuracy: 0.001)
    }

    func testExifEquivalentFocalLengthIsRetained() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: CGSize(width: 400, height: 600)).cgImage)
        let properties = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifFocalLenIn35mmFilm: 26]] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let calibration = try XCTUnwrap(DocumentCamera.from(data: data as Data))
        XCTAssertEqual(calibration.focalX, 26 * hypot(400, 600) / hypot(36, 24), accuracy: 0.01)
        XCTAssertEqual(calibration.referenceSize, CGSize(width: 400, height: 600))
        XCTAssertNil(DocumentCamera.from(data: Data()))
    }

    func testFlattenerAndDetectorUseCalibratedDimensions() throws {
        let boundary = projected(pitch: 35, yaw: 20)
        let image = TestImageFactory.solid(.white, size: size)
        let cg = try XCTUnwrap(image.cgImage)
        let output = try PageFlattener().flatten(cg, boundary: boundary, camera: camera)
        XCTAssertEqual(Double(output.height) / Double(output.width), 297 / 210.0, accuracy: 0.005)
        let corrected = try DocumentDetector(unwarper: UVDocUnwarper()).correct(image, boundary: boundary, camera: camera)
        XCTAssertEqual(corrected.size.height / corrected.size.width, 297 / 210.0, accuracy: 0.005)
    }

    private func projected(pitch: Double, yaw: Double, landscape: Bool = false,
                           calibration: DocumentCamera? = nil) -> DocumentBoundary {
        let k = calibration ?? camera
        let width = landscape ? 297.0 : 210.0, height = landscape ? 210.0 : 297.0
        let rotation = simd_quatd(angle: pitch * .pi / 180, axis: SIMD3(1, 0, 0)) *
            simd_quatd(angle: yaw * .pi / 180, axis: SIMD3(0, 1, 0))
        let points = [SIMD3(-width / 2, -height / 2, 0.0), SIMD3(width / 2, -height / 2, 0.0),
                      SIMD3(width / 2, height / 2, 0.0), SIMD3(-width / 2, height / 2, 0.0)]
        return DocumentBoundary(corners: points.map { point in
            let p = rotation.act(point) + SIMD3(40, 25, 1100.0)
            return CGPoint(x: (k.focalX * p.x / p.z + k.centerX) / size.width,
                           y: 1 - (k.focalY * p.y / p.z + k.centerY) / size.height)
        })
    }
}
