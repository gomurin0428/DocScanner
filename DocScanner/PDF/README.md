# PDF フォルダ

ページ画像から PDF を生成するビルダーを格納する。

## 型とメソッド一覧

| 型 | メソッド / プロパティ | 役割 |
| --- | --- | --- |
| `PDFBuilderError` | `noPages` / `jpegEncodingFailed` | PDF 生成失敗の LocalizedError |
| `PDFBuilder` | `init()` | ビルダー生成（状態なし） |
| `PDFBuilder` | `makePDF(from:pageSize:jpegQuality:)` | 画像配列 → PDF Data（1 画像 1 ページ、JPEG 再エンコード、throws） |
| `PDFBuilder` | `pageBounds(for:pageSize:)` (private) | ページ境界計算（固定サイズ or 画像サイズ） |
| `PDFBuilder` | `contentRect(for:in:pageSize:)` (private) | 固定 A4/Letter は aspect-fit・18pt マージン中央配置、`.fitImage` のみページ端まで描画 |

## クラス図

```mermaid
classDiagram
    class PDFBuilder {
        -pageMargin: CGFloat = 18
        +makePDF(from, pageSize, jpegQuality) Data
    }
    PDFBuilder ..> PDFPageSize : ページサイズ決定
    PDFBuilder ..> UIGraphicsPDFRenderer : 描画
    PDFBuilder ..> PDFBuilderError : throws
```

## シーケンス図

```mermaid
sequenceDiagram
    participant Ed as EditorView
    participant B as PDFBuilder
    participant R as UIGraphicsPDFRenderer
    Ed->>B: makePDF(images, .a4, 0.8)
    B->>B: 空チェック（noPages）
    loop 各画像
        B->>R: beginPage(bounds)
        B->>B: contentRect（.fitImage 以外は18ptマージン内 aspect-fit）
        B->>B: jpegData 再エンコード → draw(in:)
    end
    R-->>B: pdfData
    B-->>Ed: Data
```
