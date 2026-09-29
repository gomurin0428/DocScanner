# DocScannerTests フォルダ

ユニットテスト（XCTest、`@testable import DocScanner`、TEST_HOST はアプリ本体）。

## ヘルパー

| 型 | メソッド | 役割 |
| --- | --- | --- |
| `TestImageFactory` | `solid(_:size:)` | 単色 UIImage 生成（scale=1） |
| `TestImageFactory` | `gradient(size:)` | 水平グレーグラデーション生成 |
| `TestImageFactory` | `markedSkewedDocument()` | 暗背景＋歪んだ白い紙＋左上角の黒マーカー（上下区別用）生成 |
| `TestImageFactory` | `pixelColor(of:x:y:)` | 指定ピクセルの色取得（アルファ有無両対応） |
| `TestImageFactory` | `pixelSize(of:)` | ピクセル単位サイズ取得 |

## テストケース一覧

### PDFBuilderTests
| テスト | 内容 |
| --- | --- |
| `testMakePDFProducesThreePages` | 3 画像 → PDFDocument の pageCount が 3 |
| `testA4PageBounds` | .a4 のページ境界が ≈595x842pt |
| `testLetterPageBounds` | .letter のページ境界が ≈612x792pt |
| `testFitImagePageBounds` | .fitImage のページ境界が画像 pt サイズと一致 |
| `testEmptyImagesThrowsNoPages` | 空配列 → PDFBuilderError.noPages |

### DocumentImageProcessorTests
| テスト | 内容 |
| --- | --- |
| `testGrayscaleProducesNeutralPixels` | 単色画像 grayscale → サンプル画素 R≈G≈B |
| `testBlackAndWhiteKeepsFaintThinStrokes` | 輝度0.75の2px細線+黒塊を含む白紙 → 細線上の最小輝度<0.5・黒塊中心<0.1・余白>0.95（旧グローバル閾値では細線が消える回帰テスト） |
| `testBlackAndWhiteLiftsShadedPaper` | 陰影付き合成紙 → blackAndWhite で上/下の紙 ≥0.9・バー ≤0.1（旧一律閾値では下部が黒化する回帰テスト） |
| `testEnhancedLiftsShadedPaper` | 下部紙 ≥0.85・バー ≤0.3（enhanced の陰影除去検証） |
| `testGrayscaleNeutralAndLiftsShadedPaper` | 下部紙 R==G==B（±2/255）かつ明度 ≥0.85（grayscale 検証） |
| `testFiltersPreservePixelSize` | 全フィルタでピクセルサイズ保持 |
| `testRotateOneTurnSwapsDimensions` | 1 回転で縦横入替（200x100→100x200） |
| `testRotateFourAndZeroKeepSize` | 4 回転・0 回転でサイズ不変 |
| `testRotateMinusOneEqualsRotateThree` | -1 回転と 3 回転が同サイズ |
| `testDownscaledShrinksLargeLandscapeImage` | 4000x3000 → 3000x2250 へ縮小 |
| `testDownscaledKeepsSmallImage` | 1000x800 はサイズ不変 |
| `testDownscaledShrinksLargePortraitImage` | 3000x4000 → 2250x3000 へ縮小 |

### DocumentDetectorTests
| テスト | 内容 |
| --- | --- |
| `testDetectsSkewedQuadrilateral` | 暗背景+白い歪四角形(約600x800)を検出し補正後縦横比≈0.75(±0.25) |
| `testCorrectedImageIsNotMirroredAndCropsToDocument` | 黒マーカー付き歪書類 → 左上が暗く他角が紙色（反転なし）かつ四隅3%が紙色（背景混入なし）。y反転の旧実装では失敗する回帰テスト |
| `testQuadsAgreeThreshold` | 同一四角形→true、1角5%移動→true、12%移動→false、個数違い→false |
| `testUniformImageThrowsNoDocumentFound` | 一様グレー画像 → DocumentDetectionError.noDocumentFound |

### PageFlattenerTests
| テスト | 内容 |
| --- | --- |
| `testHomographyMapsCornersAndRoundTrips` | 台形4点→矩形4点のホモグラフィ写像 ±1e-6、逆変換で往復一致 |
| `testCurvedPageFlattensToFilledRectangle` | 上下辺±40px・左辺30pxに湾曲した白ページ(1500x2000,暗灰背景)+同形状150x200合成マスクでflatten → 外周6pxバンド全サンプル輝度>200(背景残りなし)、出力サイズが矩形弧長±5%以内 |
| `testStraightRectangleOutputsPageCrop` | 直線辺の矩形ページ+マスクでflatten → 出力がページ切り出しと同サイズ(±2%) |

### DocumentDraftTests
| テスト | 内容 |
| --- | --- |
| `testSetFilterUpdatesOnlyTargetPage` | setFilter で対象ページのみ変更、他は不変 |
| `testRotateAccumulatesQuarterTurns` | +1/+1/-1 で quarterTurns=1 |
| `testRemoveDeletesPage` | remove で要素削除、page(id:) が nil |
| `testMoveReordersPages` | [A,B,C] → move(0→3) で [B,C,A] |
| `testAppendAddsPagesAtEnd` | append で末尾へ順序通り追加 |
| `testApplyFilterToAllChangesEveryPage` | 全ページへ同一フィルタ適用 |
| `testUnknownIdOperationsAreNoOps` | 未知 id の setFilter/rotate/remove が no-op |

### FileNameSanitizerTests
| テスト | 内容 |
| --- | --- |
| `testIllegalCharactersReplaced` | `/ \ : * ? " < > \|` が `-` に置換 |
| `testPDFExtensionStripped` | 末尾 ".pdf"/".PDF" 除去 |
| `testWhitespaceOnlyThrows` | 空白のみ入力 → FileNameError.empty |
| `testExtensionOnlyThrows` | ".pdf" のみ入力 → FileNameError.empty |
| `testDefaultNameFormat` | "Scan yyyy-MM-dd HH.mm.ss" 形式 |

### DocumentStoreTests（一時ディレクトリ注入、tearDown で削除）
| テスト | 内容 |
| --- | --- |
| `testSaveCreatesFileAndEntry` | save → ファイル生成・一覧登録・pageCount 正しい |
| `testDuplicateNamesGetSuffix` | 同名 2 回保存 → "Report (2)" |
| `testDeleteRemovesFileAndEntry` | delete → ファイルと一覧エントリ消失 |
| `testRenameMovesFile` | rename → 旧パス消失・新パス存在 |
| `testReloadPicksUpExternalFiles` | 外部書込みファイルを reload で拾う |
| `testNewestFirstOrdering` | documents が createdAt 降順 |
| `testSymlinkedDirectorySaveAndRename` | symlink 親を持つ directory で save 成功・同名リネームで " (2)" 非付与・別名リネーム成功（URL 等価比較の回帰テスト） |
| `testGarbagePDFFileThrowsUnreadable` | 拡張子 pdf のゴミファイルで reload → DocumentStoreError.unreadableDocument |

### PageImporterTests
| テスト | 内容 |
| --- | --- |
| `testMixedImagesAreSplitIntoDetectedAndUndetected` | [書類画像, 一様グレー] → 検出 1 + 未検出 1 |
| `testLargeInputIsDownscaledBeforeDetection` | 長辺 4000px 入力 → 検出済み画像の長辺 ≤3000 |

## クラス図

```mermaid
classDiagram
    class PDFBuilderTests
    class DocumentImageProcessorTests
    class DocumentDetectorTests
    class FileNameSanitizerTests
    class DocumentStoreTests
    class DocumentDraftTests
    class PageImporterTests
    class TestImageFactory
    PDFBuilderTests ..> TestImageFactory
    DocumentImageProcessorTests ..> TestImageFactory
    DocumentDetectorTests ..> TestImageFactory
    DocumentStoreTests ..> TestImageFactory
    PageImporterTests ..> TestImageFactory
```

## シーケンス図

```mermaid
sequenceDiagram
    participant R as XCTestRunner
    participant T as XCTestCase
    participant SUT as テスト対象
    R->>T: setUp（executionTimeAllowance=60）
    R->>T: test メソッド実行
    T->>SUT: 対象 API 呼出し
    SUT-->>T: 結果/例外
    T->>T: XCTAssert* で検証
    R->>T: tearDown（一時ディレクトリ削除）
```
