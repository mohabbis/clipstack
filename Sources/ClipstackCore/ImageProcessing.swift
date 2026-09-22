import Foundation

/// An image converted to the format Clipstack stores.
public struct ProcessedImage: Equatable, Sendable {
    public var pngData: Data
    /// A small PNG (longest side bounded) used for list previews.
    public var thumbnailPNGData: Data
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(pngData: Data, thumbnailPNGData: Data, pixelWidth: Int, pixelHeight: Int) {
        self.pngData = pngData
        self.thumbnailPNGData = thumbnailPNGData
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

public enum ImageProcessingError: Error, Equatable {
    case unreadable
    case encodingFailed
}

/// Converts raw pasteboard image data to PNG and produces a thumbnail.
/// The macOS implementation uses ImageIO; tests use a fake.
public protocol ImageProcessing: AnyObject {
    func process(_ image: PasteboardImage) throws -> ProcessedImage
}

public enum ImageLimits {
    /// Thumbnails are bounded to this many pixels on their longest side.
    public static let thumbnailMaxPixelSize = 320
    /// Raw pasteboard images larger than this are skipped without being decoded,
    /// regardless of the user's per-item limit (uncompressed TIFFs can be very large).
    public static let maxRawInputBytes = 100 * 1024 * 1024
}
