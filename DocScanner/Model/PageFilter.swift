import Foundation

/// ページに適用する画像フィルタの種類。
enum PageFilter: String, CaseIterable, Identifiable {
    /// フィルタなし（撮影画像そのまま）。
    case original
    /// コントラスト・彩度を強めシャープ化した強調フィルタ。
    case enhanced
    /// 彩度 0 のグレースケール。
    case grayscale
    /// 2 値化した白黒フィルタ。
    case blackAndWhite

    /// Identifiable 準拠用の id。rawValue をそのまま返す。
    var id: String { rawValue }

    /// UI 表示用の英語名を返す。
    /// - 入力: なし
    /// - 出力: フィルタの表示名
    /// - 処理: ケースごとの固定文字列を返す
    var displayName: String {
        switch self {
        case .original: return "Original"
        case .enhanced: return "Enhanced"
        case .grayscale: return "Grayscale"
        case .blackAndWhite: return "Black & White"
        }
    }
}
