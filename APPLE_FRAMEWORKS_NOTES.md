# APPLE_FRAMEWORKS_NOTES

DocScanner で使っている Apple フレームワークの使い方とハマりどころのメモ。

## AVFoundation（カメラ撮影）

- **なぜ VisionKit を置き換えたか**：`VNDocumentCameraViewController` には撮影タイミングをユーザーへ委ねる API が無い（自動キャプチャのみ）。実機ユーザーの「指が写り込んだ状態で自動撮影された」報告を受け、AVCaptureSession + 手動シャッターの自前 UI（`CameraController` + `CameraCaptureView`）へ置き換えた。
- 構成：`AVCaptureSession`（`.photo` プリセット）+ 背面広角 `AVCaptureDeviceInput` + `AVCapturePhotoOutput` + `AVCaptureVideoDataOutput`。`maxPhotoDimensions` にはアクティブフォーマットの `supportedMaxPhotoDimensions` の最大を設定し、`maxPhotoQualityPrioritization = .quality`。
- 縦向き：撮影・プレビュー・ビデオ各接続で `isVideoRotationAngleSupported(90)` を確認し `videoRotationAngle = 90`。ビデオ出力接続が回転非対応の場合はバッファがセンサー横向きのままなので Vision へ `orientation: .right` を渡す（対応なら `.up`）。
- 写真：`AVCapturePhotoSettings()` で `capturePhoto(with:delegate:)` → `fileDataRepresentation()` → `UIImage(data:)`（EXIF 向きは UIImage が保持）。
- オーバレイ：直列キューの `AVCaptureVideoDataOutput` で 3 フレーム毎に `VNDetectRectanglesRequest`（DocumentDetector と同パラメータ）を実行し正規化四角形だけを公開（自動撮影はしない）。aspect-fill プレビューへの座標変換は `CameraCaptureView.overlayPoints`（y 反転 + 中央クロップオフセット）。
- 権限：`AVCaptureDevice.authorizationStatus(for: .video)` / `requestAccess`。denied/restricted は `UIApplication.openSettingsURLString` への導線アラート。`NSCameraUsageDescription` 必須（`INFOPLIST_KEY_NSCameraUsageDescription` で生成済み）。
- セッションの configure+startRunning は専用直列キューで連続実行し、stopRunning も同じキューへ積む。UI の `.task` が権限要求を所有し、await 後に cancellation と世代トークンを再確認するため、画面終了後に遅れて完了した権限/構成処理は開始・UI 更新を行わない。UI 準備状態は MainActor のみで更新する。
- 撮影開始時は MainActor で pending を同期設定し、最終 `didFinishCaptureFor` まで次のシャッターと Done を無効化する。処理 callback の画像/エラーと最終 callback の失敗をまとめて MainActor へ一度に配信し、処理 callback が欠けても pending を解除する。
- **シミュレータにはカメラデバイスが無い**ため `AVCaptureDevice.default(for: .video)` が nil → UI 側でアラート。

## VisionKit（VNDocumentCameraViewController）

- 旧スキャナ UI（ビルド 4 で削除済み）。カメラ UI・自動エッジ検出・台形補正・ページめくりが全部入りの標準スキャナだが、**シャッター任意化 API が無い**ため手動撮影要件には使えない。

## Vision（VNDetectRectanglesRequest）

- 写真インポート時の書類検出に使用。`VNImageRequestHandler(ciImage:)` で `perform`。
- パラメータ：`minimumConfidence 0.6`、`minimumAspectRatio 0.3`、`maximumObservations 1`、`quadratureTolerance 30`。
- **座標系の罠**：`VNRectangleObservation` の topLeft/topRight/bottomLeft/bottomRight は「左下原点の正規化座標(0〜1)」。CIImage も左下原点なので変換は `CGPoint(x: p.x * w, y: p.y * h)`（`VNImagePointForNormalizedPoint` 相当）。`(1 - p.y)` で反転すると補正画像が上下ミラーになる。
- `results` が空なら「検出できず」として明示的にエラーにし、UI 側で「Use Full Image / Cancel」のユーザー選択を取る（サイレントフォールバック禁止）。
- シミュレータでも動作するが、コントラストの低い合成画像では検出に失敗することがある。テストは「暗い背景 + 白い四角形」で十分なコントラストを確保する。

## CIPerspectiveCorrection

- 検出した 4 頂点を `inputTopLeft` / `inputTopRight` / `inputBottomLeft` / `inputBottomRight` に `CIVector(cgPoint:)` で渡す。
- 出力は補正済み矩形が正面から見た画像になる。`outputImage.extent` 全体を `CIContext.createCGImage` で焼く。
- 頂点の対応付けを間違える（左上/右上の入替など）と出力が回転・反転するので Vision の角名と 1:1 で対応させる。

## Core Image（フィルタ・回転）

- **陰影除去（ShadingCorrector）**：実写真では紙の一部が暗い影になるため、グローバル閾値や一律コントラストでは破綻する。背景（紙の明るさ）を「長辺 512px 縮小 → `CIMorphologyMaximum` r6（文字を消す）→ `CIGaussianBlur` r12 → 元サイズへ拡大」で推定し、`CIDivideBlendMode`（inputImage=背景, backgroundImage=元画像）で `image / background` として平坦化する。これが enhanced / grayscale / blackAndWhite の共通前段。
- **レベル補正**：`CIColorMatrix`（RGB スケール k=1/(white-black)、バイアス -black*k）→ `CIColorClamp` → `CIGammaAdjust(power)`。フィルタごとの定数：enhanced (0.12, 0.92, 1.3) + `CIColorControls` saturation 1.15 + `CISharpenLuminance` 0.5/r1.5、grayscale (0.1, 0.92, 1.2)、blackAndWhite (0.0, 0.95, 1.0) → `CIColorThreshold` 0.88。
- `CIColorControls`：`inputSaturation 0` でグレースケール、彩度補正にも使用。
- `CISharpenLuminance`：エッジを強調（enhanced 用）。`inputSharpness 0.5`、`inputRadius 1.5`。
- **blackAndWhite は適応閾値 + AA**（ビルド 4 で変更）：`local = CIGaussianBlur(g, r=0.008×max(W,H))` と `g/local` の比を `ramp(0.78,0.94)`、`g` を `ramp(0.45,0.70)` でランプし `CIMinimumCompositing` で min 合成。旧 `CIColorThreshold` 0.88 のハード閾値は薄い/細いストロークを白へ潰していた。`ramp` = CIColorMatrix + CIColorClamp。
- **CIContext のワーキングスペースは sRGB 固定が必須**：`CIContext(options: [.workingColorSpace: sRGB])` で作る。上記の除算・レベル・閾値定数はガンマエンコード済み sRGB 空間で調整済みであり、デフォルト（リニア光）だと定数がずれて blackAndWhite に黒ノイズ斑点が出る。DocumentImageProcessor のみこのコンテキストを使う。
- `CIImage.oriented(.right/.down/.left)`：90° 回転。`right` = 時計回り 90°。負の回転数は mod 4 に正規化。
- `UIImage.imageOrientation != .up` の入力は CGImage が「生の向き」のままなので、先に UIGraphicsImageRenderer で .up に正規化する（これを怠ると検出・フィルタ・回転の座標が全てずれる）。
- `CIFilter(name:)` / `outputImage` は Optional → **force unwrap 禁止**。nil なら typed error を throw する。
- モルフォロジ・ブラーは extent が膨張するため、各段で `cropped(to: extent)` して最終出力も入力 extent にクロップしピクセルサイズを維持する（`UIImage(cgImage:scale:orientation:)` で元の scale 維持）。

## VNDetectDocumentSegmentationRequest（書類領域セグメンテーション）

- iOS 15+。`VNRectangleObservation` を返し、`globalSegmentationMask`（低解像度 Float32 確率マスク、`kCVPixelFormatType_OneComponent32Float`）が取れる。マスクバッファは行が上から順。
- **プラットフォーム差が大きい**：本環境では macOS CLI は実写に conf 0.99 + 正しい四角形を返すが、iOS シミュレータ（26.5）はコンテンツ無関係に「画面下端 1/4 帯」程度の退化四角形を conf 0.83–0.99 で返す（無地画像でも 0.8 超）。同一画像・同一プロセスでも観測が変わることがある。実機では要検証だが、seg 結果は信用せず必ず別ソースで検証する設計にする。
- 対策: 先に `VNDetectRectanglesRequest` で四角形を確定させ、seg は `confidence >= 0.8` + マスクあり + 4 隅が検出四角形と max(W,H)×8% 以内（`DocumentDetector.quadsAgree`）のときだけ輪郭追跡フラット化に使う。Vision/VisionKit/Core Image に公開のデワープ API は無いため、マスク輪郭追跡 + ホモグラフィ空間 Coons パッチで自前実装（`PageFlattener`）。
- 輪郭追跡: 四角形各辺の外向き法線を −80..+80px 走査して mask≥0.5 の最外点を取り、±20px 内で内外 3px 平均輝度差（±2px ギャップ）が最大の位置で精緻化（>12 で採用）。メディアン5→移動平均7 で平滑化し 4px 内側へ寄せる。px 定数は max(W,H)/3000 でスケール。
- Coons パッチ: 4 辺を矩形空間へ写像（ホモグラフィ）し `(u,v) → 辺補間 + 辺補間 − 双線形補間` で内部を充填、逆ホモグラフィで元画像を双線形サンプル（1 回リサンプル）。出力サイズ = 写像後の上下辺平均弧長 × 左右辺平均弧長。

## UIGraphicsPDFRenderer

- 可変ページサイズ：レンダラ生成時の bounds はダミーでよく、`context.beginPage(withBounds:)` でページごとのサイズを指定する。
- A4(595x842) / Letter(612x792) は pt 固定。画像は 18pt マージン内に aspect-fit 中央配置。
- ファイルサイズ対策：`image.jpegData(compressionQuality: 0.8)` で再エンコードしてから `UIImage(data:)` 経由で `draw(in:)`。

## PDFKit

- 読み取り：`PDFDocument(url:)` / `PDFDocument(data:)` → `pageCount`、`page(at:)`、`bounds(for: .mediaBox)`。
- サムネイル：`PDFPage.thumbnail(of:for:)` で一覧用画像を簡単に生成できる。
- プレビュー：`PDFView`（`autoScales = true`）を `UIViewRepresentable` で包む。
- pageCount 取得が壊れた PDF では 0 を返すだけなので、ストア側では失敗を許容して 0 として扱う。

## その他

- `@Observable`（Observation フレームワーク、iOS 17+）：DocumentStore。View では `@Environment(DocumentStore.self)` で受ける。
- PhotosPicker：`selectionBehavior: .ordered` と `loadTransferable(type: Data.self)` → `UIImage(data:)` で明示的選択順を保持。`PageImporter` は検出済み/未検出の `ImportResult.Entry` を入力順で保持し、ユーザー選択後に順序を保ったページ列を再構成する。アラート表示 Bool と pending 結果は分離し、SwiftUI の自動 dismiss が未処理データを消さないようにする。重い変換・検出は `Task.detached` でメインスレッド外へ。
- シェア：`ShareLink(item: fileURL)` で UIActivityViewController 相当が出せる（iOS 16+）。
