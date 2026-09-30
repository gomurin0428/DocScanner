import Foundation

/// ファイル名のサニタイズに失敗した際のエラー。
enum FileNameError: LocalizedError {
    /// サニタイズ後のファイル名が空になった。
    case empty

    /// エラーの英語説明文を返す。
    var errorDescription: String? {
        switch self {
        case .empty:
            return "The file name is empty."
        }
    }
}

/// PDF ファイル名のサニタイズと既定名生成を行うユーティリティ。
enum FileNameSanitizer {

    /// ファイルシステムで使用不可の文字集合。
    private static let illegalCharacters = CharacterSet(charactersIn: "/\\:*?\"<>|")

    /// ユーザー入力の文字列を安全なファイル名（拡張子なし）へ変換する。
    /// - 入力: raw … ユーザー入力の生文字列
    /// - 出力: 不正文字を "-" に置き換え、末尾 ".pdf"（大小問わず）を除去した名前
    /// - 処理: 前後空白トリム → 末尾 .pdf 除去 → 不正文字置換 → 空なら throw
    /// - Throws: 結果が空文字なら FileNameError.empty
    static func sanitize(_ raw: String) throws -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".pdf") {
            name = String(name.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        name = name.components(separatedBy: illegalCharacters).joined(separator: "-")
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw FileNameError.empty
        }
        return name
    }

    /// 日時ベースの既定ファイル名を返す。
    /// - 入力: date … 基準日時
    /// - 出力: "Scan yyyy-MM-dd HH.mm.ss" 形式の文字列
    /// - 処理: DateFormatter で整形する（秒まで含める）
    static func defaultName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "Scan " + formatter.string(from: date)
    }
}
