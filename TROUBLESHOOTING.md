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
