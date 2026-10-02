import Foundation

/// 文字列の中心点から推定する紙面内の縦方向変位。座標は左上原点の正規化値。
struct PageDewarpModel {
    private static let knots = 8
    private static let degree = 3
    private let coefficients: [Double]
    private let minX: Double
    private let maxX: Double
    private let minY: Double
    private let maxY: Double

    static func fit(lines: [[PagePoint]]) -> PageDewarpModel? {
        let lines = lines.filter { points in
            guard points.count >= 8, points.allSatisfy({
                $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y)
            }) else { return false }
            let xs = points.map(\.x), ys = points.map(\.y)
            return xs.max()! - xs.min()! >= 0.18 && ys.max()! - ys.min()! < 0.12
        }
        let points = lines.flatMap { $0 }
        guard lines.count >= 6,
              let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max(),
              maxX - minX >= 0.45, maxY - minY >= 0.25 else { return nil }
        let rows = lines.map { $0.map(\.y).reduce(0, +) / Double($0.count) }
        guard Set(rows.map { Int($0 * 6) }).count >= 3 else { return nil }

        let count = knots * degree
        let features = lines.map { $0.map { basis(x: $0.x, y: $0.y) } }
        var weights = lines.map { [Double](repeating: 1, count: $0.count) }
        var model: PageDewarpModel?
        for _ in 0..<4 {
            var matrix = [[Double]](repeating: [Double](repeating: 0, count: count), count: count)
            var rhs = [Double](repeating: 0, count: count)
            for (index, line) in lines.enumerated() {
                let total = weights[index].reduce(0, +)
                guard total >= 6 else { continue }
                var mean = [Double](repeating: 0, count: count)
                var meanY = 0.0
                for (j, point) in line.enumerated() {
                    let weight = weights[index][j] / total
                    meanY += point.y * weight
                    for k in 0..<count { mean[k] += features[index][j][k] * weight }
                }
                for (j, point) in line.enumerated() {
                    let weight = weights[index][j]
                    let row = zip(features[index][j], mean).map { $0 - $1 }
                    for r in 0..<count {
                        rhs[r] += weight * row[r] * (point.y - meanY)
                        for c in 0..<count { matrix[r][c] += weight * row[r] * row[c] }
                    }
                }
            }
            for k in 0..<count { matrix[k][k] += 0.0001 }
            for power in 0..<degree {
                for knot in 1..<(knots - 1) {
                    let indices = [power * knots + knot - 1, power * knots + knot, power * knots + knot + 1]
                    let factors = [1.0, -2.0, 1.0]
                    for a in 0..<3 {
                        for b in 0..<3 { matrix[indices[a]][indices[b]] += factors[a] * factors[b] }
                    }
                }
            }
            guard let coefficients = try? PageGeometry.solveLinear(matrix, rhs),
                  coefficients.allSatisfy(\.isFinite) else { return nil }
            let fitted = PageDewarpModel(coefficients: coefficients, minX: minX, maxX: maxX,
                                        minY: minY, maxY: maxY)
            model = fitted
            let residuals = lines.map { line -> [Double] in
                let corrected = line.map { $0.y - fitted.displacement(at: $0) }
                let center = median(corrected)
                return corrected.map { abs($0 - center) }
            }
            let cutoff = max(0.002, median(residuals.flatMap { $0 }) * 4.5)
            weights = residuals.map { $0.map { min(1, cutoff / max($0, 0.000001)) } }
        }
        guard let model, model.isSafe else { return nil }
        let before = lines.flatMap { line -> [Double] in
            let center = median(line.map(\.y))
            return line.map { abs($0.y - center) }
        }
        let after = lines.flatMap { line -> [Double] in
            let values = line.map { $0.y - model.displacement(at: $0) }
            let center = median(values)
            return values.map { abs($0 - center) }
        }
        guard median(before) > 0.0015, median(after) < median(before) * 0.7 else { return nil }
        return model
    }

    func displacement(at point: PagePoint) -> Double {
        let x = min(max(point.x, minX - 0.08), maxX + 0.08)
        let y = min(max(point.y, minY), maxY)
        let values = Self.basis(x: x, y: y)
        let offset = zip(coefficients, values).reduce(0) { $0 + $1.0 * $1.1 }
        let edge = min(1, min(point.y, 1 - point.y) / 0.12)
        return offset * max(0, edge)
    }

    func sourcePoint(for output: PagePoint) -> PagePoint {
        var y = output.y
        for _ in 0..<8 { y = output.y + displacement(at: PagePoint(x: output.x, y: y)) }
        return PagePoint(x: output.x, y: y)
    }

    private var isSafe: Bool {
        for x in stride(from: 0.0, through: 1.0, by: 0.025) {
            var previous = -Double.infinity
            for y in stride(from: 0.0, through: 1.0, by: 0.0125) {
                let point = PagePoint(x: x, y: y)
                let offset = displacement(at: point)
                let corrected = y - offset
                guard abs(offset) <= 0.08, corrected >= 0, corrected <= 1 else { return false }
                if previous.isFinite {
                    let step = (corrected - previous) / 0.0125
                    guard (0.5...1.5).contains(step) else { return false }
                }
                previous = corrected
            }
        }
        return true
    }

    private static func basis(x: Double, y: Double) -> [Double] {
        let x = x - 0.5
        let position = y * Double(knots - 1)
        return (1...degree).flatMap { power in
            (0..<knots).map { knot in
                pow(x, Double(power)) * max(0, 1 - abs(position - Double(knot)))
            }
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
