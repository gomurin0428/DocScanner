import CoreGraphics
import Foundation

/// PDF 出力時のページサイズ。
enum PDFPageSize: CaseIterable, Identifiable {
    /// A4 縦（595 x 842 pt）。
    case a4
    /// US Letter 縦（612 x 792 pt）。
    case letter
    /// 画像サイズをそのままページサイズにする。
    case fitImage

    /// Identifiable 準拠用の id。表示名をそのまま返す。
    var id: String { displayName }

    /// UI 表示用の英語名を返す。
    /// - 入力: なし
    /// - 出力: ページサイズの表示名
    /// - 処理: ケースごとの固定文字列を返す
    var displayName: String {
        switch self {
        case .a4: return "A4"
        case .letter: return "Letter"
        case .fitImage: return "Fit to Image"
        }
    }

    /// 用紙サイズ（pt）を返す。fitImage は画像依存のため nil。
    /// - 入力: なし
    /// - 出力: 固定サイズの場合はその CGSize、fitImage は nil
    /// - 処理: ケースごとの定数を返す
    var fixedSize: CGSize? {
        switch self {
        case .a4: return CGSize(width: 595, height: 842)
        case .letter: return CGSize(width: 612, height: 792)
        case .fitImage: return nil
        }
    }
}
