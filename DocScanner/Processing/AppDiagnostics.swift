import CoreImage
import Foundation
import os

enum AppDiagnostics {
    static let logger = Logger(subsystem: "com.komurasoft.DocScanner", category: "Processing")

    static func error(_ operation: String, error: Error) {
        logger.error("\(operation, privacy: .public): \(String(reflecting: error), privacy: .private)")
    }

    static func selection(_ reason: String) {
        logger.info("\(reason, privacy: .public)")
    }
}

enum ImageRendering {
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
    ])
}
