# history

## 2026-10-01T10:14:43+09:00
- 書類検出の最小サイズ・縦横比・角度条件を見直し、最大 8 候補から面積×信頼度で選ぶ処理を静止画とカメラで共通化。seg の湾曲補正は、優先候補と一致した場合に適用。
- カメラ映像と緑枠の safe area を揃え、セッション構成後にもプレビュー接続の回転を設定。小さい紙・レシート・複数候補の回帰テストを追加。実機での位置合わせ・実写の検出精度は別途確認が必要。
- 検証: 指定シミュレータ focused tests 13/13、generic iOS Release build 成功、全テスト 63/63。全テスト後の simulator 診断収集は 600 秒でタイムアウトしたが `TEST SUCCEEDED`。SwiftLint 実行ファイル・構成なし。

## 2026-10-01T11:20:59+09:00
- 変更概要：seg のフラット化一致ゲートを `DocumentRectangleDetector.preferred(in:)` で選んだ優先候補だけに限定。優先候補以外との一致で別シートを採用する経路を除去。Vision の共有検出設定と静止画・ライブプレビューでの共通利用を文書化。
- 検証：`DocumentDetectorTests` 7/7 pass、generic iOS Release build 成功。

## 2026-09-30T20:07:13+09:00
- main の bb105458b557c0c30c7cf36fdaddc9df14591a21 から KDocScanner 1.0 (5) を署名・アーカイブ・エクスポートし、TestFlight 内部グループ Internal に配信。App Store Connect で VALID / IN_BETA_TESTING を確認。
- ビルド番号は CURRENT_PROJECT_VERSION=5 のビルド時指定。アプリのソース変更なし。実機カメラ確認は引き続き必要。

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

## 2026-09-29T17:34:34+09:00
- 変更概要：EditorView のページ行タップで Edit Page の上に新しい EditorView が再 push される遷移バグを修正。原因はルートの `.navigationDestination(item:)` と子側の `NavigationLink(value:)` + `.navigationDestination(for:)` の混在。遷移を item ベースに統一（行タップで `editingPageID` をセットし `.navigationDestination(item:)` で遷移、行は Button+chevron で `.onMove`/`.onDelete` を維持）。PageEditView の削除は dismiss→remove の順にし、削除済み表示での自動 dismiss を除去して二重 dismiss（親まで pop し draft 喪失）を防止。
- 関連PR/コミット：バグ修正コミット（feature/2026-09-29-ios-document-scanner）
- 備考：テストは `-parallel-testing-enabled NO` で実行（クローンシミュレータ生成防止）。

## 2026-09-29T18:55:22+09:00
- 変更概要：TestFlight 配布準備。アプリターゲットの Debug/Release 両構成に `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO` を追加（輸出コンプライアンス＝暗号化非該当）。README に配布セクション（アーカイブコマンド・エクスポート・輸出コンプライアンス）を追加。
- 関連PR/コミット：TestFlight 準備コミット（feature/2026-09-29-ios-document-scanner）
- 備考：アーカイブ・エクスポートは App Store Connect API キー + -allowProvisioningUpdates で自動署名。

## 2026-09-29T19:07:00+09:00
- 変更概要：実機で Save PDF が「The file couldn't be saved.」になる不具合を修正。contentsOfDirectory が symlink 解決後パスを返すため URL 等価照合が失敗していた。save/rename の一覧照合と uniqueURL の excluding 判定を lastPathComponent 比較に変更。裸の CocoaError を DocumentStoreError.savedDocumentNotFound/renamedDocumentNotFound に置換。回帰テスト testSymlinkedDirectorySaveAndRename 追加（symlink 親経由で修正前に Code=512 失敗を確認）。
- 関連PR/コミット：バグ修正コミット（feature/2026-09-29-ios-document-scanner）
- 備考：シミュレータでは一時ディレクトリへの symlink で再現（親を symlink にし init は子ディレクトリを作成）。

## 2026-09-29T19:10:44+09:00
- 変更概要：実写真で enhanced/白黒フィルタが破綻する問題を改善。背景推定による陰影除去（ShadingCorrector: 長辺512px縮小→CIMorphologyMaximum r6→CIGaussianBlur r12→復元→CIDivideBlendMode で image/background 平坦化）を共通前段として導入し、レベル補正（CIColorMatrix→CIColorClamp→CIGammaAdjust）を各フィルタ定数で適用（enhanced 0.12/0.92/1.3+彩度1.15+シャープ0.5r1.5、grayscale 0.1/0.92/1.2、blackAndWhite 0.0/0.95/1.0→閾値0.88）。旧一律閾値0.5を廃止。回帰テスト3件追加（陰影付き合成紙、旧実装で下部紙黒化=0.0を確認）。Processing README・APPLE_FRAMEWORKS_NOTES・tests README 更新。
- 関連PR/コミット：フィルタ改善コミット（feature/2026-09-29-ios-document-scanner）
- 備考：実写診断 JPEG は /Users/devin/diag/{original,enhanced,grayscale,blackAndWhite}.jpg に出力済み。

## 2026-09-29T19:15:00+09:00
- 変更概要：DocumentImageProcessor の CIContext を workingColorSpace=sRGB 固定に変更。陰影除去・レベル補正・閾値の定数はガンマエンコード済み sRGB で調整済みであり、デフォルトのリニア光ワーキングスペースでは除算/閾値結果がずれて blackAndWhite に黒ノイズ斑点が出ていたため。DocumentDetector のコンテキストは変更なし。ZZDiag を再実行し診断 JPEG を再生成。
- 関連PR/コミット：フィルタ色空間修正コミット（feature/2026-09-29-ios-document-scanner）
- 備考：APPLE_FRAMEWORKS_NOTES・TROUBLESHOOTING に sRGB ワーキングスペース依存の注意を追記。

## 2026-09-29T19:20:00+09:00
- 変更概要：TestFlight へ build 2 を配布するため CURRENT_PROJECT_VERSION を 1→2 に更新（アプリ/テストターゲットの Debug+Release 全構成、MARKETING_VERSION は 1.0 のまま）。アーカイブ・エクスポート・altool でのアップロードを App Store Connect API キーで実施。
- 関連PR/コミット：バージョン更新コミット（feature/2026-09-29-ios-document-scanner）
- 備考：アップロード後は /v1/builds API で processingState=VALID / internalBuildState=IN_BETA_TESTING を確認。

## 2026-09-29T20:35:00+09:00
- 変更概要：紙の湾曲・反り輪郭を追跡してページを正確な矩形へ引き伸ばすフラット化を追加。VNDetectDocumentSegmentationRequest の四角形+セグメンテーションマスクを使い、各辺の外向き法線をマスク走査→輝度エッジ精緻化→平滑化し、ホモグラフィ空間の Coons パッチで一括リサンプルする PageFlattener/PageGeometry を新設。実環境で seg モデルが退化四角形を返すプラットフォーム差（シミュレータで下端帯の quad を高信頼度で返す）を確認したため、VNDetectRectanglesRequest の四角形と 4 隅距離 ≤8% で一致する場合のみフラット化を採用（quadsAgree ゲート）。新規テスト PageFlattenerTests 3 件 + quadsAgree 1 件。macOS CLI 移植検証では実写が 1948x2688 でプロトタイプと一致（diff mean 0.89）。CURRENT_PROJECT_VERSION=3。
- 関連PR/コミット：フラット化機能コミット（feature/2026-09-29-ios-document-scanner）
- 備考：シミュレータでは常に矩形検出フォールバック経路になる（seg quad が不一致のため）。実機でのフラット化は要実写確認。

## 2026-09-29T21:00:00+09:00
- 変更概要：blackAndWhite フィルタをハードなグローバル閾値（CIColorThreshold 0.88）から適応閾値+アンチエイリアス化へ変更。平坦化グレー g に対し local=CIGaussianBlur(r=0.008×max(W,H)) を取り、g/local の比を ramp(0.78,0.94)・g を ramp(0.45,0.70) でそれぞれランプし CIMinimumCompositing で min 合成。細線・薄い文字が消える実機報告への対応（出力は厳密 2 値ではなく AA 付き）。ShadingCorrector.ramp を新設し levels を ramp 上に再構成。旧 testBlackAndWhiteProducesBinaryPixels を testBlackAndWhiteKeepsFaintThinStrokes へ置換。
- 関連PR/コミット：フィルタ改善コミット（feature/2026-09-29-ios-document-scanner）
- 備考：testBlackAndWhiteLiftsShadedPaper は無変更でパスを確認。

## 2026-09-29T21:15:00+09:00
- 変更概要：VNDocumentCameraViewController（自動キャプチャ）を自前の AVCaptureSession カメラへ置き換え、撮影タイミングをユーザー操作の手動シャッターへ変更。実機で「指が写り込んだ状態で自動撮影される」報告への対応（VisionKit にシャッター任意化 API が無い）。CameraController（@Observable、.photo プリセット + maxPhotoDimensions=フォーマット最大 + 品質優先、AVCaptureVideoDataOutput で 3 フレーム毎に VNDetectRectanglesRequest 実行して検出四角形のみ公開）と CameraCaptureView（フルスクリーン aspectFill プレビュー + 緑 quad オーバレイ + 手動シャッター + 枚数/サムネイル + Done/Cancel + 白フラッシュ）を新設。権限拒否時は Open Settings 導線アラート、カメラ非搭載（シミュレータ）は既存アラートを AVCaptureDevice 判定へ変更。撮影画像は PageImporter.makePages と同じ検出パイプライン（seg フラット化含む）へ流すため、handleImages を両ビューの importItems から切り出して共通化。DocumentCameraView.swift と VisionKit import を削除。overlayPoints（y-up 正規化→aspect-fill ビュー座標）を static 化し CameraCaptureViewTests 3 件追加。CURRENT_PROJECT_VERSION=4。
- 関連PR/コミット：カメラ置換コミット（feature/2026-09-29-ios-document-scanner）
- 備考：カメラ UI 自体はシミュレータで動作確認不可（デバイス無し）。generic/platform=iOS でのコンパイル確認を実施。

## 2026-09-30T10:02:35+09:00
- 変更概要：機能レビュー指摘 7 件を検証し、6 件を修正。sanitize 後の同名 rename を no-op 化し、symlink 名比較を維持。複数削除は reload 前に対象をスナップショット。固定 A4/Letter PDF の余白判定を PDFPageSize のみに基づかせ、.fitImage は全面描画を維持。ImportResult を入力順 Entry に変更し、Use Full Image / Cancel の両経路で順序を保持。カメラの configure/start/stop を sessionQueue で直列化して世代ガードを導入し、capture pending と完了/エラーを MainActor 上で一括更新。上下反転の指摘は再現せず、PageFlattener の top-origin 非対称マーカー回帰テストを追加し、PageBitmap.draw の向きは変更せず確認。関連 README と TROUBLESHOOTING を更新。
- 検証：Xcode 27 RC / iOS Simulator D0B64A8A でフォーカス 29/29、全体 60/60 pass。generic/platform=iOS Release build 成功。
- 備考：シミュレータにカメラがないため物理カメラ UI は未検証。SwiftLint 実行ファイル/構成なし。
