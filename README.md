# DocScanner

紙の書類をカメラでスキャンし、自動エッジ検出・台形補正・フィルタ適用・ページ管理を行い、PDF として保存・共有できる iOS アプリ（SwiftUI + AVFoundation + Vision + Core Image + PDFKit）。CamScanner 系のシンプルなドキュメントスキャナ。

## 機能

- **スキャン**: AVCaptureSession カメラによる手動シャッター撮影。安定した書類領域の曲線輪郭を緑枠で表示し、シャッター時の同じ輪郭を写真の画角・向きへ変換して補正する。撮影後の対象再検出は行わず、枠なし撮影は全文画像を使うか確認する
- **写真インポート**: PhotosPicker 複数選択（選択順を保持）→ 矩形・書類領域を検出して補正。矩形が見つからない折れた紙も、信頼度と形状を検証した書類領域を使用。VNDetectDocumentSegmentationRequest のマスクが取得でき選択候補と一致すれば輪郭追跡で湾曲した紙の辺も直線化（曲線輪郭 → Coons パッチ矩形化）。未検出時は「Use Full Image / Cancel」を確認し、選択に応じても入力順を維持
- **編集**: ページごとのフィルタ（Original / Enhanced / Grayscale / Black & White［適応閾値+AA］）、左右 90° 回転、削除、並べ替え（ドラッグ）、全ページ一括フィルタ、ページ追加
- **紙面内の補正**: 同梱の UVDoc（Core ML）で縦横の歪みを推定し、撮影時の輪郭を維持して端末内で補正。モデルを適用できない場合は輪郭・文字列による補正へ戻る。検出済みページは陰影補正を含む Enhanced を初期選択し、Original に切り替えると色調補正を外せる。モデルの出典・再生成は [Tools/UVDoc](Tools/UVDoc/README.md) を参照
- **PDF 出力**: A4 / Letter（画像寸法が用紙と一致しても 18pt マージン aspect-fit 中央配置）/ Fit to Image（端まで描画）、JPEG 再エンコードでファイルサイズ抑制
- **管理**: Documents/Scans に保存、一覧表示（サムネイル・日時・ページ数・サイズ）、リネーム・削除・共有（ShareLink）、PDFKit プレビュー

緑枠での撮影は、シャッターボタンに指が触れた瞬間の描画済み輪郭を固定し、指を離したときに撮影します。押下中に検出が途切れても、固定した範囲を補正に使います。

## 学習型の陰影補正

Enhanced / Grayscale / Black & White は、歪み補正後に同梱の DocRes を端末内で実行します。
モデルの出力画像を直接使わず、平滑化した明るさの比率を元の解像度の画素へ掛け、既存の階調・適応二値化処理へ渡します。
モデルの読み込み・推論失敗、非有限値、補正量の異常、小さい画像や低コントラスト画像、実機で処理用メモリの余裕が少ない場合は従来の Core Image 処理へ戻ります。
Original は陰影補正を行いません。直接の学習型二値化は、比較で QR やロゴの欠落が出たため採用していません。
モデルの出典・再生成・比較条件と制限は [Tools/DocRes](Tools/DocRes/README.md) を参照してください。

## 必要環境

- Xcode 27 以降（動作確認: Xcode 27 RC / iOS 26.5 シミュレータ）
- デプロイメントターゲット: iOS 17.0+
- **実機推奨**: ドキュメントスキャンにはカメラが必要。シミュレータでは `AVCaptureDevice.default(for: .video)` が無いため Scan ボタンでアラートが出る（写真インポート・PDF 編集・保存はシミュレータでも動作）

## 使い方

1. `DocScanner.xcodeproj` を Xcode で開く
2. スキーム `DocScanner`、実機またはシミュレータを選択して Run（⌘R）
3. 初回起動時にカメラ権限を許可 → Scan で書類を撮影 → 編集画面で名前・フィルタ・ページ順を調整 → Save PDF

## テスト

```sh
xcodebuild -project DocScanner.xcodeproj -scheme DocScanner \
  -destination 'platform=iOS Simulator,id=<UDID>' test
```

`PDFBuilderTests` / `DocumentImageProcessorTests` / `DocumentDetectorTests` / `PageFlattenerTests` / `CameraCaptureViewTests` / `CameraControllerTests` / `FileNameSanitizerTests` / `DocumentStoreTests` / `DocumentDraftTests` / `PageImporterTests` が実行される。

## 構成

| パス | 役割 |
| --- | --- |
| `DocScanner/App/` | @main エントリポイント。詳細は `DocScanner/App/README.md` |
| `DocScanner/Model/` | ScannedPage / PageFilter / PDFPageSize |
| `DocScanner/Processing/` | Core Image フィルタ・回転、Vision 書類検出 + 台形補正 |
| `DocScanner/PDF/` | UIGraphicsPDFRenderer による PDF 生成 |
| `DocScanner/Storage/` | ファイル名サニタイズ、Documents/Scans ストア |
| `DocScanner/Views/` | SwiftUI 画面群（一覧・カメラ・編集・プレビュー） |
| `DocScanner/Assets.xcassets/` | AppIcon（1024x1024 不透明）・AccentColor |
| `DocScannerTests/` | ユニットテスト（各テストの説明は `DocScannerTests/README.md`） |
| `DocScanner.xcodeproj/` | Xcode プロジェクト（objectVersion 77、フォルダ同期グループ方式） |
| `APPLE_FRAMEWORKS_NOTES.md` | VisionKit / Vision / Core Image / PDFKit の使い方とハマりどころ |
| `TROUBLESHOOTING.md` | ビルド・実行時のトラブルと対処 |
| `history.md` | 変更履歴（JST・秒精度） |

## 配布（TestFlight / App Store）

- アーカイブ（Xcode 27 RC、署名は App Store Connect API キーで自動管理）:

```sh
/Applications/Xcode-27.0-RC.app/Contents/Developer/usr/bin/xcodebuild \
  -project DocScanner.xcodeproj -scheme DocScanner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath ~/builds/DocScanner.xcarchive \
  archive -allowProvisioningUpdates \
  -authenticationKeyPath ~/.appstoreconnect/private_keys/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8 \
  -authenticationKeyID "$APP_STORE_CONNECT_API_KEY_ID" \
  -authenticationKeyIssuerID "$APP_STORE_CONNECT_API_ISSUER_ID"
```

- エクスポート: `xcodebuild -exportArchive -exportOptionsPlist`（method=app-store-connect）。
- 輸出コンプライアンス: 暗号化は非該当（`ITSAppUsesNonExemptEncryption = NO`、
  Debug/Release 両構成に設定済み）。
