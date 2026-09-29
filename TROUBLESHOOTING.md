# TROUBLESHOOTING

## 症状
- `xcodebuild`（Xcode 26.6、`/Applications/Xcode.app`）が iOS Simulator 宛先を 1 件も認識せず
  `error: iOS 26.5 is not installed` となる
- シミュレータで Scan ボタンを押してもカメラが起動せず
  「The document camera is not available on this device.」とだけ表示される

## 前提条件
- macOS 26、xcode-select は `/Applications/Xcode.app`（Xcode 26.6）
- iOS 26.5 ランタイム上の iPhone 17 シミュレータ使用

## 再現手順
1. `xcodebuild -project DocScanner.xcodeproj -scheme DocScanner -showdestinations` → iOS Sim が 0 件
2. シミュレータでアプリを起動 → Scan ボタン → アラートのみ

## 原因候補と切り分け
- Xcode 26.6 側の iOS プラットフォームコンポーネントが未インストール
  （`/Applications/Xcode-27.0-RC.app` の xcodebuild では全シミュレータが見える）
- シミュレータにはカメラハードが存在しないため `VNDocumentCameraViewController.isSupported` が常に false
  （VisionKit の制約でありアプリ側の不具合ではない）

## 対処
- ビルド/テスト：`/Applications/Xcode-27.0-RC.app/Contents/Developer/usr/bin/xcodebuild` を直接使い、
  destination は `-destination 'platform=iOS Simulator,id=<UDID>'` で明示する
- Scan の動作確認：実機が必要。シミュレータでは Import（写真）→ 検出 → 編集 → PDF 保存の流れで確認する
- 恒久：Xcode 26.6 を使うなら Settings > Components で iOS プラットフォームを再導入

## 症状（プロジェクト構成関連）
- pbxproj を手書きで作ると「ファイルを追加してもビルドに入らない」運用負荷が高い

## 対処
- objectVersion 77 + `PBXFileSystemSynchronizedRootGroup` を採用し、
  `DocScanner/` `DocScannerTests/` 配下はファイルを置くだけでターゲットに含まれる。
  Xcode 27 RC でビルド・テスト成功を確認済み（Xcode 15 未満では開けない点に注意）。

## 症状（書類検出の座標系）
- 写真インポートした書類が上下ミラーになり、歪んだまま暗い背景込みで切り出される

## 原因候補と切り分け
- `DocumentDetector` が Vision の正規化座標を `y: (1 - p.y) * height` で UIKit 流に反転させてから
  `CIPerspectiveCorrection` に渡していた。CIImage 座標系も左下原点のため反転は不要であり、
  反転した四点を渡すと補正後画像が上下反転し背景も混入する

## 対処
- `CGPoint(x: p.x * width, y: p.y * height)`（= `VNImagePointForNormalizedPoint` 相当）で変換する。
  回帰テスト `testCorrectedImageIsNotMirroredAndCropsToDocument`（黒マーカーで上下を区別）で検出する

## 症状（SwiftUI 画面遷移）
- PageEditView で Filter を変えてもプレビューが更新されない
  （セグメントの選択だけ変わる）。親へ状態を通知する方式に変えても
  初回の変更だけ反映され、2 回目以降（フィルタ・回転）が古いままになる

## 原因候補と切り分け
- 第 1 段階: EditorView が渡していたカスタム `Binding(get:set:)` は SwiftUI の
  依存解決対象にならず、set しても PageEditView の body が再評価されない
- 第 2 段階: `NavigationLink { PageEditView(page: ...) }` のクロージャ遷移だと
  親の pages 変更で遷移先が新しい入力で再生成され、表示中ビューが
  レンダリングを行う状態/タスクから切り離される

## 対処
- ページ集合を `@Observable final class DocumentDraft`（参照型）で共有し、
  PageEditView は body で draft から現在ページを読み、編集は draft メソッドへ委譲。
  非同期レンダリング完了時に renderKey が変わっていれば古い結果を捨てる。
  削除済みアクセスは空表示にする（削除ボタン側の dismiss に任せ、二重 dismiss しない）
- 遷移は item ベースで統一する（ルート側が `.navigationDestination(item:)` のとき
  子側で `NavigationLink(value:)` + `.navigationDestination(for:)` を混在させると、
  値の解決が壊れて EditorView 自身が再 push される）。EditorView は
  `editingPageID: UUID?` を行タップでセットし `.navigationDestination(item:)` で遷移。
  行は Button+chevron ラベルにして `.onMove`/`.onDelete` を維持する
- 関連して PageRow もページ値ではなく draft+pageID で受け取る（Filter All で
  親配列が丸ごと差し替わっても行ラベル・サムネイルが Observation で更新され、
  `.task(id: thumbnailKey)` が再発火する）
