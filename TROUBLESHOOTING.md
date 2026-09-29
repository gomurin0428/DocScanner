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
- PageEditView で Filter を Enhanced/Grayscale/Black & White に変えてもプレビューが更新されない
  （セグメントの選択だけ変わる）

## 原因候補と切り分け
- EditorView が渡していたカスタム `Binding(get:set:)` は SwiftUI の依存解決対象にならず、
  set しても PageEditView の body が再評価されない。結果 `.task(id: renderKey)` が再発火せず
  プレビューが古いままになる

## 対処
- 編集ビューはページをローカル `@State` で保持し、変更を `onChange` コールバックで親へ通知する
  （`PageEditView.init(page:onChange:onDelete:)`）。親は id で配列要素を差し替える。
  削除後の dismiss 中の stale index クラッシュ対策も同時に解消される
