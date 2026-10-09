import CoreGraphics
import PDFKit
import UIKit

enum PDFBuilderError: LocalizedError {
    case noPages
    case jpegEncodingFailed
    case contextCreationFailed

    var errorDescription: String? {
        switch self {
        case .noPages: return "There are no pages to export."
        case .jpegEncodingFailed: return "A page image could not be encoded as JPEG."
        case .contextCreationFailed: return "The PDF output could not be created."
        }
    }
}

struct PDFBuilder {
    private static let pageMargin: CGFloat = 18
    private static let pointsPerPixel: CGFloat = 72.0 / 300.0

    init() {}

    static func writePDF(
        pageCount: Int,
        to url: URL,
        pageSize: PDFPageSize,
        jpegQuality: CGFloat = 0.8,
        imageForPage: (Int) throws -> UIImage,
        progress: (Int) -> Void
    ) throws {
        guard pageCount > 0 else { throw PDFBuilderError.noPages }
        try? FileManager.default.removeItem(at: url)
        var context: CGContext?
        do {
            guard let createdContext = CGContext(url as CFURL, mediaBox: nil, nil) else {
                throw PDFBuilderError.contextCreationFailed
            }
            context = createdContext
            for index in 0..<pageCount {
                try autoreleasepool {
                    try Task.checkCancellation()
                    let image = try imageForPage(index)
                    try Task.checkCancellation()
                    let upright = uprightImage(image)
                    try Task.checkCancellation()
                    guard let jpegData = upright.jpegData(compressionQuality: jpegQuality),
                          let encoded = UIImage(data: jpegData),
                          let cgImage = encoded.cgImage else {
                        throw PDFBuilderError.jpegEncodingFailed
                    }
                    try Task.checkCancellation()
                    let imageSize = CGSize(width: CGFloat(cgImage.width) * pointsPerPixel,
                                           height: CGFloat(cgImage.height) * pointsPerPixel)
                    let bounds = pageBounds(for: imageSize, pageSize: pageSize)
                    var mediaBox = bounds
                    context?.beginPage(mediaBox: &mediaBox)
                    context?.saveGState()
                    context?.draw(cgImage, in: contentRect(for: imageSize, in: bounds,
                                                            pageSize: pageSize))
                    context?.restoreGState()
                    context?.endPage()
                    try Task.checkCancellation()
                }
                progress(index + 1)
            }
            context?.closePDF()
            context = nil
        } catch {
            context?.closePDF()
            context = nil
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func makePDF(from images: [UIImage], pageSize: PDFPageSize,
                 jpegQuality: CGFloat = 0.8) throws -> Data {
        guard !images.isEmpty else { throw PDFBuilderError.noPages }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocScanner-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writePDF(pageCount: images.count, to: url, pageSize: pageSize,
                          jpegQuality: jpegQuality,
                          imageForPage: { images[$0] }, progress: { _ in })
        return try Data(contentsOf: url)
    }

    private static func pageBounds(for imageSize: CGSize, pageSize: PDFPageSize) -> CGRect {
        CGRect(origin: .zero, size: pageSize.fixedSize ?? imageSize)
    }

    private static func uprightImage(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up, let cgImage = image.cgImage else { return image }
        let swapsDimensions = image.imageOrientation == .left ||
            image.imageOrientation == .leftMirrored ||
            image.imageOrientation == .right ||
            image.imageOrientation == .rightMirrored
        let scale = image.scale
        let size = CGSize(width: CGFloat(swapsDimensions ? cgImage.height : cgImage.width) / scale,
                          height: CGFloat(swapsDimensions ? cgImage.width : cgImage.height) / scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private static func contentRect(for imageSize: CGSize, in bounds: CGRect,
                                    pageSize: PDFPageSize) -> CGRect {
        guard pageSize != .fitImage else { return bounds }
        let available = bounds.insetBy(dx: pageMargin, dy: pageMargin)
        let scale = min(available.width / imageSize.width,
                        available.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: available.minX + (available.width - size.width) / 2,
                      y: available.minY + (available.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}
