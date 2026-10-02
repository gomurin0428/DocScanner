import UIKit

/// スキャン済み 1 ページの編集状態を保持するモデル。
struct ScannedPage: Identifiable, Hashable {
    /// ページの一意な識別子。
    let id: UUID
    /// 台形補正済みの元画像（フィルタ・回転は未適用）。
    var baseImage: UIImage
    /// 適用するフィルタ。
    var filter: PageFilter
    /// 時計回り 90 度回転の回数（負値は反時計回り）。
    var quarterTurns: Int

    /// 新しいスキャンページを生成する。
    /// - 入力: baseImage … 元画像、filter … 初期フィルタ（既定 .original）、quarterTurns … 初期回転数（既定 0）
    /// - 出力: 初期化済み ScannedPage
    /// - 処理: id を新規採番して各プロパティを設定する
    init(baseImage: UIImage, filter: PageFilter = .original, quarterTurns: Int = 0) {
        self.id = UUID()
        self.baseImage = baseImage
        self.filter = filter
        self.quarterTurns = quarterTurns
    }

    /// 識別子ベースの等価判定。
    /// - 入力: lhs / rhs … 比較対象
    /// - 出力: id が同じなら true
    /// - 処理: UIImage は比較できないため id のみで判定する
    static func == (lhs: ScannedPage, rhs: ScannedPage) -> Bool {
        lhs.id == rhs.id
    }

    /// 識別子ベースのハッシュ。
    /// - 入力: hasher … ハッシュ生成器
    /// - 出力: なし
    /// - 処理: id のみをハッシュへ混ぜる
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// 現在の編集状態（回転 + フィルタ）を適用した最終画像を返す。
    /// - 入力: processor … 画像処理エンジン（既定は新規インスタンス）
    /// - 出力: 回転・フィルタ適用後の UIImage
    /// - 処理: まず quarterTurns で回転し、続けて filter を適用する
    func renderedImage(using processor: DocumentImageProcessor = DocumentImageProcessor()) throws -> UIImage {
        let rotated = try processor.rotate(baseImage, quarterTurns: quarterTurns)
        return try processor.apply(filter, to: rotated)
    }

    /// サムネイル用に縮小してから回転とフィルタを適用した画像を返す。
    /// - 入力: processor … 画像処理エンジン（既定は新規インスタンス）
    /// - 出力: 長辺 224 px 以下の回転・フィルタ適用後 UIImage
    /// - 処理: 元画像を先に縮小し、続けて回転とフィルタを適用する
    func thumbnailImage(using processor: DocumentImageProcessor = DocumentImageProcessor()) throws -> UIImage {
        let downscaled = try processor.downscaled(baseImage, maxPixelDimension: 224)
        let rotated = try processor.rotate(downscaled, quarterTurns: quarterTurns)
        return try processor.apply(filter, to: rotated)
    }
}
