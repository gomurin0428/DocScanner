# history

## 2026-09-29T00:00:00+09:00
- 変更概要：DocScanner 新規作成。VisionKit ドキュメントカメラ + PhotosPicker インポート、VNDetectRectanglesRequest + CIPerspectiveCorrection による書類検出・台形補正、Core Image フィルタ（Enhanced/Grayscale/Black&White）・90°回転、ページ並べ替え・削除・追加編集、UIGraphicsPDFRenderer で A4/Letter/FitImage の PDF 生成、Documents/Scans への保存・一覧・リネーム・削除・共有、PDFKit プレビューを実装。XCTest 27 件追加。プロジェクトは objectVersion 77 + PBXFileSystemSynchronizedRootGroup 方式でフォルダ同期（ファイル追加時の pbxproj 編集不要）。
- 関連PR/コミット：初回作成（feature/2026-09-29-ios-document-scanner）
- 備考：xcode-select 先の Xcode 26.6 は iOS Simulator プラットフォーム未導入のため Xcode-27.0-RC でビルド・テスト。シミュレータはカメラ非搭載のため VNDocumentCameraViewController.isSupported=false → Scan ボタンはアラート表示で確認（実スキャンは要実機）。

## 2026-09-29T08:00:00+09:00
- 変更概要：レビュー指摘対応。DocumentStore.init を throws 化し DocScannerApp で do/catch → 失敗時「Storage Unavailable」画面。reload は属性欠損 missingFileAttributes / 読めない PDF unreadableDocument を throw（暗黙スキップ廃止）。PDFBuilder は pdfData クロージャが throw できないため JPEG 再エンコードを事前化し失敗時 jpegEncodingFailed。写真インポートを PageImporter に集約（loadFailed/decodeFailed、重複コード解消）。取り込み時に長辺 3000px へ縮小（カメラ/写真両経路）。EditorView.binding(for:) を id ルックアップ化して削除後 dismiss 中の stale index クラッシュを解消。Scan/Import/Save PDF を titleAndIcon 表示。テスト 6 件追加（計 33 件）。
- 関連PR/コミット：レビュー対応コミット（feature/2026-09-29-ios-document-scanner）
- 備考：PageRow のサムネイル失敗時は警告アイコン表示に変更（fail-fast）。

## 2026-09-29T12:00:00+09:00
- 変更概要：iOS 26 では `.bottomBar` ツールバー項目が `.labelStyle(.titleAndIcon)` を無視しアイコンのみ表示になる問題を修正。DocumentListView の Scan/Import と EditorView の Save PDF を `.safeAreaInset(edge: .bottom)` のフル幅ボタンに変更。PageImporterError.loadFailed を (index, message) 化し、loadTransferable の元エラーメッセージをアラートに含めるよう改修。
- 関連PR/コミット：レビュー対応コミット（feature/2026-09-29-ios-document-scanner）
- 備考：再インストール後のスクリーンショットで Scan/Import のタイトル表示を目視確認済み。

## 2026-09-29T20:00:00+09:00
- 変更概要：シミュレータ E2E で見つかった 2 件の不具合を修正。(1) DocumentDetector が Vision の正規化座標を y 反転させて CIPerspectiveCorrection に渡していたため補正結果が上下ミラー・歪み・背景混入になっていた問題を `y: p.y * height`（CIImage も左下原点）に修正。回帰テスト testCorrectedImageIsNotMirroredAndCropsToDocument を追加（旧実装で失敗確認済み）。実写真フィクスチャでの出力も目視確認。(2) PageEditView のフィルタ変更でプレビューが更新されない問題を修正。EditorView のカスタム Binding(get:set:) は SwiftUI の依存解決対象外で body 再評価されなかったため、編集状態をローカル @State で保持し onChange コールバックで親へ通知する設計に変更（binding(for:) 廃止）。TROUBLESHOOTING に両件の落とし穴を追記。テスト計 34 件。
- 関連PR/コミット：バグ修正コミット（feature/2026-09-29-ios-document-scanner）
- 備考：補正出力 /tmp/docscanner-evidence/corrected-output.png で正立・矩形化・書類領域のみ切り出しを確認。

## 2026-09-29T22:00:00+09:00
- 変更概要：PageEditView で 2 回目以降のフィルタ変更・回転がプレビューに反映されない問題を修正。原因はクロージャ遷移 `NavigationLink { PageEditView(page:) }` が親の pages 変更で新入力で再生成され、表示中ビューが状態/タスクから切り離されること。`@Observable final class DocumentDraft`（pages, page(id:), setFilter, rotate, remove, move, append, applyFilterToAll）を Model に新設し、EditorView は draft を共有、`NavigationLink(value:)` + `.navigationDestination(for: UUID.self)` で遷移先入力を固定。PageEditView は draft からページを読み編集を委譲、非同期レンダリング完了時に renderKey が変わっていれば古い結果を破棄。同様に Filter All で行ラベル・サムネイルが更新されない問題も PageRow を draft+pageID 参照化して解消。DocumentDraftTests 7 件追加（計 41 件）。
- 関連PR/コミット：バグ修正コミット（feature/2026-09-29-ios-document-scanner）
- 備考：ビルド/テストは iPhone 17 Pro (8EFCC0B0) + 専用 DerivedData-DocScanner-fix で実施（E2E 中の iPhone 17 D0B64A8A を汚さないため）。
