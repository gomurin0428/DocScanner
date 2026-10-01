import CoreGraphics

/// 書類の四辺。左下原点の正規化座標で、上・下辺は左→右、左右辺は上→下。
struct DocumentBoundary: Equatable {
    let top: [CGPoint]
    let right: [CGPoint]
    let bottom: [CGPoint]
    let left: [CGPoint]

    var corners: [CGPoint] { [top[0], top[top.count - 1], bottom[bottom.count - 1], bottom[0]] }
    var outline: [CGPoint] { top + right.dropFirst() + bottom.reversed().dropFirst() + left.reversed().dropFirst() }

    /// 四辺を受け取り、描画・保存で共有する輪郭を構成する。
    init(top: [CGPoint], right: [CGPoint], bottom: [CGPoint], left: [CGPoint]) {
        self.top = top
        self.right = right
        self.bottom = bottom
        self.left = left
    }

    /// TL/TR/BR/BL の四隅から直線の輪郭を作る。
    init(corners: [CGPoint]) {
        top = [corners[0], corners[1]]
        right = [corners[1], corners[2]]
        bottom = [corners[3], corners[2]]
        left = [corners[0], corners[3]]
    }

    /// 全点を同じ変換に通し、辺の対応関係を保持する。
    func map(_ transform: (CGPoint) -> CGPoint) -> DocumentBoundary {
        DocumentBoundary(top: top.map(transform), right: right.map(transform),
                         bottom: bottom.map(transform), left: left.map(transform))
    }

    /// 描画・切り抜きに使える有限な画像内の輪郭かを検査する。
    var isValid: Bool {
        guard [top, right, bottom, left].allSatisfy({ $0.count >= 2 }),
              outline.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                  (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        let points = corners
        return points.indices.allSatisfy { index in
            let a = points[index], b = points[(index + 1) % 4], c = points[(index + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) < -0.00001
        }
    }
}
