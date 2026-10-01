# TROUBLESHOOTING

## 書類が見つからない・緑枠がずれる

- 最小サイズの既定値 0.2 と縦横比下限 0.3 は、小さく写った紙やレシートを除外する。macOS の Vision で 1000×1400 の暗背景に描いた 140×200 の紙と 180×1000 の紙は旧設定で 0 件、サイズ 0.1・縦横比 0.15 の新設定で検出できた。実写での精度を示す結果ではない。
- プレビューだけ `.ignoresSafeArea()` にすると、緑枠の GeometryReader と表示領域が異なる。プレビューと枠を同じ全画面 GeometryReader に置く。
- プレビュー生成時にはセッション接続がまだ無い場合がある。`isConfigured` の更新後にも接続回転を設定する。
- 複数の矩形は面積×信頼度で選ぶ。大きな画面や机などを紙と取り違える可能性は残る。低コントラストや紙の端が見切れた写真を必ず検出できるわけではない。
- 緑枠の実際の位置合わせと撮影中の検出性能は iPhone で確認する。シミュレータには物理カメラが無い。

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
- シミュレータにはカメラハードが存在しないため `AVCaptureDevice.default(for: .video)` が nil
  （ハード制約でありアプリ側の不具合ではない）

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

## 症状（実機・TestFlight）
- Save PDF で「The file couldn't be saved.」とエラーになる（PDF 自体は書き込まれている）。
  リネームでも同種のエラーになる。シミュレータでは再現しない

## 原因候補と切り分け
- `DocumentStore.save`/`rename` が保存後の一覧照合を URL 等価（`$0.url == url`）で
  行っていた。実機では `contentsOfDirectory` が symlink 解決後のパス
  （/var → /private/var 等）を返すため URL が一致せず、裸の
  `CocoaError(.fileWriteUnknown/.fileReadUnknown)` が投げられていた。
  `uniqueURL(for:excluding:)` の `candidate != excluding` も同種

## 対処
- 照合・除外判定は URL 等価ではなく `lastPathComponent`（ファイル名）で行う。
  裸の CocoaError は廃止し `DocumentStoreError.savedDocumentNotFound` /
  `.renamedDocumentNotFound`（ファイル名入り英語メッセージ）を投げる。
  回帰テスト `testSymlinkedDirectorySaveAndRename`（symlink 親ディレクトリ経由）で再現検証

# トラブルシューティング: blackAndWhite に黒いノイズ斑点が出る（レシピは正しいのに）

## 症状
- 陰影除去レシピ導入後も、実写真の blackAndWhite で影領域に黒い斑点ノイズが乗る。
  プロトタイプ（CLI）の出力とは明らかに違う

## 原因候補と切り分け
- フィルタ構成・定数はプロトタイプと一致。違いは CIContext の
  workingColorSpace のみ。デフォルト `CIContext()` はリニア光で演算するため、
  ガンマエンコード済み sRGB で調整した除算・レベル・閾値の定数がずれる

## 対処
- 定数がチューニングされた色空間と同じワーキングスペースを使う:
  `CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])`。
  DocumentImageProcessor のコンテキストのみこれに固定する（DocumentDetector は別物）。
- 一般化すれば「CI フィルタ定数はワーキングカラースペース依存」—
  閾値・レベル・除算レシピを移植するときはプロトタイプの context 設定も一緒に移植する

# トラブルシューティング: blackAndWhite で細い線・薄い文字が消える

## 症状
- 実機スキャンを白黒 PDF 化すると、薄い/細いストローク（ハイフン、漢字の横画、
  小さなレターヘッド文字）が消失する。手ブレで縦方向に滲んだ画素はさらに消えやすい

## 原因候補と切り分け
- 旧実装は平坦化グレーに対し `CIColorThreshold` 0.88 のハードなグローバル閾値を
  掛けていた。紙より少し暗いだけの細線（輝度 0.7–0.8 台）は一律で白へ潰れる

## 対処
- 適応閾値 + アンチエイリアス化に変更: `g/local`（local = ガウスぼかし、
  r = 0.008×max(W,H)）の比を ramp(0.78, 0.94) で 2 値化し、
  `ramp(g, 0.45, 0.70)` のグローバル側と `CIMinimumCompositing` で min 合成。
  細線は局所比で拾い、大きな黒領域のくり抜きはグローバル側で防ぐ。
  出力は厳密な 2 値ではなくアンチエイリアス付き
- 回帰テスト `testBlackAndWhiteKeepsFaintThinStrokes`（0.75 輝度の 2px 細線）で検証

# トラブルシューティング: シミュレータでインポート画像が下端帯だけに切り出される

## 症状
- 写真インポート後のページが画像下端 1/4 程度の帯だけになる（iOS シミュレータのみ、実機・macOS では正しい領域）

## 原因候補と切り分け
- `VNDetectDocumentSegmentationRequest` のプラットフォーム差。iOS シミュレータ（26.5）では
  コンテンツ無関係に画面下端帯程度の退化四角形を confidence 0.83–0.99 で返す
  （無地画像でも 0.8 超、同一画像で観測が変わることもある）。macOS では同一画像で
  conf 0.99 + 正しい四角形 + 144x256 マスクを返す
- マスクもほぼ全体が 0.8 前後の無意味値になり、quad の異常を補正できない

## 対処
- seg 観測を鵜呑みにしない。先に `VNDetectRectanglesRequest` で四角形を確定し、
  seg は `confidence >= 0.8` + `globalSegmentationMask` あり +
  `quadsAgree`（4 隅距離 ≤ max(W,H)×8%）を全て満たすときだけ
  輪郭追跡フラット化に使う。それ以外は CIPerspectiveCorrection に留める
- Vision 系リクエストの結果を別プラットフォームにそのまま期待しない（シミュレータの
  モデル出力は実機・macOS と異なり得る）

## 症状（混在写真のインポート順）
- 未検出画像に「Use Full Image / Cancel」を選ぶと、検出済みページと未検出ページの順序が選択順と違う

## 原因と対処
- 検出済み/未検出を別々の配列に保持すると interleave 情報を復元できない。`PhotosPicker`
  は `.ordered` を指定し、`ImportResult.Entry` を入力順に保持する。alert 表示状態は pending
  結果とは別の Bool にし、button handler が完了する前に dismiss setter で結果を消さない。

## 症状（画面を閉じた後にカメラが開始する／撮影中に Done できる）
- 権限要求またはセッション構成が非同期中にカメラ画面を閉じると、遅延完了した開始処理や UI 更新が残る
- 既存ページがある状態で次の写真を撮影中に Done が先に返る

## 原因と対処
- configure/start/stop を別キュー投入にすると開始と停止の順序が競合する。SwiftUI task の cancellation
  と同期的な generation token を権限 await 後・構成後に確認し、全セッション操作を同じ serial queue に置く。
  撮影は MainActor で pending を同期設定し、最終 `didFinishCaptureFor` に画像/error を一括反映する。
