# history

## 2026-09-29T00:00:00+09:00
- 変更概要：DocScanner 新規作成。VisionKit ドキュメントカメラ + PhotosPicker インポート、VNDetectRectanglesRequest + CIPerspectiveCorrection による書類検出・台形補正、Core Image フィルタ（Enhanced/Grayscale/Black&White）・90°回転、ページ並べ替え・削除・追加編集、UIGraphicsPDFRenderer で A4/Letter/FitImage の PDF 生成、Documents/Scans への保存・一覧・リネーム・削除・共有、PDFKit プレビューを実装。XCTest 27 件追加。プロジェクトは objectVersion 77 + PBXFileSystemSynchronizedRootGroup 方式でフォルダ同期（ファイル追加時の pbxproj 編集不要）。
- 関連PR/コミット：初回作成（feature/2026-09-29-ios-document-scanner）
- 備考：xcode-select 先の Xcode 26.6 は iOS Simulator プラットフォーム未導入のため Xcode-27.0-RC でビルド・テスト。シミュレータはカメラ非搭載のため VNDocumentCameraViewController.isSupported=false → Scan ボタンはアラート表示で確認（実スキャンは要実機）。
