import Foundation

/// 編集中ドキュメントのページ集合を保持する下書きモデル。
/// @Observable のため参照を共有する全ビューが pages の変更を購読できる。
@Observable final class DocumentDraft {

    /// 編集中のページ一覧。
    var pages: [ScannedPage]

    /// 下書きを初期化する。
    /// - 入力: pages … 初期ページ配列
    /// - 出力: 初期化済み DocumentDraft
    /// - 処理: pages を保持する
    init(pages: [ScannedPage]) {
        self.pages = pages
    }

    /// 指定 id のページを返す。
    /// - 入力: id … ページ識別子
    /// - 出力: 見つかったページ。削除済みなどで見つからない場合は nil
    /// - 処理: pages を線形探索する
    func page(id: UUID) -> ScannedPage? {
        pages.first { $0.id == id }
    }

    /// 指定ページのフィルタを設定する。
    /// - 入力: filter … 設定するフィルタ、id … 対象ページ識別子
    /// - 出力: なし
    /// - 処理: id が見つからない場合は何もしない（削除直後の UI 一時状態を許容する）
    func setFilter(_ filter: PageFilter, for id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].filter = filter
    }

    /// 指定ページを時計回りに回転する。
    /// - 入力: quarterTurns … 90 度回転の回数（負値は反時計回り）、id … 対象ページ識別子
    /// - 出力: なし
    /// - 処理: id が見つからない場合は何もしない（削除直後の UI 一時状態を許容する）
    func rotate(by quarterTurns: Int, for id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].quarterTurns += quarterTurns
    }

    /// 指定ページを削除する。
    /// - 入力: id … 削除対象のページ識別子
    /// - 出力: なし
    /// - 処理: 該当要素を pages から除去する
    func remove(id: UUID) {
        pages.removeAll { $0.id == id }
    }

    /// ページを並べ替える。
    /// - 入力: source … 移動元インデックス集合、destination … 移動先インデックス
    /// - 出力: なし
    /// - 処理: pages に対して move(fromOffsets:toOffset:) を適用する
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        pages.move(fromOffsets: source, toOffset: destination)
    }

    /// ページを末尾へ追加する。
    /// - 入力: newPages … 追加するページ配列
    /// - 出力: なし
    /// - 処理: pages へ append する
    func append(_ newPages: [ScannedPage]) {
        pages.append(contentsOf: newPages)
    }

    /// 全ページに同一フィルタを適用する。
    /// - 入力: filter … 適用するフィルタ
    /// - 出力: なし
    /// - 処理: pages の各要素の filter を書き換える
    func applyFilterToAll(_ filter: PageFilter) {
        for index in pages.indices {
            pages[index].filter = filter
        }
    }
}
