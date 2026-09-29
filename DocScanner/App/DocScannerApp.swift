import SwiftUI

/// DocScanner アプリのエントリポイント。DocumentStore を生成してルートビューへ注入する。
@main
struct DocScannerApp: App {
    /// アプリ全体で共有する保存済みドキュメントのストア。
    @State private var store = DocumentStore()

    /// ルートシーンを返す。
    /// - 入力: なし
    /// - 出力: DocumentListView をルートに持つ WindowGroup
    /// - 処理: DocumentStore を environment 経由でビュー階層へ注入する
    var body: some Scene {
        WindowGroup {
            DocumentListView()
                .environment(store)
        }
    }
}
