# Views フォルダ

SwiftUI 画面群を格納する。

## 型とメソッド一覧

| 型 | メソッド / プロパティ | 役割 |
| --- | --- | --- |
| `DocumentListView` | `body` | 保存 PDF 一覧ルート。Scan（カメラ非搭載時アラート）/ Import（PhotosPicker→書類検出）、スワイプ削除、コンテキストメニュー（Rename/Share/Delete）。Scan/Import は `.safeAreaInset(edge: .bottom)` のフル幅ボタン（iOS 26 の `.bottomBar` ツールバーでは `.titleAndIcon` が効かないため） |
| `DocumentListView` | `importItems` / `handleImages` / `acceptUndetectedImages` / `discardUndetectedImages` / `delete` / `performRename` / `present` (private) | 順序付き写真・カメラ取り込み（pending ImportResult と独立した alert Bool を保持）、未検出確認、削除、リネーム、エラー表示 |
| `DocumentRow` (private) | `body` / `metaText` / `loadThumbnail` | 1 行表示（PDFKit 1 ページ目サムネイル + 日時・ページ数・サイズ） |
| `CameraError` | `noCameraDevice` / `cannotCreateInput` / `cannotAddInput` / `cannotAddPhotoOutput` / `cannotAddVideoOutput` / `captureFailed` / `invalidPhotoData` | カメラ構成・撮影失敗の LocalizedError |
| `CameraController` | `isAvailable()` (static) / `beginActivation()` / `start(generation:)` / `stop()` / `capture()` | @Observable な AVCaptureSession ラッパー。sessionQueue で configure+start/stop を直列化し、世代トークンで遅延開始・UI 通知を抑止。写真 pending は MainActor で同期設定し、最終 callback まで単一撮影を維持 |
| `CameraController` | `detectedQuad` / `detectedBoundary` / `capturedSources` / `frameSize` / `captures` / `lastCapture` / `isCapturing` / `canFinish` / `error` / `isConfigured` / `captureSession` | 表示輪郭と撮影入力を公開。撮影中は枠を固定しシャッター/Done を無効化 |
| `CameraPhotoState` | `init(captures:)` / `sources` / `captures` / `beginCapture()` / `finishCapture(image:shouldAppend:boundary:)` / `isCapturing` / `canFinish` | 各写真と固定輪郭を入力順で保持。失敗・旧世代の撮影は追加しない |
| `CameraCaptureGeometry` | `transform(origin:x:y:)` / `normalizedPhotoPoint(_:size:orientation:)` | 出力変換のアフィン写像と EXIF 向きの変換。写真ピクセルから表示向きの左下原点正規化座標へ変換 |
| `CameraPhotoCaptureDelegate` | `init(boundary:completion:)` / `photoOutput(_:didFinishProcessingPhoto:error:)` / `photoOutput(_:didFinishCaptureFor:error:)` | 撮影要求時の metadata 輪郭を固定し、写真出力の画角と EXIF 向きへ変換。変換不正はエラーとして最終完了で返す |
| `DocumentRectangleTracker` | `update(_:at:)` | 書類候補とフレーム時刻から安定した四隅を返す。3 回・0.35 秒以上の連続確認、四隅の平滑化、0.75 秒の消失猶予で枠の点滅・飛び移りを抑える |
| `CameraCaptureView` | `body` / `startIfAuthorized` (async) | フルスクリーンカメラ画面。preview（aspectFill）+ 緑 quad オーバレイ + 手動シャッター（白フラッシュ）+ 枚数/サムネイル + Done/Cancel。SwiftUI task が権限要求を所有し、denied は Open Settings、撮影失敗は pending 解除後も画面を保つエラーアラート |
| `CameraCaptureView` | `overlayPoints(normalized:bufferSize:viewSize:)` (static) | 同じ画角を仮定したaspect-fill変換の参照計算（単体テスト対象）。実際の緑枠は下記のAVFoundation変換を使用 |
| `CameraPreviewView` (private) | `makeUIView` / `updateUIView` | AVCaptureVideoPreviewLayer の Representable。緑枠と同一の全画面 GeometryReader を共有（resizeAspectFill）。isConfigured 更新後にも接続回転を設定 |
| `CameraPreviewView.PreviewView` (private) | `updateRotation()` | 接続が利用可能なら解析フレームと同じ rotation 90 を適用 |
| `CameraPreviewView.PreviewView` (private) | `layoutSubviews()` / `boundary` / `outlineLayer` | metadata輪郭を`layerPointConverted(fromCaptureDevicePoint:)`で変換しCAShapeLayerへ描画。解析とプレビューの画角差を考慮し、レイアウト変更時にも再計算。暗黙アニメーションなし |
| `EditorView` | `body` / `init(pages:)` | 新規ドキュメント編集（List .onMove 並べ替え・削除、ファイル名、用紙サイズ、追加スキャン/インポート、全ページフィルタ、Save PDF は下部 safeAreaInset のフル幅ボタン）。ページは共有 `DocumentDraft` で保持し、行タップ→ `editingPageID` → `.navigationDestination(item:)` で遷移（item/値ベース遷移の混在は不可） |
| `EditorView` | `importItems` / `handleImages` / `save` / `applyFilterToAll` / `showCameraOrAlert` / `acceptUndetected` / `discardUndetected` (private) | 順序付き pending ImportResult から既存ページの後ろへ取込・保存 |
| `PageRow` (private) | `body` / `loadThumbnail` / `thumbnailKey` | ページ縮小サムネイル行（失敗時は警告アイコン）。draft+pageID で参照し Filter All の変更も Observation で反映、非同期完了時にキーが変わっていれば古い結果を破棄。行は Button+chevron で包み `.onMove`/`.onDelete` は維持 |
| `PageEditView` | `body` / `init(draft:pageID:)` / `editContent` / `filterSelection` / `renderPage` / `renderKey` | 1 ページ編集（大プレビュー、フィルタ segmented、左右回転、削除）。ページは draft から id で読み、編集は draft メソッドへ委譲。非同期レンダリング完了時に renderKey が変わっていれば古い結果を捨てる |
| `PDFKitView` (private) | `makeUIView` / `updateUIView` | PDFKit PDFView の Representable |
| `PDFPreviewView` | `body` / `deleteDocument` | 保存済み PDF プレビュー + ShareLink + Delete |

## クラス図

ライブ解析は最大毎秒 5 回、confidence ≥ 0.6 の書類領域を形状検証して追跡する。四隅の 1〜99% 内包、凸性、最短辺 10%、辺長比 0.15 を要求。3 回・0.35 秒の確認後、マスクから湾曲した四辺を抽出して緑枠へ渡す。短い未検出や別候補では前の輪郭を保持し、0.75 秒の消失で消す。候補変更時は再確認が必要。カメラ世代・画像寸法が変われば初期化する。シャッター時の同じ輪郭を video→metadata→photo 座標変換して保存し、撮影後の再検出はしない。枠なし撮影は全文画像確認に回す。

```mermaid
sequenceDiagram
    participant C as CameraController (videoQueue)
    participant V as Vision
    participant T as DocumentRectangleTracker
    participant U as MainActor
    C->>V: 矩形 + 書類領域検出（最大 5Hz）
    V-->>C: 優先候補と書類領域
    C->>T: update(書類候補または nil, フレーム時刻)
    T-->>C: 安定した四隅または nil
    C->>C: マスク輪郭抽出・平滑化四隅へ写像
    C->>U: 輪郭とmetadata座標を同時更新
```

```mermaid
classDiagram
    class DocumentListView
    class CameraCaptureView {
        +onDone([PageSource])
        +onError(Error)
        +onCancel()
        +overlayPoints(normalized, bufferSize, viewSize)$ [CGPoint]
    }
    class CameraController {
        <<observable>>
        +detectedQuad: [CGPoint]
        +captures: [UIImage]
        +beginActivation() UInt64
        +start(generation) / stop() / capture()
        +isCapturing / canFinish
    }
    class CameraLifecycleState {
        +activate() UInt64
        +deactivate()
        +canStart(generation, taskIsCancelled) Bool
    }
    class DocumentRectangleTracker {
        +update(observation, time) [CGPoint]?
    }
    CameraController --> DocumentRectangleTracker
    class CameraPhotoState {
        +beginCapture() Bool
        +finishCapture(image, shouldAppend, boundary)
        +canFinish Bool
    }
    class EditorView {
        +draft: DocumentDraft
    }
    class PageEditView {
        +draft: DocumentDraft
        +pageID: UUID
    }
    class PDFPreviewView {
        +document: SavedDocument
    }
    DocumentListView --> CameraCaptureView : Scan 起動
    CameraCaptureView --> CameraController : セッション・撮影
    CameraController --> DocumentRectangleDetector : 書類領域の形状検証
    CameraController --> PageFlattener : 曲線輪郭抽出
    CameraController --> CameraPhotoCaptureDelegate : シャッター時の輪郭固定
    CameraPhotoCaptureDelegate --> CameraCaptureGeometry : 写真の画角・向きへ変換
    CameraController --> CameraLifecycleState : 世代ガード
    CameraController --> CameraPhotoState : single-flight 撮影状態
    DocumentListView --> EditorView : スキャン/インポート後
    DocumentListView --> PDFPreviewView : 保存済み選択
    EditorView --> PageEditView : editingPageID→navigationDestination(item:)
    EditorView --> PDFPreviewView : 保存完了
    EditorView --> CameraCaptureView : Add Pages
```

## シーケンス図

```mermaid
sequenceDiagram
    participant U as User
    participant L as DocumentListView
    participant C as CameraCaptureView
    participant E as EditorView
    participant B as PDFBuilder
    participant S as DocumentStore
    participant P as PDFPreviewView
    U->>L: Scan タップ
    L->>C: カメラ表示（手動シャッター）
    U->>C: 撮影→Done
    C-->>L: [PageSource.camera]（onDone、固定輪郭付き）
    L->>E: draftPages 遷移
    U->>E: Save PDF
    E->>B: makePDF(renderedImages)
    B-->>E: Data
    E->>S: save(pdfData, name)
    S-->>E: SavedDocument
    E->>P: プレビュー遷移
```
