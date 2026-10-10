import CoreGraphics
import CoreVideo
import Foundation

/// VNDetectDocumentSegmentationRequest の低解像度セグメンテーションマスク。
/// 値は書類の存在確率（0〜1）。座標変換は左上原点の画像ピクセル座標を受け取る
/// （マスクバッファの行は上から順）。
struct SegmentationMask {
    /// マスクの幅（ピクセル）。
    let width: Int
    /// マスクの高さ（ピクセル）。
    let height: Int
    /// 行優先の確率値（width × height 要素）。
    let values: [Float]
    /// 画像ピクセル → マスクピクセルの X 方向スケール。
    let scaleX: Double
    /// 画像ピクセル → マスクピクセルの Y 方向スケール。
    let scaleY: Double

    /// Vision が返すピクセルバッファからマスクを構築する。
    /// - 入力: pixelBuffer … globalSegmentationMask のバッファ、
    ///   imageWidth / imageHeight … 元画像のピクセルサイズ
    /// - 出力: 画像座標へマップ可能な SegmentationMask
    /// - 処理: Float32 1ch 形式を検証し、行優先で全値をコピーする
    /// - Throws: 想定外のピクセル形式なら DocumentDetectionError.unexpectedMaskFormat
    init(pixelBuffer: CVPixelBuffer, imageWidth: Int, imageHeight: Int) throws {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_OneComponent32Float else {
            let fmt = String(format: "0x%08x", CVPixelBufferGetPixelFormatType(pixelBuffer))
            throw DocumentDetectionError.unexpectedMaskFormat(fmt)
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        let bpr = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw DocumentDetectionError.unexpectedMaskFormat("no base address")
        }
        var vals = [Float](repeating: 0, count: w * h)
        for r in 0..<h {
            let row = (base + r * bpr).assumingMemoryBound(to: Float.self)
            for c in 0..<w { vals[r * w + c] = row[c] }
        }
        self.init(width: w, height: h, values: vals,
                  imageWidth: imageWidth, imageHeight: imageHeight)
    }

    /// 値配列から直接構築する（テスト用の合成マスク）。
    /// - 入力: width / height … マスクサイズ、values … 行優先 Float 配列、
    ///   imageWidth / imageHeight … マップ先の画像ピクセルサイズ
    /// - 出力: SegmentationMask
    /// - 処理: スケール比を計算して保持する
    init(width: Int, height: Int, values: [Float], imageWidth: Int, imageHeight: Int) {
        self.width = width
        self.height = height
        self.values = values
        self.scaleX = Double(width) / Double(imageWidth)
        self.scaleY = Double(height) / Double(imageHeight)
    }

    /// 画像ピクセル座標（左上原点）のマスク値を双線形補間で返す。
    /// - 入力: point … 画像ピクセル座標
    /// - 出力: 0〜1 の補間済みマスク値
    /// - 処理: マスク座標へ変換し周囲 4 点を双線形補間する
    func value(at point: PagePoint) -> Double {
        let x = min(max(point.x * scaleX - 0.5, 0), Double(width - 1))
        let y = min(max(point.y * scaleY - 0.5, 0), Double(height - 1))
        let x0 = min(Int(x), width - 2)
        let y0 = min(Int(y), height - 2)
        let tx = x - Double(x0)
        let ty = y - Double(y0)
        let a = Double(values[y0 * width + x0])
        let b = Double(values[y0 * width + x0 + 1])
        let c = Double(values[(y0 + 1) * width + x0])
        let d = Double(values[(y0 + 1) * width + x0 + 1])
        return (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
    }
}

/// sRGB RGBA8 の CPU ビットマップ（輝度・画素サンプリング用）。
struct PageBitmap {
    /// 幅（ピクセル）。
    let width: Int
    /// 高さ（ピクセル）。
    let height: Int
    /// 行優先 RGBA8 データ。
    var data: [UInt8]

    /// CGImage を RGBA8 へ描画する。
    /// - 入力: image … 入力 CGImage
    /// - 出力: ビットマップ
    /// - 処理: sRGB premultipliedLast コンテキストへ全体を描く
    /// - Throws: コンテキスト生成失敗時 DocumentDetectionError.bitmapContextFailed
    init(_ image: CGImage, background: CGColor? = nil) throws {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw DocumentDetectionError.bitmapContextFailed
        }
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        data = buffer
    }

    /// 指定座標の輝度（最近傍、0〜255）を返す。
    /// - 入力: x, y … ピクセル座標（範囲外は端にクランプ）
    /// - 出力: Rec.601 輝度
    /// - 処理: 最近傍ピクセルの RGB から輝度を計算する
    func luminance(atX x: Double, y: Double) -> Double {
        let xi = min(max(Int(x), 0), width - 1)
        let yi = min(max(Int(y), 0), height - 1)
        let o = (yi * width + xi) * 4
        return 0.299 * Double(data[o]) + 0.587 * Double(data[o + 1]) + 0.114 * Double(data[o + 2])
    }

    /// 指定座標の RGB を双線形補間して out へ書き込む。
    /// - 入力: x, y … ピクセル座標（中心基準で -0.5 補正済みを想定）、out … 4 バイト出力先
    /// - 出力: なし（out[0...2] に RGB を書き込む）
    /// - 処理: 周囲 4 画素をクランプして双線形補間する
    func sampleRGB(atX x: Double, y: Double, into out: UnsafeMutablePointer<UInt8>) {
        let x0 = min(max(Int(x.rounded(.down)), 0), width - 2)
        let y0 = min(max(Int(y.rounded(.down)), 0), height - 2)
        let fx = min(max(x - Double(x0), 0), 1)
        let fy = min(max(y - Double(y0), 0), 1)
        for ch in 0..<3 {
            let a = Double(data[(y0 * width + x0) * 4 + ch])
            let b = Double(data[(y0 * width + x0 + 1) * 4 + ch])
            let c = Double(data[((y0 + 1) * width + x0) * 4 + ch])
            let d = Double(data[((y0 + 1) * width + x0 + 1) * 4 + ch])
            out[ch] = UInt8(((a * (1 - fx) + b * fx) * (1 - fy)
                             + (c * (1 - fx) + d * fx) * fy).rounded())
        }
    }
}

/// セグメンテーションマスクで書類輪郭を精密に追跡し、湾曲した紙の辺を
/// 直線化してページを矩形に引き伸ばすフラットナ。
struct PageFlattener {

    /// 辺トレースのサンプル数（各辺 N+1 点）。
    private static let edgeSamples = 64
    /// Coons パッチのグリッド分割数。
    private static let coonsGrid = 32
    /// 定数スケールの基準解像度（プロトタイプ動作サイズ）。
    private static let referenceSize = 3000.0

    /// フラットナを初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み PageFlattener
    /// - 処理: 状態を持たないため空
    init() {}

    /// 画像をセグメンテーションマスクと四隅でフラット化した CGImage を返す。
    /// - 入力: image … 向き正規化済み CGImage、
    ///   corners … 左上原点ピクセル座標の 4 隅（TL, TR, BR, BL の順）、
    ///   mask … セグメンテーションマスク
    /// - 出力: 書類が矩形に引き伸ばされた CGImage（背景除去済み）
    /// - 処理: 各辺を法線方向にマスク走査 → 輝度エッジで精緻化 → 平滑化・内側オフセット
    ///   → 角整合 → ホモグラフィで矩形空間へ写像 → Coons パッチで一括リサンプル。
    ///   80/20/INSET/窓サイズ等の px 定数は max(W,H)/3000 でスケールする
    /// - Throws: ビットマップ生成失敗・ホモグラフィ特異・出力生成失敗
    func flatten(_ image: CGImage, corners: [CGPoint], mask: SegmentationMask) throws -> CGImage {
        try flatten(image, boundary: traceBoundary(image, corners: corners, mask: mask))
    }

    /// 画像とマスクから曲がった四辺を抽出し、正規化座標で返す。
    /// - 処理: マスク走査・輝度精緻化・平滑化・角整合を行う。描画と補正で共有する。
    func traceBoundary(_ image: CGImage, corners: [CGPoint], mask: SegmentationMask) throws -> DocumentBoundary {
        guard corners.count == 4 else {
            throw DocumentDetectionError.invalidImage
        }
        let bitmap = try PageBitmap(image)
        let W = Double(bitmap.width)
        let H = Double(bitmap.height)
        // px 定数を解像度非依存にするためのスケール
        let scale = max(W, H) / Self.referenceSize
        let searchRange = 200 * scale
        let refineRange = 20 * scale
        let inset = 4 * scale
        let gap = 2 * scale
        let window = max(1, Int((3 * scale).rounded()))

        let tl = PagePoint(x: Double(corners[0].x), y: Double(corners[0].y))
        let tr = PagePoint(x: Double(corners[1].x), y: Double(corners[1].y))
        let br = PagePoint(x: Double(corners[2].x), y: Double(corners[2].y))
        let bl = PagePoint(x: Double(corners[3].x), y: Double(corners[3].y))
        let center = (tl + tr + br + bl) * 0.25

        /// 辺 a→b に沿って輪郭点を N+1 個返す。
        func traceEdge(_ a: PagePoint, _ b: PagePoint) -> [PagePoint] {
            let delta = b - a
            let dir = delta * (1 / delta.length)
            var normal = PagePoint(x: -dir.y, y: dir.x)
            let mid = (a + b) * 0.5
            // 外向き法線（中心から遠ざかる側）を選ぶ
            if ((mid + normal) - center).length < (mid - center).length {
                normal = normal * -1
            }
            var offsets: [Double] = []
            for i in 0...Self.edgeSamples {
                let t = Double(i) / Double(Self.edgeSamples)
                let base = a + delta * t
                // マスク上で -80..+80（スケール済み）を内→外へ走査し、
                // mask >= 0.5 を満たす最も外側のオフセットを取る
                var off = 0.0
                var found = false
                var k = -searchRange
                while k <= searchRange {
                    let p = base + normal * k
                    if p.x >= 0, p.x < W, p.y >= 0, p.y < H,
                       mask.value(at: p) >= 0.5 { off = k; found = true }
                    k += 1
                }
                if !found { off = 0 }
                // 輝度エッジで精緻化: 交差近傍 ±refineRange で
                // 内側 window px 平均と外側 window px 平均の差が最大の位置を採用
                var best = 0.0
                var bestK = off
                var kk = off - refineRange
                while kk <= off + refineRange {
                    var inside = 0.0
                    var outside = 0.0
                    for j in 0..<window {
                        let ip = base + normal * (kk - gap - Double(j))
                        let op = base + normal * (kk + gap + Double(j))
                        inside += bitmap.luminance(atX: ip.x, y: ip.y)
                        outside += bitmap.luminance(atX: op.x, y: op.y)
                    }
                    let gradient = abs(inside - outside) / Double(window)
                    if gradient > best { best = gradient; bestK = kk }
                    kk += 1
                }
                if best > 12 { off = bestK }
                offsets.append(off)
            }
            // ロバスト平滑化: メディアン(5) → 移動平均(7)
            var median = offsets
            for i in 0..<offsets.count {
                let lo = max(0, i - 2)
                let hi = min(offsets.count - 1, i + 2)
                median[i] = Array(offsets[lo...hi]).sorted()[(hi - lo) / 2]
            }
            var smooth = median
            for i in 0..<median.count {
                let lo = max(0, i - 3)
                let hi = min(median.count - 1, i + 3)
                smooth[i] = median[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            }
            return (0...Self.edgeSamples).map {
                a + delta * (Double($0) / Double(Self.edgeSamples)) + normal * (smooth[$0] - inset)
            }
        }

        var top = traceEdge(tl, tr)
        var right = traceEdge(tr, br)
        var bottom = traceEdge(bl, br)
        var left = traceEdge(tl, bl)

        // 隣接辺の端点を平均して角を整合し、各辺に線形補正を掛ける
        func reconcile(_ points: inout [PagePoint], _ a: PagePoint, _ b: PagePoint) {
            let da = a - points.first!
            let db = b - points.last!
            for i in 0..<points.count {
                let t = Double(i) / Double(points.count - 1)
                points[i] = points[i] + da * (1 - t) + db * t
            }
        }
        let cTL = (top.first! + left.first!) * 0.5
        let cTR = (top.last! + right.first!) * 0.5
        let cBR = (right.last! + bottom.last!) * 0.5
        let cBL = (bottom.first! + left.last!) * 0.5
        reconcile(&top, cTL, cTR)
        reconcile(&right, cTR, cBR)
        reconcile(&bottom, cBL, cBR)
        reconcile(&left, cTL, cBL)

        func normalize(_ points: [PagePoint]) -> [CGPoint] {
            points.map { CGPoint(x: min(1, max(0, $0.x / W)), y: min(1, max(0, 1 - $0.y / H))) }
        }
        return DocumentBoundary(top: normalize(top), right: normalize(right),
                                bottom: normalize(bottom), left: normalize(left))
    }

    func refineBoundary(_ image: CGImage, boundary: DocumentBoundary) throws -> DocumentBoundary {
        guard boundary.isValid else { throw DocumentDetectionError.invalidImage }
        let w = Double(image.width), h = Double(image.height)
        let range = min(w, h) * 0.03
        let step = max(1, range / 60), gap = max(1, min(w, h) * 0.001)
        func pixels(_ points: [CGPoint]) -> [PagePoint] {
            points.map { PagePoint(x: $0.x * w, y: (1 - $0.y) * h) }
        }
        func refine(_ points: [CGPoint]) throws -> [PagePoint] {
            let edge = pixels(points)
            let count = max(17, edge.count)
            var offsets = [Double](), samples = [PagePoint](), normals = [PagePoint]()
            for i in 0..<count {
                let t = Double(i) / Double(count - 1)
                let p = PageGeometry.sample(edge, at: t)
                let tangent = PageGeometry.sample(edge, at: min(1, t + 0.02)) -
                    PageGeometry.sample(edge, at: max(0, t - 0.02))
                let normal = PagePoint(x: -tangent.y, y: tangent.x) * (1 / max(tangent.length, 1e-6))
                var offset = 0.0, best = 12.0
                if i > 0, i < count - 1 {
                    let start = p - normal * (range + gap), end = p + normal * (range + gap)
                    let bounds = CGRect(x: min(start.x, end.x) - 1, y: min(start.y, end.y) - 1,
                                        width: abs(end.x - start.x) + 3, height: abs(end.y - start.y) + 3)
                        .integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
                    guard let crop = image.cropping(to: bounds) else { throw DocumentDetectionError.renderFailed }
                    let bitmap = try PageBitmap(crop)
                    for d in stride(from: -range, through: range, by: step) {
                        let a = p + normal * (d - gap), b = p + normal * (d + gap)
                        guard a.x >= 0, a.x < w, a.y >= 0, a.y < h,
                              b.x >= 0, b.x < w, b.y >= 0, b.y < h else { continue }
                        let gradient = abs(bitmap.luminance(atX: a.x - bounds.minX, y: a.y - bounds.minY) -
                                           bitmap.luminance(atX: b.x - bounds.minX, y: b.y - bounds.minY))
                        let score = gradient - 4 * abs(d) / max(range, 1)
                        if score > best { best = score; offset = d }
                    }
                }
                samples.append(p)
                normals.append(normal)
                offsets.append(offset)
            }
            let median = offsets.dropFirst().dropLast().sorted()[((count - 2) / 2)]
            offsets[0] = median
            offsets[count - 1] = median
            return samples.indices.map { i in
                let start = max(0, i - 1), end = min(count - 1, i + 1)
                let local = offsets[start...end].sorted()
                let offset = i == 0 || i == count - 1 ? offsets[i] : local[local.count / 2]
                return samples[i] + normals[i] * offset
            }
        }
        var top = try refine(boundary.top), right = try refine(boundary.right)
        var bottom = try refine(boundary.bottom), left = try refine(boundary.left)
        func intersection(_ a: [PagePoint], _ b: [PagePoint], near p: PagePoint) -> PagePoint {
            let u = a.last! - a[0], v = b.last! - b[0], d = b[0] - a[0]
            let cross = u.x * v.y - u.y * v.x
            guard abs(cross) > 1e-6 else { return p }
            return a[0] + u * ((d.x * v.y - d.y * v.x) / cross)
        }
        let original = pixels(boundary.corners)
        let corners = [intersection(top, left, near: original[0]), intersection(top, right, near: original[1]),
                       intersection(bottom, right, near: original[2]), intersection(bottom, left, near: original[3])]
        guard zip(corners, original).allSatisfy({ ($0 - $1).length <= range * 1.5 + 2 }) else {
            throw DocumentDetectionError.correctionFailed
        }
        func reconcile(_ points: inout [PagePoint], _ start: PagePoint, _ end: PagePoint) {
            let a = start - points[0], b = end - points[points.count - 1]
            for i in points.indices {
                let t = Double(i) / Double(points.count - 1)
                points[i] = points[i] + a * (1 - t) + b * t
            }
        }
        reconcile(&top, corners[0], corners[1])
        reconcile(&right, corners[1], corners[2])
        reconcile(&bottom, corners[3], corners[2])
        reconcile(&left, corners[0], corners[3])
        func normalize(_ points: [PagePoint]) -> [CGPoint] {
            points.map { CGPoint(x: min(1, max(0, $0.x / w)), y: min(1, max(0, 1 - $0.y / h))) }
        }
        let result = DocumentBoundary(top: normalize(top), right: normalize(right),
                                      bottom: normalize(bottom), left: normalize(left))
        guard result.isValid else { throw DocumentDetectionError.correctionFailed }
        return result
    }

    /// 保存した四辺を再検出せず、そのまま矩形へ引き伸ばす。
    /// - 入力: 向き正規化済み画像と左下原点の正規化輪郭、出力: 補正画像
    func flatten(_ image: CGImage, boundary: DocumentBoundary, camera: DocumentCamera? = nil) throws -> CGImage {
        guard boundary.isValid else { throw DocumentDetectionError.invalidImage }
        let bitmap = try PageBitmap(image)
        func pixels(_ points: [CGPoint]) -> [PagePoint] {
            points.map { PagePoint(x: $0.x * Double(bitmap.width), y: (1 - $0.y) * Double(bitmap.height)) }
        }
        let top = pixels(boundary.top), right = pixels(boundary.right)
        let bottom = pixels(boundary.bottom), left = pixels(boundary.left)
        let corners = pixels(boundary.corners)
        let tl = corners[0], tr = corners[1], br = corners[2], bl = corners[3]
        let cTL = tl, cTR = tr, cBR = br, cBL = bl

        // 矩形化用ホモグラフィ（出力は四角形の平均辺長の矩形）
        let rectW = ((tr - tl).length + (br - bl).length) / 2
        let rectH = ((bl - tl).length + (br - tr).length) / 2
        let qTL = PagePoint(x: 0, y: 0)
        let qTR = PagePoint(x: rectW, y: 0)
        let qBR = PagePoint(x: rectW, y: rectH)
        let qBL = PagePoint(x: 0, y: rectH)
        let hs = try PageGeometry.homography(from: [cTL, cTR, cBR, cBL],
                                             to: [qTL, qTR, qBR, qBL])
        let hInv = try PageGeometry.homography(from: [qTL, qTR, qBR, qBL],
                                               to: [cTL, cTR, cBR, cBL])
        let mapTop = top.map { PageGeometry.apply(hs, to: $0) }
        let mapBottom = bottom.map { PageGeometry.apply(hs, to: $0) }
        let mapLeft = left.map { PageGeometry.apply(hs, to: $0) }
        let mapRight = right.map { PageGeometry.apply(hs, to: $0) }

        let size = try PageGeometry.outputSize(boundary: boundary,
                                               imageSize: CGSize(width: image.width, height: image.height), camera: camera)
        let outW = Int(size.width), outH = Int(size.height)
        guard outW >= 2, outH >= 2 else { throw DocumentDetectionError.invalidImage }

        /// Coons パッチ: 矩形空間 (u,v) → 元画像座標。
        func coons(_ u: Double, _ v: Double) -> PagePoint {
            let topBottom = PageGeometry.sample(mapTop, at: u) * (1 - v)
                + PageGeometry.sample(mapBottom, at: u) * v
            let leftRight = PageGeometry.sample(mapLeft, at: v) * (1 - u)
                + PageGeometry.sample(mapRight, at: v) * u
            let bilinear = qTL * ((1 - u) * (1 - v)) + qTR * (u * (1 - v))
                + qBL * ((1 - u) * v) + qBR * (u * v)
            return PageGeometry.apply(hInv, to: topBottom + leftRight - bilinear)
        }

        // Coons を 32x32 グリッドで前評価し、画素ごとにセル内双線形補間する
        let gridSize = Self.coonsGrid
        var grid = [PagePoint]()
        grid.reserveCapacity((gridSize + 1) * (gridSize + 1))
        for gy in 0...gridSize {
            for gx in 0...gridSize {
                grid.append(coons(Double(gx) / Double(gridSize), Double(gy) / Double(gridSize)))
            }
        }
        var out = [UInt8](repeating: 255, count: outW * outH * 4)
        for r in 0..<outH {
            let v = (Double(r) + 0.5) / Double(outH) * Double(gridSize)
            let gy = min(Int(v), gridSize - 1)
            let ty = v - Double(gy)
            for c in 0..<outW {
                let u = (Double(c) + 0.5) / Double(outW) * Double(gridSize)
                let gx = min(Int(u), gridSize - 1)
                let tx = u - Double(gx)
                let p00 = grid[gy * (gridSize + 1) + gx]
                let p10 = grid[gy * (gridSize + 1) + gx + 1]
                let p01 = grid[(gy + 1) * (gridSize + 1) + gx]
                let p11 = grid[(gy + 1) * (gridSize + 1) + gx + 1]
                let p = (p00 * (1 - tx) + p10 * tx) * (1 - ty)
                    + (p01 * (1 - tx) + p11 * tx) * ty
                let o = (r * outW + c) * 4
                out.withUnsafeMutableBufferPointer { ptr in
                    bitmap.sampleRGB(atX: p.x - 0.5, y: p.y - 0.5,
                                     into: ptr.baseAddress! + o)
                }
            }
        }
        guard let context = CGContext(
            data: &out, width: outW, height: outH, bitsPerComponent: 8,
            bytesPerRow: outW * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let output = context.makeImage() else {
            throw DocumentDetectionError.renderFailed
        }
        return output
    }
}
