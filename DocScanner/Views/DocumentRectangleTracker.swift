import Vision

/// 連続した検出だけを表示し、単発の誤検出や候補変更を抑える状態。
struct DocumentRectangleTracker {
    private(set) var didMatchObservation = false
    private var displayed: [CGPoint]?
    private var lastMatched: [CGPoint]?
    private var lastSeen: TimeInterval = 0
    private var pending: [CGPoint]?
    private var pendingSince: TimeInterval = 0
    private var pendingCount = 0
    private var previousTime: TimeInterval?

    /// 候補とフレーム時刻を受け取り、安定した表示用四角形を返す。
    /// - 入力: observation … 書類として確認済みの候補、time … 単調増加する秒
    /// - 出力: 平滑化した四隅。確認中または消失時は nil
    /// - 処理: 3 回かつ 0.35 秒の一致で表示し、0.75 秒の未検出で解除する
    mutating func update(_ observation: VNRectangleObservation?, at time: TimeInterval) -> [CGPoint]? {
        didMatchObservation = false
        guard time.isFinite else {
            self = Self()
            return nil
        }
        if let previousTime, time <= previousTime || time - previousTime > 0.75 {
            self = Self()
        }
        previousTime = time
        if displayed != nil, time - lastSeen > 0.75 {
            displayed = nil
            lastMatched = nil
        }
        guard let observation else {
            pending = nil
            pendingCount = 0
            return displayed
        }
        let quad = [observation.topLeft, observation.topRight,
                    observation.bottomRight, observation.bottomLeft]
        if let lastMatched, let displayed, Self.matches(quad, lastMatched) {
            didMatchObservation = true
            self.displayed = zip(displayed, quad).map { old, new in
                CGPoint(x: old.x + (new.x - old.x) * 0.35,
                        y: old.y + (new.y - old.y) * 0.35)
            }
            self.lastMatched = quad
            lastSeen = time
            pending = nil
            pendingCount = 0
            return self.displayed
        }
        if let pending, Self.matches(quad, pending) {
            pendingCount += 1
        } else {
            pending = quad
            pendingSince = time
            pendingCount = 1
        }
        if displayed == nil, pendingCount >= 3, time - pendingSince >= 0.35 {
            didMatchObservation = true
            displayed = quad
            lastMatched = quad
            lastSeen = time
            pending = nil
            pendingCount = 0
        }
        return displayed
    }

    /// 四隅の距離を短辺に比例する許容幅で比較し、同じ紙か判定する。
    private static func matches(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Bool {
        let width = (rhs.map(\.x).max() ?? 0) - (rhs.map(\.x).min() ?? 0)
        let height = (rhs.map(\.y).max() ?? 0) - (rhs.map(\.y).min() ?? 0)
        let tolerance = min(0.07, min(width, height) * 0.2)
        return zip(lhs, rhs).allSatisfy { a, b in
            hypot(a.x - b.x, a.y - b.y) <= tolerance
        }
    }
}
