# history

## 2026-09-29T00:00:00+09:00
- 変更概要：DocScanner 新規作成。VisionKit ドキュメントカメラ + PhotosPicker インポート、VNDetectRectanglesRequest + CIPerspectiveCorrection による書類検出・台形補正、Core Image フィルタ（Enhanced/Grayscale/Black&White）・90°回転、ページ並べ替え・削除・追加編集、UIGraphicsPDFRenderer で A4/Letter/FitImage の PDF 生成、Documents/Scans への保存・一覧・リネーム・削除・共有、PDFKit プレビューを実装。XCTest 27 件追加。プロジェクトは objectVersion 77 + PBXFileSystemSynchronizedRootGroup 方式でフォルダ同期（ファイル追加時の pbxproj 編集不要）。
- 関連PR/コミット：初回作成（feature/2026-09-29-ios-document-scanner）
- 備考：xcode-select 先の Xcode 26.6 は iOS Simulator プラットフォーム未導入のため Xcode-27.0-RC でビルド・テスト。シミュレータはカメラ非搭載のため VNDocumentCameraViewController.isSupported=false → Scan ボタンはアラート表示で確認（実スキャンは要実機）。

## 2026-09-29T08:00:00+09:00
- 変更概要：レビュー指摘対応。DocumentStore.init を throws 化し DocScannerApp で do/catch → 失敗時「Storage Unavailable」画面。reload は属性欠損 missingFileAttributes / 読めない PDF unreadableDocument を throw（暗黙スキップ廃止）。PDFBuilder は pdfData クロージャが throw できないため JPEG 再エンコードを事前化し失敗時 jpegEncodingFailed。写真インポートを PageImporter に集約（loadFailed/decodeFailed、重複コード解消）。取り込み時に長辺 3000px へ縮小（カメラ/写真両経路）。EditorView.binding(for:) を id ルックアップ化して削除後 dismiss 中の stale index クラッシュを解消。Scan/Import/Save PDF を titleAndIcon 表示。テスト 6 件追加（計 33 件）。
- 関連PR/コミット：レビュー対応コミット（feature/2026-09-29-ios-document-scanner）
- 備考：PageRow のサムネイル失敗時は警告アイコン表示に変更（fail-fast）。
