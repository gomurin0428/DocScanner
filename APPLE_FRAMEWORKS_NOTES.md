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
- **座標系の罠**：`VNRectangleObservation` の topLeft/topRight/bottomLeft/bottomRight は「左下原点の正規化座標(0〜1)」。Core Image のピクセル座標へは `CGPoint(x: p.x * w, y: (1 - p.y) * h)` で変換する。
- `results` が空なら「検出できず」として明示的にエラーにし、UI 側で「Use Full Image / Cancel」のユーザー選択を取る（サイレントフォールバック禁止）。
- シミュレータでも動作するが、コントラストの低い合成画像では検出に失敗することがある。テストは「暗い背景 + 白い四角形」で十分なコントラストを確保する。

## CIPerspectiveCorrection

- 検出した 4 頂点を `inputTopLeft` / `inputTopRight` / `inputBottomLeft` / `inputBottomRight` に `CIVector(cgPoint:)` で渡す。
- 出力は補正済み矩形が正面から見た画像になる。`outputImage.extent` 全体を `CIContext.createCGImage` で焼く。
- 頂点の対応付けを間違える（左上/右上の入替など）と出力が回転・反転するので Vision の角名と 1:1 で対応させる。

## Core Image（フィルタ・回転）

- `CIColorControls`：`inputSaturation 0` でグレースケール、`inputContrast 1.15 + inputSaturation 1.1` で強調。
- `CISharpenLuminance`：エッジを強調（enhanced 用）。`inputSharpness 0.4`。
- `CIColorThreshold`（iOS 14+）：`inputThreshold 0.5` で完全 2 値化。前段にグレースケール + コントラスト強化を入れると綺麗。
- `CIImage.oriented(.right/.down/.left)`：90° 回転。`right` = 時計回り 90°。負の回転数は mod 4 に正規化。
- `UIImage.imageOrientation != .up` の入力は CGImage が「生の向き」のままなので、先に UIGraphicsImageRenderer で .up に正規化する（これを怠ると検出・フィルタ・回転の座標が全てずれる）。
- `CIFilter(name:)` / `outputImage` は Optional → **force unwrap 禁止**。nil なら typed error を throw する。
- 出力ピクセルサイズを保つため `UIImage(cgImage:scale:orientation:)` で元の scale を維持する。

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
