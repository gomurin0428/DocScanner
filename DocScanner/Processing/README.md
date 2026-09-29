# Processing フォルダ

Core Image / Vision を使った画像処理（フィルタ・回転・書類検出 + 台形補正）を格納する。

## 型とメソッド一覧

| 型 | メソッド / プロパティ | 役割 |
| --- | --- | --- |
| `ImageProcessingError` | `invalidImage` / `filterFailed` / `renderFailed` | 画像処理失敗の LocalizedError |
| `DocumentImageProcessor` | `init()` | CIContext 生成 |
| `DocumentImageProcessor` | `apply(_:to:)` | PageFilter を画像へ適用（陰影除去 + レベル補正、ピクセルサイズ保持、throws） |
| `DocumentImageProcessor` | `rotate(_:quarterTurns:)` | 90°単位の時計回り回転（mod 4、負値対応、throws） |
| `DocumentImageProcessor` | `downscaled(_:maxPixelDimension:)` | 長辺を上限 px（既定 3000）以下へ縮小（アスペクト保持・scale=1、throws） |
| `DocumentImageProcessor` | `normalizedCGImage(of:)` (private) | UIImage の向きを .up に正規化 |
| `DocumentImageProcessor` | `render(_:scale:)` (private) | CIImage → CGImage → UIImage へ焼き付け |
| `ShadingCorrector` | `background(of:)` (static) | 背景推定（長辺512px縮小→CIMorphologyMaximum r6→CIGaussianBlur r12→復元、throws） |
| `ShadingCorrector` | `flattened(_:)` (static) | CIDivideBlendMode で画像÷背景の平坦化（throws） |
| `ShadingCorrector` | `grayscale(_:)` (static) | 彩度 0 グレースケール化（throws） |
| `ShadingCorrector` | `levels(_:black:white:gamma:)` (static) | CIColorMatrix→CIColorClamp→CIGammaAdjust のレベル補正（throws） |
| `DocumentDetectionError` | `noDocumentFound` / `invalidImage` / `visionFailed` / `correctionFailed` / `renderFailed` / `unexpectedMaskFormat` / `bitmapContextFailed` / `singularHomography` | 検出・フラット化失敗の LocalizedError |
| `DocumentDetector` | `init()` | CIContext 生成 |
| `DocumentDetector` | `detectAndCorrect(_:)` | VNDetectRectanglesRequest で四角形検出 → seg が一致すれば PageFlattener、なければ CIPerspectiveCorrection（throws） |
| `DocumentDetector` | `quadsAgree(_:_:width:height:)` (static) | seg 四角形と検出四角形の 4 隅距離が max(W,H)×8% 以内か判定 |
| `DocumentDetector` | `perspectiveCorrect(_:rectangle:scale:)` (private) | CIPerspectiveCorrection 適用 + レンダリング |
| `DocumentDetector` | `normalizedCGImage(of:)` (private) | UIImage の向きを .up に正規化 |
| `SegmentationMask` | `init(pixelBuffer:imageWidth:imageHeight:)` | Vision Float32 マスクを読み込む（形式不一致は throw） |
| `SegmentationMask` | `init(width:height:values:imageWidth:imageHeight:)` | 合成マスク構築（テスト用） |
| `SegmentationMask` | `value(at:)` | 画像ピクセル座標のマスク値を双線形補間 |
| `PageBitmap` | `init(_:)` | CGImage → sRGB RGBA8 ビットマップ（throws） |
| `PageBitmap` | `luminance(atX:y:)` / `sampleRGB(atX:y:into:)` | 最近傍輝度 / 双線形 RGB サンプル |
| `PageFlattener` | `flatten(_:corners:mask:)` | マスク輪郭追跡 + Coons パッチで湾曲辺を矩形化（throws） |
| `PagePoint` | `+` / `-` / `*` / `length` | Double 精度 2D 点（左上原点） |
| `PageGeometry` | `solveLinear(_:_:)` / `homography(from:to:)` / `apply(_:to:)` / `arcLength(_:)` / `sample(_:at:)` (static) | 線形ソルバ・ホモグラフィ・曲線サンプリング（throws） |
| `PageImporterError` | `loadFailed(index, message)` / `decodeFailed(index)` | 写真読み込み失敗の LocalizedError（index と元エラーメッセージ付き） |
| `ImportResult` | `detectedPages` / `undetectedImages` | 検出済みページと未検出元画像の振り分け結果 |
| `PageImporter` | `init()` | DocumentDetector と DocumentImageProcessor を生成 |
| `PageImporter` | `loadImages(from:)` (static) | PhotosPickerItem → UIImage（失敗は throw、非同期） |
| `PageImporter` | `makePages(from:)` | 縮小 → 検出を実行し ImportResult を返す（throws） |

## クラス図

```mermaid
classDiagram
    class DocumentImageProcessor {
        -context: CIContext
        +apply(filter, to:) UIImage
        +rotate(image, quarterTurns:) UIImage
    }
    class DocumentDetector {
        -context: CIContext
        +detectAndCorrect(image) UIImage
    }
    class ShadingCorrector {
        <<utility>>
        +background(of)$ CIImage
        +flattened(_:)$ CIImage
        +grayscale(_:)$ CIImage
        +levels(_:black:white:gamma:)$ CIImage
    }
    DocumentImageProcessor --> ShadingCorrector : フィルタ適用
    DocumentImageProcessor ..> ImageProcessingError : throws
    DocumentDetector ..> DocumentDetectionError : throws
    class PageImporter {
        -detector: DocumentDetector
        -processor: DocumentImageProcessor
        +loadImages(from)$ [UIImage]
        +makePages(from) ImportResult
    }
    DocumentImageProcessor ..> ImageProcessingError : throws
    DocumentDetector ..> DocumentDetectionError : throws
    class PageFlattener {
        +flatten(image, corners, mask) CGImage
    }
    class SegmentationMask {
        +value(at) Double
    }
    class PageGeometry {
        <<utility>>
        +homography(from:to:)$ [Double]
    }
    DocumentDetector ..> VNDetectRectanglesRequest : 検出
    DocumentDetector ..> VNDetectDocumentSegmentationRequest : seg+マスク
    DocumentDetector --> PageFlattener : quadsAgree 合格時
    PageFlattener --> SegmentationMask
    PageFlattener --> PageGeometry
    DocumentDetector ..> CIPerspectiveCorrection : 補正
    PageImporter --> DocumentDetector
    PageImporter --> DocumentImageProcessor : 縮小
    PageImporter --> ImportResult
    PageImporter ..> PageImporterError : throws
```

## シーケンス図

```mermaid
sequenceDiagram
    participant UI as DocumentListView
    participant Det as DocumentDetector
    participant VN as VNImageRequestHandler
    participant CI as CIFilter(CIPerspectiveCorrection)
    UI->>Det: detectAndCorrect(photo)
    Det->>Det: 向き正規化 → CIImage
    Det->>VN: perform(VNDetectRectanglesRequest)
    VN-->>Det: VNRectangleObservation（なければ noDocumentFound）
    Det->>Det: 正規化座標 → ピクセル座標へ変換
    Det->>CI: inputTopLeft/TopRight/BottomLeft/BottomRight
    CI-->>Det: 補正済み CIImage
    Det-->>UI: 補正済み UIImage
```
