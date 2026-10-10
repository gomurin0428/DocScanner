import CoreGraphics
import Foundation
import simd

/// 幾何計算用の Double 精度 2D 点（左上原点ピクセル座標）。
struct PagePoint {
    var x: Double
    var y: Double

    /// ベクトル加算。
    /// - 入力: lhs, rhs … 加算する 2 点
    /// - 出力: 成分ごとの和
    /// - 処理: x/y をそれぞれ加算する
    static func + (lhs: PagePoint, rhs: PagePoint) -> PagePoint {
        PagePoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    /// ベクトル減算。
    /// - 入力: lhs, rhs … 減算する 2 点
    /// - 出力: 成分ごとの差
    /// - 処理: x/y をそれぞれ減算する
    static func - (lhs: PagePoint, rhs: PagePoint) -> PagePoint {
        PagePoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    /// スカラー倍。
    /// - 入力: lhs … 点、s … スカラー
    /// - 出力: 成分ごとの積
    /// - 処理: x/y にスカラーを掛ける
    static func * (lhs: PagePoint, s: Double) -> PagePoint {
        PagePoint(x: lhs.x * s, y: lhs.y * s)
    }

    /// 原点からの距離（ベクトル長）を返す。
    var length: Double { (x * x + y * y).squareRoot() }
}

/// ホモグラフィ・曲線サンプリング・線形ソルバの幾何ユーティリティ。
enum PageGeometry {

    static func outputSize(boundary: DocumentBoundary, imageSize: CGSize,
                           camera: DocumentCamera? = nil) throws -> CGSize {
        guard boundary.isValid, imageSize.width > 0, imageSize.height > 0 else {
            throw DocumentDetectionError.invalidImage
        }
        let corners = boundary.corners.map {
            PagePoint(x: $0.x * imageSize.width, y: (1 - $0.y) * imageSize.height)
        }
        let width = ((corners[1] - corners[0]).length + (corners[2] - corners[3]).length) / 2
        let height = ((corners[3] - corners[0]).length + (corners[2] - corners[1]).length) / 2
        let unit = [PagePoint(x: 0, y: 0), PagePoint(x: 1, y: 0),
                    PagePoint(x: 1, y: 1), PagePoint(x: 0, y: 1)]
        let h = try homography(from: unit, to: corners)
        var calibration = camera?.scaled(to: imageSize)
        if calibration == nil {
            let cx = imageSize.width / 2, cy = imageSize.height / 2
            let product = h[6] * h[7]
            let fSquared = -((h[0] - cx * h[6]) * (h[1] - cx * h[7]) +
                             (h[3] - cy * h[6]) * (h[4] - cy * h[7])) / product
            let f = sqrt(fSquared)
            let diagonal = hypot(imageSize.width, imageSize.height)
            if abs(product) > 1e-10, f.isFinite, f > diagonal * 0.25, f < diagonal * 10 {
                calibration = DocumentCamera(focalX: f, focalY: f, centerX: cx, centerY: cy,
                                             referenceSize: imageSize)
                AppDiagnostics.selection("Document aspect ratio: focal length estimated from orthogonal edges")
            } else {
                AppDiagnostics.selection("Document aspect ratio: uncalibrated projection; focal length is indeterminate")
            }
        }
        var ratio = height / width
        if let calibration, calibration.focalX.isFinite, calibration.focalY.isFinite,
           calibration.focalX > 0, calibration.focalY > 0 {
            let u = SIMD3((h[0] - calibration.centerX * h[6]) / calibration.focalX,
                          (h[3] - calibration.centerY * h[6]) / calibration.focalY, h[6])
            let v = SIMD3((h[1] - calibration.centerX * h[7]) / calibration.focalX,
                          (h[4] - calibration.centerY * h[7]) / calibration.focalY, h[7])
            let orthogonality = abs(simd_dot(u, v)) / (simd_length(u) * simd_length(v))
            let metricRatio = simd_length(v) / simd_length(u)
            if metricRatio.isFinite, metricRatio > 0, orthogonality < 0.15 {
                ratio = metricRatio
            } else {
                AppDiagnostics.selection("Document aspect ratio: nonplanar or inconsistent calibrated corners")
            }
        }
        let outWidth = max(width, height / ratio), outHeight = outWidth * ratio
        let scale = min(1, 4096 / max(outWidth, outHeight))
        return CGSize(width: max(2, (outWidth * scale).rounded()),
                      height: max(2, (outHeight * scale).rounded()))
    }

    /// 部分ピボット付きガウス消去で連立方程式を解く。
    /// - 入力: matrix … 正方係数行列、rhs … 右辺ベクトル
    /// - 出力: 解ベクトル
    /// - 処理: 全列で最大絶対値ピボットを選び前進消去・後退代入する
    /// - Throws: ピボットがほぼ 0 の特異行列の場合 DocumentDetectionError.singularHomography
    static func solveLinear(_ matrix: [[Double]], _ rhs: [Double]) throws -> [Double] {
        var a = matrix
        var b = rhs
        let n = b.count
        for i in 0..<n {
            var p = i
            for r in i..<n where abs(a[r][i]) > abs(a[p][i]) { p = r }
            if abs(a[p][i]) < 1e-12 {
                throw DocumentDetectionError.singularHomography
            }
            a.swapAt(i, p)
            b.swapAt(i, p)
            for r in 0..<n where r != i {
                let f = a[r][i] / a[i][i]
                if f == 0 { continue }
                for c in i..<n { a[r][c] -= f * a[i][c] }
                b[r] -= f * b[i]
            }
        }
        return (0..<n).map { b[$0] / a[$0][$0] }
    }

    /// 4 点対応からホモグラフィ行列（3x3 平坦化、h33=1）を求める。
    /// - 入力: src … 変換元 4 点、dst … 変換先 4 点（いずれも左上原点ピクセル座標）
    /// - 出力: 9 要素のホモグラフィ係数
    /// - 処理: src[i]→dst[i] の 8 元連立方程式を解く
    /// - Throws: 4 点が退化して方程式が特異な場合 singularHomography
    static func homography(from src: [PagePoint], to dst: [PagePoint]) throws -> [Double] {
        var a: [[Double]] = []
        var b: [Double] = []
        for i in 0..<4 {
            let x = src[i].x, y = src[i].y, u = dst[i].x, v = dst[i].y
            a.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
            b.append(u)
            a.append([0, 0, 0, x, y, 1, -v * x, -v * y])
            b.append(v)
        }
        return try solveLinear(a, b) + [1]
    }

    /// ホモグラフィを 1 点へ適用する。
    /// - 入力: h … 9 要素係数、p … 入力点
    /// - 出力: 変換後の点
    /// - 処理: 射影除算を含む 3x3 変換を適用する
    static func apply(_ h: [Double], to p: PagePoint) -> PagePoint {
        let w = h[6] * p.x + h[7] * p.y + h[8]
        return PagePoint(x: (h[0] * p.x + h[1] * p.y + h[2]) / w,
                         y: (h[3] * p.x + h[4] * p.y + h[5]) / w)
    }

    /// 折れ線の弧長を返す。
    /// - 入力: points … 順序付き点列
    /// - 出力: 隣接点間距離の合計
    /// - 処理: 各区間長を累積する
    static func arcLength(_ points: [PagePoint]) -> Double {
        zip(points, points.dropFirst()).map { ($1 - $0).length }.reduce(0, +)
    }

    /// 折れ線上を t (0〜1) で線形補間サンプルする。
    /// - 入力: points … 点列、t … 0〜1 の位置
    /// - 出力: 補間点
    /// - 処理: t をセグメントインデックスに変換して 2 点間を補間する
    static func sample(_ points: [PagePoint], at t: Double) -> PagePoint {
        let f = t * Double(points.count - 1)
        let i = min(Int(f), points.count - 2)
        let r = f - Double(i)
        return points[i] * (1 - r) + points[i + 1] * r
    }
}
