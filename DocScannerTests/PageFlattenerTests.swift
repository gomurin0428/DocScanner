import XCTest
import CoreGraphics
import Foundation
import UIKit
@testable import DocScanner

/// PageFlattener（マスク輪郭追跡 + Coons パッチ矩形化）のテスト。ML には依存しない。
final class PageFlattenerTests: XCTestCase {

    /// 対象フラットナ。
    private let flattener = PageFlattener()

    /// プレビューでなぞった湾曲輪郭を保存し、解像度が違う写真にも同じ四辺を使う。
    func testSavedCurvedBoundaryIsReusedAtPhotoResolution() throws {
        let size = CGSize(width: 1500, height: 2000)
        let path = curvedPagePath()
        let photo = renderPage(path: path, size: size)
        var scale = CGAffineTransform(scaleX: 0.5, y: 0.5)
        let previewPath = try XCTUnwrap(path.copy(using: &scale))
        let previewSize = CGSize(width: 750, height: 1000)
        let preview = renderPage(path: previewPath, size: previewSize)
        let boundary = try flattener.traceBoundary(preview, corners: [
            CGPoint(x: 100, y: 150), CGPoint(x: 650, y: 175),
            CGPoint(x: 640, y: 875), CGPoint(x: 115, y: 850)
        ], mask: makeMask(path: previewPath, size: previewSize))
        XCTAssertTrue(boundary.isValid)
        XCTAssertEqual(boundary.top.count, 65)
        let straightMidpoint = (boundary.top[0].y + boundary.top[64].y) / 2
        XCTAssertGreaterThan(abs(boundary.top[32].y - straightMidpoint), 0.004)
        let output = try flattener.flatten(photo, boundary: boundary)
        XCTAssertGreaterThan(output.width, 1000)
        XCTAssertGreaterThan(output.height, 1300)
        let result = UIImage(cgImage: output)
        for x in stride(from: 10, to: output.width - 10, by: 100) {
            let color = try XCTUnwrap(TestImageFactory.pixelColor(of: result, x: x, y: 10))
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            XCTAssertGreaterThan((red + green + blue) / 3, 0.8)
        }
    }

    /// 各テストの前処理。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: テストタイムアウトを 60 秒に設定する
    override func setUp() {
        super.setUp()
        executionTimeAllowance = 60
    }

    /// ホモグラフィが四隅を矩形の角へ写し、逆変換で往復できることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 台形 4 点から homography/逆行列を求め、写像先と往復誤差を 1e-6 で検査する
    func testHomographyMapsCornersAndRoundTrips() throws {
        let src = [
            PagePoint(x: 100, y: 50), PagePoint(x: 900, y: 80),
            PagePoint(x: 950, y: 1400), PagePoint(x: 80, y: 1350)
        ]
        let dst = [
            PagePoint(x: 0, y: 0), PagePoint(x: 800, y: 0),
            PagePoint(x: 800, y: 1200), PagePoint(x: 0, y: 1200)
        ]
        let h = try PageGeometry.homography(from: src, to: dst)
        for i in 0..<4 {
            let mapped = PageGeometry.apply(h, to: src[i])
            XCTAssertEqual(mapped.x, dst[i].x, accuracy: 1e-6)
            XCTAssertEqual(mapped.y, dst[i].y, accuracy: 1e-6)
        }
        let inv = try PageGeometry.homography(from: dst, to: src)
        for i in 0..<4 {
            let round = PageGeometry.apply(inv, to: PageGeometry.apply(h, to: src[i]))
            XCTAssertEqual(round.x, src[i].x, accuracy: 1e-6)
            XCTAssertEqual(round.y, src[i].y, accuracy: 1e-6)
        }
    }

    /// 曲線辺を持つページで、背景が残らず出力サイズが弧長相当になることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 上辺・下辺 ±40px、左辺 30px に湾曲した白ページ（暗い背景 + 黒バー）を
    ///   1500x2000 で描き、同形状の 150x200 マスクと四隅で flatten。
    ///   出力外周 6px の平均輝度 > 200、サイズが矩形弧長の ±5% 以内を検査する
    func testCurvedPageFlattensToFilledRectangle() throws {
        let size = CGSize(width: 1500, height: 2000)
        let path = curvedPagePath()
        let image = renderPage(path: path, size: size)
        let mask = makeMask(path: path, size: size)
        let corners: [CGPoint] = [
            CGPoint(x: 200, y: 300), CGPoint(x: 1300, y: 350),
            CGPoint(x: 1280, y: 1750), CGPoint(x: 230, y: 1700)
        ]
        let output = try flattener.flatten(image, corners: corners, mask: mask)
        let result = UIImage(cgImage: output)

        // 外周 6px バンドに背景（暗灰）が残っていないこと
        for y in [0, 2, 5, output.height - 6, output.height - 3, output.height - 1] {
            for x in stride(from: 0, to: output.width, by: 60) {
                let color = try XCTUnwrap(
                    TestImageFactory.pixelColor(of: result, x: x, y: y))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThan((r + g + b) / 3, 200.0 / 255.0,
                                     "border pixel (\(x),\(y)) = \(r)")
            }
        }
        for x in [0, 5, output.width - 6, output.width - 1] {
            for y in stride(from: 0, to: output.height, by: 80) {
                let color = try XCTUnwrap(
                    TestImageFactory.pixelColor(of: result, x: x, y: y))
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                color.getRed(&r, green: &g, blue: &b, alpha: &a)
                XCTAssertGreaterThan((r + g + b) / 3, 200.0 / 255.0,
                                     "border pixel (\(x),\(y)) = \(r)")
            }
        }

        // 出力サイズは四辺の平均弧長（矩形化後）の ±5% 以内
        let topLen = PagePoint(x: 1300, y: 350) - PagePoint(x: 200, y: 300)
        let bottomLen = PagePoint(x: 1280, y: 1750) - PagePoint(x: 230, y: 1700)
        let leftLen = PagePoint(x: 230, y: 1700) - PagePoint(x: 200, y: 300)
        let rightLen = PagePoint(x: 1280, y: 1750) - PagePoint(x: 1300, y: 350)
        let expectedW = (topLen.length + bottomLen.length) / 2
        let expectedH = (leftLen.length + rightLen.length) / 2
        XCTAssertEqual(Double(output.width), expectedW, accuracy: expectedW * 0.05)
        XCTAssertEqual(Double(output.height), expectedH, accuracy: expectedH * 0.05)
    }

    /// 直線辺の矩形ページでは出力がほぼそのままの切り出しになることを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 軸平行な矩形ページ + 同形状マスクで flatten し、
    ///   出力サイズがページ辺長の ±2% 以内であることを検査する
    func testStraightRectangleOutputsPageCrop() throws {
        let size = CGSize(width: 1500, height: 2000)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 200, y: 300))
        path.addLine(to: CGPoint(x: 1300, y: 300))
        path.addLine(to: CGPoint(x: 1300, y: 1700))
        path.addLine(to: CGPoint(x: 200, y: 1700))
        path.closeSubpath()
        let image = renderPage(path: path, size: size)
        let mask = makeMask(path: path, size: size)
        let corners: [CGPoint] = [
            CGPoint(x: 200, y: 300), CGPoint(x: 1300, y: 300),
            CGPoint(x: 1300, y: 1700), CGPoint(x: 200, y: 1700)
        ]
        let output = try flattener.flatten(image, corners: corners, mask: mask)
        XCTAssertEqual(Double(output.width), 1100, accuracy: 1100 * 0.02)
        XCTAssertEqual(Double(output.height), 1400, accuracy: 1400 * 0.02)
    }

    func testCornersOnlyPlanarFlatteningKeepsEqualGridSpacingInSkewedTrapezoid() throws {
        let size = CGSize(width: 1000, height: 1200)
        let sourceCorners = [
            PagePoint(x: 180, y: 100), PagePoint(x: 850, y: 140),
            PagePoint(x: 960, y: 1080), PagePoint(x: 80, y: 900)
        ]
        let flatCorners = [
            PagePoint(x: 0, y: 0), PagePoint(x: 800, y: 0),
            PagePoint(x: 800, y: 1000), PagePoint(x: 0, y: 1000)
        ]
        let projection = try PageGeometry.homography(from: flatCorners, to: sourceCorners)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let canvas = context.cgContext
            canvas.setStrokeColor(UIColor.black.cgColor)
            canvas.setLineWidth(3)
            for index in 1..<10 {
                let position = Double(index) / 10
                for sample in 0...100 {
                    let point = PageGeometry.apply(projection, to: PagePoint(
                        x: 800 * Double(sample) / 100, y: 1000 * position))
                    if sample == 0 { canvas.move(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
                    else { canvas.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
                }
                canvas.strokePath()
                for sample in 0...100 {
                    let point = PageGeometry.apply(projection, to: PagePoint(
                        x: 800 * position, y: 1000 * Double(sample) / 100))
                    if sample == 0 { canvas.move(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
                    else { canvas.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))) }
                }
                canvas.strokePath()
            }
        }
        let cgImage = try XCTUnwrap(image.cgImage)
        func normalizedEdge(_ start: PagePoint, _ end: PagePoint) -> [CGPoint] {
            (0...32).map { index in
                let t = Double(index) / 32
                let point = start * (1 - t) + end * t
                return CGPoint(x: point.x / Double(size.width),
                               y: 1 - point.y / Double(size.height))
            }
        }
        let sampledBoundary = DocumentBoundary(
            top: normalizedEdge(sourceCorners[0], sourceCorners[1]),
            right: normalizedEdge(sourceCorners[1], sourceCorners[2]),
            bottom: normalizedEdge(sourceCorners[3], sourceCorners[2]),
            left: normalizedEdge(sourceCorners[0], sourceCorners[3]))
        XCTAssertTrue(sampledBoundary.hasStraightEdges(in: size))

        let output = try flattener.flattenPlanar(cgImage, boundary: sampledBoundary)
        let pixels = try PageBitmap(output)
        let x = Double(output.width) * 0.45
        var lineCenters = [Double](), runStart: Int?
        for y in 0..<output.height {
            if pixels.luminance(atX: x, y: Double(y)) < 100 {
                if runStart == nil { runStart = y }
            } else if let start = runStart {
                lineCenters.append(Double(start + y - 1) / 2)
                runStart = nil
            }
        }
        if let start = runStart { lineCenters.append(Double(start + output.height - 1) / 2) }
        guard lineCenters.count == 9 else {
            XCTFail("expected 9 horizontal grid lines, found \(lineCenters.count)")
            return
        }
        let gaps = zip(lineCenters, lineCenters.dropFirst()).map { $1 - $0 }
        let meanGap = gaps.reduce(0, +) / Double(gaps.count)
        for gap in gaps {
            XCTAssertEqual(gap, meanGap, accuracy: meanGap * 0.05)
        }
    }

    func testRefineBoundaryDoesNotInventSamplesWithoutAnObservedEdge() throws {
        let size = CGSize(width: 800, height: 1000)
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
        let boundary = DocumentBoundary(corners: [CGPoint(x: 0.1, y: 0.9), CGPoint(x: 0.9, y: 0.9),
                                                  CGPoint(x: 0.9, y: 0.1), CGPoint(x: 0.1, y: 0.1)])

        let refined = try flattener.refineBoundary(image, boundary: boundary)

        XCTAssertEqual(refined.top.count, 2)
        XCTAssertFalse(refined.hasStraightEdges(in: size))
        XCTAssertNoThrow(try flattener.flattenPlanar(image, boundary: refined))
    }

    func testRefineBoundaryDeclinesAcuteCornerShiftBeyondLocalRange() throws {
        let size = CGSize(width: 1000, height: 1000)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let actual = [PagePoint(x: 100, y: 100), PagePoint(x: 800, y: 500),
                      PagePoint(x: 800, y: 900), PagePoint(x: 700, y: 900)]
        let candidate = [PagePoint(x: 144.39, y: 139.19), PagePoint(x: 788, y: 506.96),
                         PagePoint(x: 788, y: 888), PagePoint(x: 706, y: 888)]
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.1, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let path = context.cgContext
            path.beginPath()
            path.move(to: CGPoint(x: CGFloat(actual[0].x), y: CGFloat(actual[0].y)))
            for point in actual.dropFirst() {
                path.addLine(to: CGPoint(x: CGFloat(point.x), y: CGFloat(point.y)))
            }
            path.closePath()
            UIColor.white.setFill()
            path.fillPath()
        }
        func normalized(_ point: PagePoint) -> CGPoint {
            CGPoint(x: CGFloat(point.x / Double(size.width)),
                    y: CGFloat(1 - point.y / Double(size.height)))
        }
        let boundary = DocumentBoundary(corners: candidate.map(normalized))

        let refined = try flattener.refineBoundary(XCTUnwrap(image.cgImage), boundary: boundary)

        XCTAssertEqual(refined, boundary)
    }

    func testPhotoRecoveryFindsOuterPagePastClutterAndPrintedEdges() throws {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let actual = [CGPoint(x: 250, y: 40), CGPoint(x: 970, y: 65),
                      CGPoint(x: 920, y: 1350), CGPoint(x: 290, y: 1490)]
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.38, green: 0.34, blue: 0.29, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let canvas = context.cgContext
            for index in 0..<12 {
                canvas.setStrokeColor(UIColor(white: 0.25 + CGFloat(index % 4) * 0.04, alpha: 1).cgColor)
                canvas.setLineWidth(3)
                canvas.move(to: CGPoint(x: 0, y: CGFloat(index * 127)))
                canvas.addLine(to: CGPoint(x: size.width, y: CGFloat(index * 127 + 55)))
                canvas.strokePath()
            }
            let page = CGMutablePath()
            page.move(to: actual[0])
            for point in actual.dropFirst() { page.addLine(to: point) }
            page.closeSubpath()
            canvas.addPath(page)
            canvas.setFillColor(UIColor.white.cgColor)
            canvas.fillPath()
            canvas.setStrokeColor(UIColor(white: 0.12, alpha: 1).cgColor)
            canvas.setLineWidth(9)
            canvas.stroke(CGRect(x: 410, y: 420, width: 240, height: 340))
            canvas.setLineWidth(11)
            canvas.move(to: CGPoint(x: 315, y: 170))
            canvas.addLine(to: CGPoint(x: 315, y: 1380))
            canvas.strokePath()
        }
        let detected = DocumentBoundary(corners: [
            CGPoint(x: 238.0 / 1200, y: 1 - 32.0 / 1600), CGPoint(x: 984.0 / 1200, y: 1 - 59.0 / 1600),
            CGPoint(x: 940.0 / 1200, y: 1 - 1354.0 / 1600), CGPoint(x: 112.0 / 1200, y: 1 - 1509.0 / 1600)
        ])

        let recovered = try XCTUnwrap(flattener.recoverPhotoBoundary(XCTUnwrap(image.cgImage), boundary: detected))
        let points = recovered.corners.map { PagePoint(x: Double($0.x) * 1200, y: (1 - Double($0.y)) * 1600) }

        for (point, expected) in zip(points, actual) {
            XCTAssertLessThan((point - PagePoint(x: Double(expected.x), y: Double(expected.y))).length, 25)
        }
        XCTAssertGreaterThan(recovered.left.count, 16)
        XCTAssertTrue(recovered.hasStraightEdges(in: size))
    }

    func testPhotoRecoveryFindsDarkPaperOnLightBackground() throws {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let actual = [CGPoint(x: 250, y: 40), CGPoint(x: 970, y: 65),
                      CGPoint(x: 920, y: 1350), CGPoint(x: 290, y: 1490)]
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let page = CGMutablePath()
            page.move(to: actual[0])
            for point in actual.dropFirst() { page.addLine(to: point) }
            page.closeSubpath()
            context.cgContext.addPath(page)
            context.cgContext.setFillColor(UIColor(white: 0.2, alpha: 1).cgColor)
            context.cgContext.fillPath()
        }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / size.width, y: 1 - point.y / size.height)
        }
        let candidate = DocumentBoundary(corners: [
            normalized(CGPoint(x: 238, y: 32)), normalized(CGPoint(x: 984, y: 59)),
            normalized(CGPoint(x: 940, y: 1354)), normalized(CGPoint(x: 112, y: 1509))
        ])

        let recovered = try XCTUnwrap(flattener.recoverPhotoBoundary(XCTUnwrap(image.cgImage), boundary: candidate))
        let points = recovered.corners.map { PagePoint(x: Double($0.x) * 1200, y: (1 - Double($0.y)) * 1600) }

        for (point, expected) in zip(points, actual) {
            XCTAssertLessThan((point - PagePoint(x: Double(expected.x), y: Double(expected.y))).length, 25)
        }
        XCTAssertTrue(recovered.hasStraightEdges(in: size))
    }

    func testPhotoRecoveryPreservesPartialMeasuredCurve() throws {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let topLeft = CGPoint(x: 250, y: 40), topRight = CGPoint(x: 970, y: 65)
        let bottomRight = CGPoint(x: 920, y: 1350), bottomLeft = CGPoint(x: 290, y: 1490)
        let control1 = CGPoint(x: 975, y: 400), control2 = CGPoint(x: 925, y: 1000)
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.38, green: 0.34, blue: 0.29, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let page = context.cgContext
            page.beginPath()
            page.move(to: topLeft)
            page.addLine(to: topRight)
            page.addCurve(to: bottomRight, control1: control1, control2: control2)
            page.addLine(to: bottomLeft)
            page.closePath()
            page.setFillColor(UIColor.white.cgColor)
            page.fillPath()
        }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / size.width, y: 1 - point.y / size.height)
        }
        func curve(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(
                x: u * u * u * topRight.x + 3 * u * u * t * control1.x
                    + 3 * u * t * t * control2.x + t * t * t * bottomRight.x,
                y: u * u * u * topRight.y + 3 * u * u * t * control1.y
                    + 3 * u * t * t * control2.y + t * t * t * bottomRight.y
            )
        }
        let detected = DocumentBoundary(corners: [
            normalized(CGPoint(x: 238, y: 32)), normalized(CGPoint(x: 984, y: 59)),
            normalized(CGPoint(x: 940, y: 1354)), normalized(CGPoint(x: 112, y: 1509))
        ])
        let measured = DocumentBoundary(
            top: [normalized(topLeft), normalized(topRight)],
            right: (0...4).map { normalized(curve(CGFloat($0) / 4)) },
            bottom: [normalized(bottomLeft), normalized(bottomRight)],
            left: [normalized(topLeft), normalized(bottomLeft)]
        )
        XCTAssertTrue(measured.hasMeasuredCurvedEdges(in: size))

        let recovered = try XCTUnwrap(flattener.recoverPhotoBoundary(
            XCTUnwrap(image.cgImage), boundary: detected, preservingMeasuredEdges: measured))

        let measuredInterior = Array(measured.right.dropFirst().dropLast())
        let recoveredInterior = Array(recovered.right.dropFirst().dropLast())
        XCTAssertTrue(recoveredInterior.allSatisfy { measuredInterior.contains($0) })
        let start = try XCTUnwrap(recovered.right.first)
        let end = try XCTUnwrap(recovered.right.last)
        let dx = Double(end.x - start.x), dy = Double(end.y - start.y)
        let lengthSquared = dx * dx + dy * dy
        let positions = recovered.right.map { point in
            let x = Double(point.x - start.x), y = Double(point.y - start.y)
            return (x * dx + y * dy) / lengthSquared
        }
        XCTAssertTrue(positions.dropFirst().dropLast().allSatisfy { $0 > 0 && $0 < 1 })
        XCTAssertTrue(zip(positions, positions.dropFirst()).allSatisfy { $0.1 > $0.0 })
        XCTAssertGreaterThan(try XCTUnwrap(recovered.edgeMaximumDeviationPixels(in: size))[1], 3)
    }

    func testPhotoRecoveryRejectsEvidencePoorBoundary() throws {
        let size = CGSize(width: 600, height: 800)
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
        let boundary = DocumentBoundary(corners: [CGPoint(x: 0.2, y: 0.9), CGPoint(x: 0.8, y: 0.9),
                                                   CGPoint(x: 0.8, y: 0.1), CGPoint(x: 0.2, y: 0.1)])

        XCTAssertNil(try flattener.recoverPhotoBoundary(image, boundary: boundary))
    }

    func testPhotoRecoveryRetainsOneUnmeasuredEdgeWithoutInventingSamples() throws {
        let size = CGSize(width: 1200, height: 1600)
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
        let corners = [CGPoint(x: 150, y: 100), CGPoint(x: 650, y: 120),
                       CGPoint(x: 620, y: 650), CGPoint(x: 170, y: 630)]
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / size.width, y: 1 - point.y / size.height)
        }
        func edge(_ start: CGPoint, _ end: CGPoint) -> [CGPoint] {
            (0...4).map { index in
                let t = CGFloat(index) / 4
                return normalized(CGPoint(x: start.x * (1 - t) + end.x * t,
                                          y: start.y * (1 - t) + end.y * t))
            }
        }
        let candidate = DocumentBoundary(corners: corners.map(normalized))
        let local = DocumentBoundary(top: candidate.top,
                                     right: edge(corners[1], corners[2]),
                                     bottom: edge(corners[3], corners[2]),
                                     left: edge(corners[0], corners[3]))

        let recovered = try XCTUnwrap(flattener.recoverPhotoBoundary(
            image, boundary: candidate, preservingMeasuredEdges: local))

        XCTAssertEqual(recovered.top.count, 2)
        XCTAssertEqual(recovered.top, candidate.top)
        XCTAssertEqual(Array(recovered.right.dropFirst().dropLast()),
                       Array(local.right.dropFirst().dropLast()))
        XCTAssertEqual(Array(recovered.bottom.dropFirst().dropLast()),
                       Array(local.bottom.dropFirst().dropLast()))
        XCTAssertEqual(Array(recovered.left.dropFirst().dropLast()),
                       Array(local.left.dropFirst().dropLast()))
    }

    func testPhotoRecoveryRejectsLargeCornerShiftOnRetainedEdge() throws {
        let size = CGSize(width: 1200, height: 1600)
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
        let corners = [CGPoint(x: 150, y: 100), CGPoint(x: 650, y: 120),
                       CGPoint(x: 620, y: 650), CGPoint(x: 170, y: 630)]
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / size.width, y: 1 - point.y / size.height)
        }
        func edge(_ start: CGPoint, _ end: CGPoint) -> [CGPoint] {
            (0...4).map { index in
                let t = CGFloat(index) / 4
                return normalized(CGPoint(x: start.x * (1 - t) + end.x * t,
                                          y: start.y * (1 - t) + end.y * t))
            }
        }
        let shiftedTopRight = CGPoint(x: corners[1].x + 24, y: corners[1].y)
        let shiftedBottomRight = CGPoint(x: corners[2].x + 24, y: corners[2].y)
        let candidate = DocumentBoundary(corners: corners.map(normalized))
        let local = DocumentBoundary(top: candidate.top,
                                     right: edge(shiftedTopRight, shiftedBottomRight),
                                     bottom: edge(corners[3], shiftedBottomRight),
                                     left: edge(corners[0], corners[3]))

        XCTAssertNil(try flattener.recoverPhotoBoundary(
            image, boundary: candidate, preservingMeasuredEdges: local))
    }

    func testPhotoRecoveryRejectsCompetingPrintedBoundary() throws {
        let size = CGSize(width: 1200, height: 1600)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.38, green: 0.34, blue: 0.29, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let canvas = context.cgContext
            canvas.setFillColor(UIColor.white.cgColor)
            canvas.fill(CGRect(x: 250, y: 100, width: 700, height: 1300))
            canvas.setStrokeColor(UIColor.black.cgColor)
            canvas.setLineWidth(8)
            canvas.stroke(CGRect(x: 265, y: 115, width: 670, height: 1270))
        }
        func normalized(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x / size.width, y: 1 - point.y / size.height)
        }
        let candidate = DocumentBoundary(corners: [
            normalized(CGPoint(x: 257.5, y: 107.5)), normalized(CGPoint(x: 942.5, y: 107.5)),
            normalized(CGPoint(x: 942.5, y: 1392.5)), normalized(CGPoint(x: 257.5, y: 1392.5))
        ])

        XCTAssertNil(try flattener.recoverPhotoBoundary(XCTUnwrap(image.cgImage), boundary: candidate))
    }

    func testPhotoRecoveryRetainsKnownCurvedBoundary() throws {
        let size = CGSize(width: 600, height: 800)
        let image = try XCTUnwrap(TestImageFactory.solid(.white, size: size).cgImage)
        let topLeft = CGPoint(x: 0.2, y: 0.9), topRight = CGPoint(x: 0.8, y: 0.9)
        let boundary = DocumentBoundary(top: [topLeft, CGPoint(x: 0.4, y: 0.87),
                                               CGPoint(x: 0.6, y: 0.93), topRight],
            right: [topRight, CGPoint(x: 0.8, y: 0.1)],
            bottom: [CGPoint(x: 0.2, y: 0.1), CGPoint(x: 0.8, y: 0.1)],
            left: [topLeft, CGPoint(x: 0.2, y: 0.1)])
        XCTAssertTrue(boundary.hasMeasuredCurvedEdges(in: size))

        XCTAssertEqual(try XCTUnwrap(flattener.recoverPhotoBoundary(image, boundary: boundary)), boundary)
    }

    /// 上原点 raw 画像とマスクで、ページ位置・上下マーカーを保って flatten することを検証する。
    /// - 入力: なし
    /// - 出力: なし
    /// - 処理: 非対称な 100x150 RGBA 画像・上原点マスク・縦オフセット四角形で
    ///   PageBitmap のサンプルと出力の上下マーカー位置を確認する
    func testTopOriginAsymmetricImageAndMaskKeepMarkerPositions() throws {
        let image = try makeTopOriginRawImage(width: 100, height: 150)
        let bitmap = try PageBitmap(image)
        let topSourceOffset = (50 * bitmap.width + 37) * 4
        let bottomSourceOffset = (109 * bitmap.width + 63) * 4
        XCTAssertGreaterThan(bitmap.data[topSourceOffset], 200)
        XCTAssertLessThan(bitmap.data[topSourceOffset + 2], 80)
        XCTAssertLessThan(bitmap.data[bottomSourceOffset], 80)
        XCTAssertGreaterThan(bitmap.data[bottomSourceOffset + 2], 200)

        let corners = [
            CGPoint(x: 20, y: 30), CGPoint(x: 80, y: 30),
            CGPoint(x: 80, y: 130), CGPoint(x: 20, y: 130)
        ]
        let mask = makeTopOriginMask(width: 100, height: 150)
        let output = try flattener.flatten(image, corners: corners, mask: mask)
        let outputBitmap = try PageBitmap(output)
        let topX = Int(Double(output.width) * 0.28)
        let topY = Int(Double(output.height) * 0.21)
        let bottomX = Int(Double(output.width) * 0.75)
        let bottomY = Int(Double(output.height) * 0.79)
        let topOffset = (topY * outputBitmap.width + topX) * 4
        let bottomOffset = (bottomY * outputBitmap.width + bottomX) * 4
        XCTAssertGreaterThan(outputBitmap.data[topOffset], 180)
        XCTAssertLessThan(outputBitmap.data[topOffset + 2], 80)
        XCTAssertLessThan(outputBitmap.data[bottomOffset], 80)
        XCTAssertGreaterThan(outputBitmap.data[bottomOffset + 2], 180)
    }

    /// 上下辺 ±40px・左辺 30px に湾曲したページ形状の CGPath を返す。
    /// - 入力: なし
    /// - 出力: 左上→右上→右下→左下の閉パス（左上原点座標）
    /// - 処理: 各辺を二次曲線（control を外向きにずらす）で結ぶ
    private func curvedPagePath() -> CGMutablePath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 200, y: 300))
        // 上辺は上に 40px 膨らむ
        path.addQuadCurve(to: CGPoint(x: 1300, y: 350),
                          control: CGPoint(x: 750, y: 265))
        // 右辺はほぼ直線（軽い膨らみ）
        path.addQuadCurve(to: CGPoint(x: 1280, y: 1750),
                          control: CGPoint(x: 1310, y: 1050))
        // 下辺は下に 40px 膨らむ（右→左へ描く）
        path.addQuadCurve(to: CGPoint(x: 230, y: 1700),
                          control: CGPoint(x: 760, y: 1790))
        // 左辺は左に 30px 膨らむ（下→上へ描く）
        path.addQuadCurve(to: CGPoint(x: 200, y: 300),
                          control: CGPoint(x: 170, y: 1000))
        path.closeSubpath()
        return path
    }

    /// 暗灰背景 + 白いページ形状 + 黒い横バーの合成画像を描画する。
    /// - 入力: path … ページ形状（左上原点）、size … 画像サイズ
    /// - 出力: 描画済み CGImage
    /// - 処理: 背景を 40 の灰で塗り、パスを白で塗り、内部に黒バーを数本描く
    private func renderPage(path: CGPath, size: CGSize) -> CGImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 40.0 / 255.0, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            ctx.cgContext.addPath(path)
            ctx.cgContext.setFillColor(UIColor.white.cgColor)
            ctx.cgContext.fillPath()
            UIColor.black.setFill()
            for i in 0..<8 {
                ctx.fill(CGRect(x: 400, y: 500 + i * 140, width: 700, height: 20))
            }
        }.cgImage!
    }

    /// ページ形状と同じ形を低解像度でラスタライズした合成マスクを返す。
    /// - 入力: path … ページ形状、size … 画像サイズ
    /// - 出力: 150x200 の SegmentationMask（内部=1、外部=0）
    /// - 処理: グレー 8bit コンテキストにスケール済みパスを白塗りして Float 化する
    private func makeMask(path: CGPath, size: CGSize) -> SegmentationMask {
        let mw = 150
        let mh = 200
        var buf = [UInt8](repeating: 0, count: mw * mh)
        let context = CGContext(
            data: &buf, width: mw, height: mh, bitsPerComponent: 8,
            bytesPerRow: mw, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        // 生の CGBitmapContext は左下原点なので、左上原点のパス座標と
        // 行が上から順のマスクレイアウトに合わせるため上下を反転してから描く
        context.translateBy(x: 0, y: CGFloat(mh))
        context.scaleBy(x: Double(mw) / Double(size.width),
                        y: -Double(mh) / Double(size.height))
        context.addPath(path)
        context.setFillColor(gray: 1, alpha: 1)
        context.fillPath()
        let values = buf.map { Float($0) / 255 }
        return SegmentationMask(width: mw, height: mh, values: values,
                                imageWidth: Int(size.width), imageHeight: Int(size.height))
    }

    private func makeTopOriginRawImage(width: Int, height: Int) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let isPage = (20..<80).contains(x) && (30..<130).contains(y)
                let color: (UInt8, UInt8, UInt8) = {
                    if (30..<45).contains(x) && (44..<59).contains(y) { return (255, 0, 0) }
                    if (56..<71).contains(x) && (102..<117).contains(y) { return (0, 0, 255) }
                    return isPage ? (245, 245, 245) : (40, 40, 40)
                }()
                bytes[offset] = color.0
                bytes[offset + 1] = color.1
                bytes[offset + 2] = color.2
                bytes[offset + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func makeTopOriginMask(width: Int, height: Int) -> SegmentationMask {
        var values = [Float](repeating: 0, count: width * height)
        for y in 30..<130 {
            for x in 20..<80 {
                values[y * width + x] = 1
            }
        }
        return SegmentationMask(width: width, height: height, values: values,
                                imageWidth: width, imageHeight: height)
    }
}
