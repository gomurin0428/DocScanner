import Vision

/// 撮影プレビューと保存画像で共通の書類候補検出。
enum DocumentRectangleDetector {
    /// 小さな紙・細長い紙・斜めの紙を含む最大 8 候補を検出するリクエストを作る。
    /// - 入力: なし
    /// - 出力: 設定済みの矩形検出リクエスト
    /// - 処理: サイズ・縦横比・角度の許容範囲を設定する
    static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.15
        request.minimumSize = 0.1
        request.maximumObservations = 8
        request.quadratureTolerance = 45
        return request
    }

    /// 候補から面積と信頼度の積が最大の書類を選ぶ。
    /// - 入力: observations … Vision の検出候補
    /// - 出力: 選択した候補、候補が無ければ nil
    /// - 処理: 傾いた四角形の実面積を計算し、小さな内枠より紙全体を優先する
    static func preferred(in observations: [VNRectangleObservation]) -> VNRectangleObservation? {
        observations.max { score($0) < score($1) }
    }

    /// 直線矩形の有無に依存せず、書類領域を一貫して追跡候補に使う。
    /// - 入力: observations … 矩形候補、document … 書類領域、size … 向き補正済み寸法
    /// - 出力: 書類候補。不確かな領域や画面端の退化領域は nil
    /// - 処理: 信頼度と四角形の形状を検証し、矩形の有無だけで書類を除外しない
    static func liveDocument(in observations: [VNRectangleObservation],
                             document: VNRectangleObservation?,
                             size: CGSize) -> VNRectangleObservation? {
        guard let document, document.confidence >= 0.6,
              size.width > 0, size.height > 0 else { return nil }
        let points = [document.topLeft, document.topRight,
                      document.bottomRight, document.bottomLeft]
        guard points.allSatisfy({ (0.01...0.99).contains($0.x) && (0.01...0.99).contains($0.y) }) else {
            return nil
        }
        let edges = points.indices.map { index in
            let a = points[index]
            let b = points[(index + 1) % 4]
            return CGPoint(x: (b.x - a.x) * size.width, y: (b.y - a.y) * size.height)
        }
        guard edges.indices.allSatisfy({ index in
            let a = edges[index]
            let b = edges[(index + 1) % 4]
            return a.x * b.y - a.y * b.x < 0
        }) else { return nil }
        let lengths = edges.map { hypot($0.x, $0.y) }
        guard let shortest = lengths.min(), let longest = lengths.max(),
              shortest >= min(size.width, size.height) * 0.1,
              shortest / longest >= 0.15 else { return nil }
        return document
    }

    /// 優先矩形が書類領域検出でも裏付けられる場合だけ矩形候補を返す。
    /// - 入力: observations … 矩形候補、document … 書類領域、size … 向き補正済み画素寸法
    /// - 出力: 確認済み矩形、信頼度不足・不一致なら nil
    /// - 処理: 書類領域の信頼度 0.8 と優先矩形の四隅の一致を要求する
    static func confirmedDocument(in observations: [VNRectangleObservation],
                                  document: VNRectangleObservation?,
                                  size: CGSize) -> VNRectangleObservation? {
        guard let document, document.confidence >= 0.8,
              let rectangle = preferred(in: observations),
              DocumentDetector.quadsAgree(
                [document.topLeft, document.topRight, document.bottomRight, document.bottomLeft],
                [rectangle.topLeft, rectangle.topRight, rectangle.bottomRight, rectangle.bottomLeft],
                width: size.width, height: size.height) else { return nil }
        return rectangle
    }

    /// 正規化四角形の面積に信頼度を掛けた値を返す。
    /// - 入力: 検出した四角形
    /// - 出力: 面積と信頼度の積
    /// - 処理: 頂点の外積和から実面積を計算する
    private static func score(_ observation: VNRectangleObservation) -> CGFloat {
        let points = [observation.topLeft, observation.topRight,
                      observation.bottomRight, observation.bottomLeft]
        var twiceArea: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            twiceArea += points[index].x * next.y - next.x * points[index].y
        }
        return abs(twiceArea) * CGFloat(observation.confidence) / 2
    }
}
