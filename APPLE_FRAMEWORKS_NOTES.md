# APPLE_FRAMEWORKS_NOTES

DocScanner で使っている Apple フレームワークの使い方とハマりどころのメモ。

## VisionKit（VNDocumentCameraViewController）

- カメラ UI・自動エッジ検出・台形補正・ページめくりが全部入りの標準スキャナ。
- `VNDocumentCameraViewController.isSupported` で必ず事前チェックする。**シミュレータでは常に false**。
- delegate は 3 コールバックのみ：`didFinishWith:`（`VNDocumentCameraScan` → `pageCount` / `imageOfPage(at:)`）、`didCancel`、`didFailWithError:`。
- `NSCameraUsageDescription` が Info.plist 必須（本プロジェクトは `INFOPLIST_KEY_NSCameraUsageDescription` で生成）。
- SwiftUI では `UIViewControllerRepresentable` + `fullScreenCover` で包む。

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
- `CIColorThreshold`（iOS 14+）：平坦化後のグレーに対し `inputThreshold 0.88` で完全 2 値化（旧: 一律 0.5 は影のある紙を黒化させた）。
- **CIContext のワーキングスペースは sRGB 固定が必須**：`CIContext(options: [.workingColorSpace: sRGB])` で作る。上記の除算・レベル・閾値定数はガンマエンコード済み sRGB 空間で調整済みであり、デフォルト（リニア光）だと定数がずれて blackAndWhite に黒ノイズ斑点が出る。DocumentImageProcessor のみこのコンテキストを使う。
- `CIImage.oriented(.right/.down/.left)`：90° 回転。`right` = 時計回り 90°。負の回転数は mod 4 に正規化。
- `UIImage.imageOrientation != .up` の入力は CGImage が「生の向き」のままなので、先に UIGraphicsImageRenderer で .up に正規化する（これを怠ると検出・フィルタ・回転の座標が全てずれる）。
- `CIFilter(name:)` / `outputImage` は Optional → **force unwrap 禁止**。nil なら typed error を throw する。
- モルフォロジ・ブラーは extent が膨張するため、各段で `cropped(to: extent)` して最終出力も入力 extent にクロップしピクセルサイズを維持する（`UIImage(cgImage:scale:orientation:)` で元の scale 維持）。

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
- PhotosPicker：`loadTransferable(type: Data.self)` → `UIImage(data:)`。重い変換・検出は `Task.detached` でメインスレッド外へ。
- シェア：`ShareLink(item: fileURL)` で UIActivityViewController 相当が出せる（iOS 16+）。
