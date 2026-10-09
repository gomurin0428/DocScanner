import SwiftUI

/// DocScanner アプリのエントリポイント。DocumentStore を生成してルートビューへ注入する。
@main
struct DocScannerApp: App {
    /// アプリ全体で共有する保存済みドキュメントのストア。初期化失敗時は nil。
    private let store: DocumentStore?
    /// ストア初期化に失敗した場合のエラー。
    private let storeError: Error?

    /// アプリを初期化する。
    /// - 入力: なし
    /// - 出力: 初期化済み DocScannerApp
    /// - 処理: DocumentStore を生成する。失敗時はエラーを保持し、
    ///   ストアなしで起動してエラー画面を表示する
    init() {
        do {
            store = try DocumentStore(loadExisting: false)
            storeError = nil
        } catch {
            store = nil
            storeError = error
        }
    }

    /// ルートシーンを返す。
    /// - 入力: なし
    /// - 出力: DocumentListView（正常時）またはエラー画面（ストア初期化失敗時）を持つ WindowGroup
    /// - 処理: store があれば一覧画面へ environment 注入し、なければエラー内容を表示する
    var body: some Scene {
        WindowGroup {
            if let store {
                DocumentListView()
                    .environment(store)
            } else {
                ContentUnavailableView(
                    "Storage Unavailable",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(storeError?.localizedDescription ?? "")
                )
            }
        }
    }
}
