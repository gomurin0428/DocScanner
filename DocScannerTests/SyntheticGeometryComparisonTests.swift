import CoreGraphics
import Foundation
import XCTest
import UIKit
@testable import DocScanner

final class SyntheticGeometryComparisonTests: XCTestCase {
    private let flattener = PageFlattener()

    func testSyntheticGroundTruthComparison() throws {
        for kind in WarpKind.allCases {
            let fixture = try Fixture.make(kind)
            assertInverseRoundTrip(fixture)
            if kind.isInteriorWarp {
                for i in 0...16 {
                    let t = Double(i) / 16
                    for (u, v) in [(t, 0.0), (t, 1.0), (0.0, t), (1.0, t)] {
                        let (x, y) = fixture.forward(u: u, v: v)
                        XCTAssertEqual(x, fixture.x0 + fixture.width * u, accuracy: 1e-10)
                        XCTAssertEqual(y, fixture.y0 + fixture.height * v, accuracy: 1e-10)
                    }
                }
                XCTAssertEqual(fixture.forward(u: 0.5, v: 0.5).0, fixture.x0 + fixture.width / 2 + 24)
            }
            let analytic = try analyticReconstruction(fixture)
            let analyticScore = try metrics(analytic, fixture.reference)
            XCTAssertLessThan(analyticScore.mae, 0.06)
            if kind == .identity {
                XCTAssertEqual(analyticScore.mae, 0, accuracy: 0.01)
                XCTAssertEqual(analyticScore.inkF1, 1)
            }
            let traced = try flattener.traceBoundary(
                fixture.image, corners: fixture.corners, mask: fixture.mask)
            let maskOutput = try flattener.flatten(fixture.image, boundary: traced)
            let maskMetric = try metrics(maskOutput, fixture.reference)
            let boundaryMean = boundaryError(traced, fixture.boundary, fixture.size)
            let knownBoundary = try flattener.flatten(fixture.image, boundary: fixture.boundary)
            let knownBoundaryMetric = try metrics(knownBoundary, fixture.reference)
            var row: [String: Any] = [
                "case": kind.rawValue,
                "coordinateConvention": "top-left image edge origin; pixel centers at (i+0.5,j+0.5); boundary normalized bottom-left",
                "analyticInverse": scoreJSON(analyticScore),
                "knownBoundaryFlatten": scoreJSON(knownBoundaryMetric),
                "maskTrace": scoreJSON(maskMetric), "boundaryMeanPx": boundaryMean
            ]
            var outputs: [(String, CGImage)] = [
                ("analytic-inverse", analytic), ("known-boundary-flatten", knownBoundary),
                ("mask-trace-flatten", maskOutput)
            ]
            if kind.isInteriorWarp {
                row["control"] = "same boundary as identity; interior warp is outside boundary-only correction"
            }
            let planar = try flattener.flattenPlanar(
                fixture.image, boundary: fixture.boundary.cornersOnly)
            outputs.append(("planar-only-baseline", planar))
            row["planarOnly"] = scoreJSON(try metrics(planar, fixture.reference))
            try attachJSON(row, name: "\(kind.rawValue)-geometry-metrics.json")
            try attachFixture(fixture, outputs: outputs)
            try emit(row, prefix: "SYNTHETIC_GEOMETRY")
            switch kind {
            case .keystone:
                for error in maskMetric.landmarkErrors {
                    XCTAssertLessThan(try XCTUnwrap(error), 2, "Mask-traced planar keystone")
                }
            case .sideCurl, .verticalCurl:
                XCTAssertLessThan(knownBoundaryMetric.mae, kind == .sideCurl ? 0.030 : 0.034)
                for error in knownBoundaryMetric.landmarkErrors {
                    XCTAssertLessThan(try XCTUnwrap(error), 1, "Known-boundary \(kind.rawValue)")
                }
            default:
                break
            }
        }
    }

    func testSyntheticAutomaticRouteDiagnostics() throws {
        let detector = DocumentDetector()
        var rows = [[String: Any]]()
        for kind in WarpKind.allCases {
            let fixture = try Fixture.make(kind)
            var row: [String: Any] = [
                "case": kind.rawValue,
                "route": "DocumentDetector.detectAndCorrect",
                "coordinateConvention": "top-left image edge origin; pixel centers at (i+0.5,j+0.5)"
            ]
            let result: UIImage
            do {
                result = try detector.detectAndCorrect(
                    UIImage(cgImage: fixture.image, scale: 1, orientation: .up))
            } catch {
                let nsError = error as NSError
                row["status"] = "route-error"
                row["error"] = [
                    "enum": String(reflecting: error), "type": String(reflecting: type(of: error)),
                    "domain": nsError.domain, "code": nsError.code,
                    "localizedDescription": error.localizedDescription
                ]
                rows.append(row)
                continue
            }
            guard let image = result.cgImage else {
                row["status"] = "no-cgimage"
                rows.append(row)
                continue
            }
            row["status"] = "route-completed"
            row["geometry"] = scoreJSON(try metrics(image, fixture.reference))
            try attachImage(image, name: "\(kind.rawValue)-automatic-route.png")
            rows.append(row)
        }
        try attachJSON(rows, name: "automatic-route-results.json")
        for row in rows { try emit(row, prefix: "SYNTHETIC_ROUTE") }
    }

    func testMetricSanityControls() throws {
        let size = CGSize(width: 48, height: 48)
        let white = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
        let black = try XCTUnwrap(TestImageFactory.solid(.black, size: size).cgImage)
        let whiteScore = try metrics(white, white)
        let blackScore = try metrics(black, black)
        let oppositeScore = try metrics(white, black)
        XCTAssertEqual(whiteScore.inkF1, 1)
        XCTAssertEqual(blackScore.inkF1, 1)
        XCTAssertEqual(oppositeScore.inkF1, 0)
        for score in [whiteScore, blackScore, oppositeScore] {
            XCTAssertTrue((0...1).contains(score.inkF1))
        }

        let stretched = try XCTUnwrap(
            TestImageFactory.solid(.white, size: CGSize(width: 64, height: 48)).cgImage)
        let sizeMismatch = try metrics(stretched, white)
        XCTAssertEqual(sizeMismatch.widthError, 16)
        XCTAssertEqual(sizeMismatch.heightError, 0)
        XCTAssertEqual(sizeMismatch.aspectError, 1.0 / 3.0, accuracy: 0.001)
    }

    func testAsymmetricMarkersConfirmPixelCenterOrigin() throws {
        let fixture = try Fixture.make(.identity)
        let analytic = try analyticReconstruction(fixture)
        let planar = try flattener.flattenPlanar(fixture.image, boundary: fixture.boundary)
        for (image, offset) in [(fixture.image, 90.0), (fixture.reference, 0.0),
                                (analytic, 0.0), (planar, 0.0)] {
            let centers = Self.markerCenters(try PageBitmap(image))
            for (index, marker) in Self.markers.enumerated() {
                let center = try XCTUnwrap(centers[index])
                XCTAssertEqual(Double(center.x), marker.x + offset, accuracy: 0.01)
                XCTAssertEqual(Double(center.y), marker.y + offset, accuracy: 0.01)
            }
        }
    }

    private static let markers: [(x: Double, y: Double, rgb: (UInt8, UInt8, UInt8))] = [
        (125, 122, (255, 0, 255)), (489, 357, (0, 255, 255)), (245, 603, (255, 255, 0))
    ]

    private static func markerCenters(_ bitmap: PageBitmap) -> [CGPoint?] {
        var sums = Array(repeating: (x: 0.0, y: 0.0, count: 0.0), count: markers.count)
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                let p = (y * bitmap.width + x) * 4
                let r = bitmap.data[p], g = bitmap.data[p + 1], b = bitmap.data[p + 2]
                let index: Int
                if r > 220, g < 35, b > 220 { index = 0 }
                else if r < 35, g > 220, b > 220 { index = 1 }
                else if r > 220, g > 220, b < 35 { index = 2 }
                else { continue }
                sums[index].x += Double(x) + 0.5
                sums[index].y += Double(y) + 0.5
                sums[index].count += 1
            }
        }
        return sums.map { $0.count > 0 ? CGPoint(x: $0.x / $0.count, y: $0.y / $0.count) : nil }
    }

    private enum WarpKind: String, CaseIterable {
        case identity, keystone, sideCurl, verticalCurl, interiorWave
        var isCurvedBoundary: Bool { self == .sideCurl || self == .verticalCurl }
        var isInteriorWarp: Bool { self == .interiorWave }
        var formula: String {
            switch self {
            case .identity: return "x=x0+W*u; y=y0+H*v"
            case .keystone: return "h=120/580; x=x0+(700*u+(60+30*h)*v-30)/(1+h*v); y=y0+dy*(1+h)*v/(1+h*v); dy=sqrt(800^2-60^2)"
            case .sideCurl: return "x=x0+W*u+42*sin(pi*v)*(1-2*u); y=y0+H*v"
            case .verticalCurl: return "x=x0+W*u; y=y0+H*v+40*sin(pi*u)*(1-2*v)"
            case .interiorWave: return "x=x0+W*u+24*sin(pi*u)*sin(pi*v); y=y0+H*v"
            }
        }
    }

    private struct Fixture {
        let kind: WarpKind
        let image: CGImage
        let reference: CGImage
        let boundary: DocumentBoundary
        let mask: SegmentationMask
        let corners: [CGPoint]
        let size: CGSize
        let width: Double
        let height: Double
        let x0 = 90.0
        let y0 = 90.0

        static func make(_ kind: WarpKind) throws -> Fixture {
            let width = 640
            let height = 800, canvasW = 820, canvasH = 980
            let maskW = 205, maskH = 245
            let reference = SyntheticGeometryComparisonTests.makeReference(width: width, height: height)
            let sourceTexture = try PageBitmap(try XCTUnwrap(reference.cgImage))
            var rgba = [UInt8](repeating: 0, count: canvasW * canvasH * 4)
            var maskValues = [Float](repeating: 0, count: maskW * maskH)
            for y in 0..<canvasH {
                for x in 0..<canvasW {
                    let sx = Double(x) + 0.5, sy = Double(y) + 0.5
                    let (u, v) = inverse(kind, x: sx - 90, y: sy - 90,
                                         width: Double(width), height: Double(height))
                    let offset = (y * canvasW + x) * 4
                    if u >= 0, u <= 1, v >= 0, v <= 1 {
                        let sample = SyntheticGeometryComparisonTests.rgb(
                            sourceTexture, x: u * Double(width) - 0.5,
                            y: v * Double(height) - 0.5)
                        rgba[offset] = sample.0; rgba[offset + 1] = sample.1
                        rgba[offset + 2] = sample.2; rgba[offset + 3] = 255
                    } else {
                        rgba[offset] = 54; rgba[offset + 1] = 61
                        rgba[offset + 2] = 67; rgba[offset + 3] = 255
                    }
                }
            }
            guard let context = CGContext(data: &rgba, width: canvasW, height: canvasH,
                bitsPerComponent: 8, bytesPerRow: canvasW * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let image = context.makeImage() else { throw DocumentDetectionError.renderFailed }
            for y in 0..<maskH {
                for x in 0..<maskW {
                    let sx = (Double(x) + 0.5) * Double(canvasW) / Double(maskW) - 90
                    let sy = (Double(y) + 0.5) * Double(canvasH) / Double(maskH) - 90
                    let (u, v) = inverse(kind, x: sx, y: sy,
                                         width: Double(width), height: Double(height))
                    if u >= 0, u <= 1, v >= 0, v <= 1 {
                        maskValues[y * maskW + x] = 1
                    }
                }
            }
            let n = kind.isCurvedBoundary ? 65 : 2
            func edge(_ side: Int) -> [CGPoint] {
                (0..<n).map { i in
                    let t = Double(i) / Double(n - 1)
                    let u = side == 0 || side == 2 ? t : (side == 1 ? 1 : 0)
                    let v = side == 1 || side == 3 ? t : (side == 2 ? 1 : 0)
                    let p = forward(kind, u: u, v: v, width: Double(width), height: Double(height))
                    return CGPoint(x: CGFloat(p.0 / Double(canvasW)),
                                   y: CGFloat(1 - p.1 / Double(canvasH)))
                }
            }
            let boundary = DocumentBoundary(top: edge(0), right: edge(1), bottom: edge(2), left: edge(3))
            let corners = boundary.corners.map {
                CGPoint(x: CGFloat(Double($0.x) * Double(canvasW)),
                        y: CGFloat((1 - Double($0.y)) * Double(canvasH)))
            }
            return Fixture(kind: kind, image: image, reference: try XCTUnwrap(reference.cgImage),
                boundary: boundary,
                mask: SegmentationMask(width: maskW, height: maskH, values: maskValues,
                                       imageWidth: canvasW, imageHeight: canvasH),
                corners: corners,
                size: CGSize(width: CGFloat(canvasW), height: CGFloat(canvasH)),
                width: Double(width), height: Double(height))
        }

        func forward(u: Double, v: Double) -> (Double, Double) {
            Self.forward(kind, u: u, v: v, width: width, height: height)
        }

        private static func forward(_ kind: WarpKind, u: Double, v: Double,
                                    width: Double, height: Double) -> (Double, Double) {
            let x0 = 90.0, y0 = 90.0
            switch kind {
            case .identity: return (x0 + width * u, y0 + height * v)
            case .sideCurl:
                return (x0 + width * u + 42 * sin(.pi * v) * (1 - 2 * u), y0 + height * v)
            case .verticalCurl:
                return (x0 + width * u, y0 + height * v + 40 * sin(.pi * u) * (1 - 2 * v))
            case .interiorWave:
                return (x0 + width * u + 24 * sin(.pi * u) * sin(.pi * v), y0 + height * v)
            case .keystone:
                let h = 120.0 / 580.0, top = 700.0, sideShift = 60.0
                let dy = sqrt(800 * 800 - sideShift * sideShift)
                return (x0 + (top * u + (sideShift + 30 * h) * v - 30) / (1 + h * v),
                        y0 + dy * (1 + h) * v / (1 + h * v))
            }
        }

        static func inverse(_ kind: WarpKind, x: Double, y: Double,
                            width: Double, height: Double) -> (Double, Double) {
            switch kind {
            case .identity: return (x / width, y / height)
            case .sideCurl:
                let v = y / height, a = 42 * sin(.pi * v)
                return ((x - a) / (width - 2 * a), v)
            case .verticalCurl:
                let u = x / width, a = 40 * sin(.pi * u)
                return (u, (y - a) / (height - 2 * a))
            case .interiorWave:
                let v = y / height
                guard x >= 0, x <= width else { return (x < 0 ? -1 : 2, v) }
                var low = 0.0, high = 1.0
                for _ in 0..<36 {
                    let mid = (low + high) / 2
                    let mapped = width * mid + 24 * sin(.pi * mid) * sin(.pi * v)
                    if mapped < x { low = mid } else { high = mid }
                }
                return ((low + high) / 2, v)
            case .keystone:
                let h = 120.0 / 580.0, top = 700.0
                let dy = sqrt(Double(800 * 800 - 60 * 60))
                let q = y, v = q / (dy * (1 + h) - h * q)
                return ((x * (1 + h * v) - (60 + 30 * h) * v + 30) / top, v)
            }
        }
    }
    private struct Score {
        let mae: Double
        let inkF1: Double
        let width: Int
        let height: Int
        let widthError: Int
        let heightError: Int
        let aspectError: Double
        let landmarkErrors: [Double?]
    }

    private func metrics(_ image: CGImage, _ reference: CGImage) throws -> Score {
        let a = try PageBitmap(image), b = try PageBitmap(reference)
        var error = 0.0, samples = 0, refInk = 0, hit = 0, outInk = 0
        for y in 0..<max(a.height, b.height) {
            for x in 0..<max(a.width, b.width) {
                let inReference = x < b.width && y < b.height
                guard inReference || (x < a.width && y < a.height) else { continue }
                let c = x < a.width && y < a.height ? Self.rgb(a, x: Double(x), y: Double(y)) : (255, 255, 255)
                let r = inReference ? Self.rgb(b, x: Double(x), y: Double(y)) : (255, 255, 255)
                let luma = 0.299 * Double(c.0) + 0.587 * Double(c.1) + 0.114 * Double(c.2)
                let target = 0.299 * Double(r.0) + 0.587 * Double(r.1) + 0.114 * Double(r.2)
                error += (abs(Double(c.0) - Double(r.0)) + abs(Double(c.1) - Double(r.1))
                        + abs(Double(c.2) - Double(r.2))) / (3 * 255)
                let targetIsInk = target < 100
                let outputIsInk = luma < 100
                if targetIsInk { refInk += 1 }
                if outputIsInk { outInk += 1 }
                if targetIsInk && outputIsInk { hit += 1 }
                samples += 1
            }
        }
        let precision = outInk == 0 ? (refInk == 0 ? 1.0 : 0.0) : Double(hit) / Double(outInk)
        let recall = refInk == 0 ? (outInk == 0 ? 1.0 : 0.0) : Double(hit) / Double(refInk)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        let aspectError = abs(Double(image.width) / Double(image.height)
                            / (Double(reference.width) / Double(reference.height)) - 1)
        let scale = Double(b.width) / Double(a.width)
        let landmarkErrors: [Double?] = zip(Self.markerCenters(a), Self.markerCenters(b)).map { pair in
            guard let output = pair.0, let expected = pair.1 else { return nil }
            return hypot(Double(output.x) * scale - Double(expected.x),
                         Double(output.y) * scale - Double(expected.y))
        }
        return Score(mae: error / Double(samples), inkF1: f1,
                     width: image.width, height: image.height,
                     widthError: image.width - reference.width,
                     heightError: image.height - reference.height, aspectError: aspectError,
                     landmarkErrors: landmarkErrors)
    }

    private func analyticReconstruction(_ fixture: Fixture) throws -> CGImage {
        let source = try PageBitmap(fixture.image)
        let reference = try PageBitmap(fixture.reference)
        var rgba = [UInt8](repeating: 255, count: reference.width * reference.height * 4)
        for y in 0..<reference.height {
            for x in 0..<reference.width {
                let u = (Double(x) + 0.5) / Double(reference.width)
                let v = (Double(y) + 0.5) / Double(reference.height)
                let sourcePoint = fixture.forward(u: u, v: v)
                let color = Self.rgb(source, x: sourcePoint.0 - 0.5, y: sourcePoint.1 - 0.5)
                let offset = (y * reference.width + x) * 4
                rgba[offset] = color.0; rgba[offset + 1] = color.1
                rgba[offset + 2] = color.2; rgba[offset + 3] = 255
            }
        }
        guard let context = CGContext(data: &rgba, width: reference.width, height: reference.height,
            bitsPerComponent: 8, bytesPerRow: reference.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage() else { throw DocumentDetectionError.renderFailed }
        return image
    }

    private func attachFixture(_ fixture: Fixture, outputs: [(String, CGImage)]) throws {
        try attachImage(fixture.image, name: "\(fixture.kind.rawValue)-input.png")
        try attachImage(fixture.reference, name: "\(fixture.kind.rawValue)-flat-reference.png")
        try attachImage(try maskImage(fixture.mask), name: "\(fixture.kind.rawValue)-mask.png")
        let edges: [[String: Any]] = [
            ["name": "top", "points": fixture.boundary.top.map { [Double($0.x), Double($0.y)] }],
            ["name": "right", "points": fixture.boundary.right.map { [Double($0.x), Double($0.y)] }],
            ["name": "bottom", "points": fixture.boundary.bottom.map { [Double($0.x), Double($0.y)] }],
            ["name": "left", "points": fixture.boundary.left.map { [Double($0.x), Double($0.y)] }]
        ]
        let groundTruth: [String: Any] = [
            "case": fixture.kind.rawValue,
            "coordinateConvention": "image edge coordinates; top-left origin; pixel centers at (i+0.5,j+0.5); DocumentBoundary points normalized with bottom-left origin",
            "inputSize": [Int(fixture.size.width), Int(fixture.size.height)],
            "referenceSize": [fixture.reference.width, fixture.reference.height],
            "landmarksTopLeftPx": Self.markers.map { [$0.x, $0.y] },
            "maskSize": [fixture.mask.width, fixture.mask.height],
            "maskThreshold": 0.5,
            "mapping": [
                "name": fixture.kind.rawValue,
                "forwardFormula": fixture.kind.formula,
                "translationOriginTopLeftPx": [90, 90],
                "flatPageSizePx": [Int(fixture.width), Int(fixture.height)],
                "canvasSizePx": [Int(fixture.size.width), Int(fixture.size.height)],
                "sideCurlAmplitudePx": 42,
                "verticalCurlAmplitudePx": 40,
                "interiorWaveAmplitudePx": 24,
                "keystoneTopWidthPx": 700,
                "keystoneBottomWidthPx": 580,
                "keystoneFactor": 120.0 / 580.0,
                "keystoneSideShiftPx": 60,
                "keystoneVerticalOffsetPx": 60
            ],
            "maskSource": "generated binary ground truth; not a Vision mask or confidence sample",
            "boundary": edges
        ]
        try attachJSON(groundTruth, name: "\(fixture.kind.rawValue)-ground-truth.json")
        for (name, image) in outputs {
            try attachImage(image, name: "\(fixture.kind.rawValue)-\(name).png")
        }
    }

    private func maskImage(_ mask: SegmentationMask) throws -> CGImage {
        var rgba = [UInt8](repeating: 0, count: mask.width * mask.height * 4)
        for index in mask.values.indices {
            let value = UInt8((min(max(mask.values[index], 0), 1) * 255).rounded())
            let offset = index * 4
            rgba[offset] = value; rgba[offset + 1] = value
            rgba[offset + 2] = value; rgba[offset + 3] = 255
        }
        guard let context = CGContext(data: &rgba, width: mask.width, height: mask.height,
            bitsPerComponent: 8, bytesPerRow: mask.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let image = context.makeImage() else { throw DocumentDetectionError.renderFailed }
        return image
    }

    private func attachImage(_ image: CGImage, name: String) throws {
        guard let data = UIImage(cgImage: image).pngData() else {
            throw DocumentDetectionError.renderFailed
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attachJSON(_ value: Any, name: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func scoreJSON(_ score: Score) -> [String: Any] {
        ["rgbMAE": score.mae, "inkF1": score.inkF1,
         "outputSizePx": [score.width, score.height],
         "widthErrorPx": score.widthError, "heightErrorPx": score.heightError,
         "aspectError": score.aspectError,
         "landmarkErrorAtReferenceWidthPx": score.landmarkErrors.map { error -> Any in
             if let error { return error }
             return NSNull()
         }]
    }

    private func emit(_ value: [String: Any], prefix: String) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        print("\(prefix) \(String(decoding: data, as: UTF8.self))")
    }

    private func boundaryError(_ a: DocumentBoundary, _ b: DocumentBoundary, _ size: CGSize) -> Double {
        func pixels(_ points: [CGPoint]) -> [(Double, Double)] {
            points.map { (Double($0.x) * Double(size.width),
                          (1 - Double($0.y)) * Double(size.height)) }
        }
        func distance(_ point: (Double, Double), to line: [(Double, Double)]) -> Double {
            guard line.count >= 2 else { return .infinity }
            return (0..<(line.count - 1)).map { index in
                let start = line[index], end = line[index + 1]
                let dx = end.0 - start.0, dy = end.1 - start.1
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared == 0 ? 0 : min(max(
                    ((point.0 - start.0) * dx + (point.1 - start.1) * dy) / lengthSquared, 0), 1)
                return hypot(point.0 - (start.0 + t * dx), point.1 - (start.1 + t * dy))
            }.min() ?? .infinity
        }
        let lhs = [a.top, a.right, a.bottom, a.left].map(pixels)
        let rhs = [b.top, b.right, b.bottom, b.left].map(pixels)
        var distances = [Double]()
        for index in 0..<4 {
            distances += lhs[index].map { distance($0, to: rhs[index]) }
            distances += rhs[index].map { distance($0, to: lhs[index]) }
        }
        return distances.reduce(0, +) / Double(distances.count)
    }

    private func assertInverseRoundTrip(_ f: Fixture) {
        for u in stride(from: 0.1, through: 0.9, by: 0.2) {
            for v in stride(from: 0.1, through: 0.9, by: 0.2) {
                let p = f.forward(u: u, v: v)
                let inverse = Fixture.inverse(f.kind, x: p.0 - f.x0, y: p.1 - f.y0,
                                               width: f.width, height: f.height)
                XCTAssertEqual(inverse.0, u, accuracy: 1e-8)
                XCTAssertEqual(inverse.1, v, accuracy: 1e-8)
            }
        }
    }

    private static func makeReference(width: Int, height: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)), format: format).image { r in
            UIColor.white.setFill()
            r.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            let c = r.cgContext
            c.setFillColor(UIColor.black.cgColor)
            for (row, y) in [70, 105, 165, 205, 330, 375, 520, 565, 680, 735].enumerated() {
                var x = 42
                for col in 0..<14 {
                    let w = 8 + ((row * 13 + col * 17) % 26)
                    c.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(w),
                                  height: CGFloat(col % 4 == 0 ? 3 : 2)))
                    x += w + 7
                    if x > width - 40 { break }
                }
            }
            c.setStrokeColor(UIColor.darkGray.cgColor); c.setLineWidth(1)
            for y in [150, 310, 500, 650] {
                c.move(to: CGPoint(x: 35, y: CGFloat(y)))
                c.addLine(to: CGPoint(x: 605, y: CGFloat(y)))
                c.strokePath()
            }
            UIColor.systemPink.setFill(); c.fill(CGRect(x: 40, y: 225, width: 210, height: 58))
            c.setStrokeColor(UIColor.systemRed.cgColor); c.setLineWidth(4)
            c.strokeEllipse(in: CGRect(x: 455, y: 620, width: 110, height: 110))
            UIColor.systemBlue.setStroke(); c.setLineWidth(3)
            c.move(to: CGPoint(x: 70, y: 420)); c.addLine(to: CGPoint(x: 180, y: 450))
            c.addLine(to: CGPoint(x: 285, y: 425)); c.addLine(to: CGPoint(x: 390, y: 470)); c.strokePath()
            c.setStrokeColor(UIColor.systemGreen.cgColor); c.setLineWidth(2)
            c.move(to: CGPoint(x: 100, y: 780)); c.addLine(to: CGPoint(x: 240, y: 755))
            c.addLine(to: CGPoint(x: 360, y: 785)); c.strokePath()
            for marker in markers {
                c.setFillColor(red: CGFloat(marker.rgb.0) / 255, green: CGFloat(marker.rgb.1) / 255,
                               blue: CGFloat(marker.rgb.2) / 255, alpha: 1)
                c.fill(CGRect(x: marker.x - 5, y: marker.y - 5, width: 10, height: 10))
            }
        }
    }

    private static func rgb(_ b: PageBitmap, x: Double, y: Double) -> (UInt8, UInt8, UInt8) {
        let x0 = min(max(Int(x.rounded(.down)), 0), b.width - 2)
        let y0 = min(max(Int(y.rounded(.down)), 0), b.height - 2)
        let fx = min(max(x - Double(x0), 0), 1), fy = min(max(y - Double(y0), 0), 1)
        func channel(_ c: Int) -> UInt8 {
            let p = (y0 * b.width + x0) * 4 + c
            let a = Double(b.data[p]), q = Double(b.data[p + 4])
            let r = Double(b.data[p + b.width * 4]), s = Double(b.data[p + b.width * 4 + 4])
            return UInt8((((a * (1 - fx) + q * fx) * (1 - fy)
                         + (r * (1 - fx) + s * fx) * fy)).rounded())
        }
        return (channel(0), channel(1), channel(2))
    }
}
