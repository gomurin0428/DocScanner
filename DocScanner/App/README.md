# App フォルダ

アプリのエントリポイントを格納する。

## 型とメソッド一覧

| 型 | メソッド / プロパティ | 役割 |
| --- | --- | --- |
| `DocScannerApp` | `body` | @main の App。`DocumentStore` を生成し `DocumentListView` へ environment 注入する |
| `DocScannerApp` | `store` | アプリ全体共有のドキュメントストア（@State で保持） |

## クラス図

```mermaid
classDiagram
    class DocScannerApp {
        +store: DocumentStore
        +body: some Scene
    }
    DocScannerApp --> DocumentListView : ルートビュー
    DocScannerApp --> DocumentStore : environment 注入
```

## シーケンス図

```mermaid
sequenceDiagram
    participant OS as iOS
    participant App as DocScannerApp
    participant Store as DocumentStore
    participant List as DocumentListView
    OS->>App: 起動（body 評価）
    App->>Store: init（Documents/Scans 作成・reload）
    App->>List: DocumentListView() + .environment(store)
    List->>Store: documents 参照して一覧描画
```
