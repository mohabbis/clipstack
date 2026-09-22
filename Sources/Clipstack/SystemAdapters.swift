#if os(macOS)
import AppKit
import ClipstackCore
import ImageIO
import UniformTypeIdentifiers

/// `NSPasteboard.general` behind the `PasteboardSource` abstraction.
final class SystemPasteboard: PasteboardSource {
    private let pasteboard: NSPasteboard

    /// Image types Clipstack reads, in order of preference.
    private static let imageTypes: [NSPasteboard.PasteboardType] = [
        .png,
        .tiff,
        NSPasteboard.PasteboardType(UTType.jpeg.identifier),
        NSPasteboard.PasteboardType(UTType.heic.identifier),
        NSPasteboard.PasteboardType(UTType.gif.identifier),
    ]

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func currentTypes() -> [String] {
        pasteboard.types?.map(\.rawValue) ?? []
    }

    func readText() -> String? {
        pasteboard.string(forType: .string)
    }

    func readImage() -> PasteboardImage? {
        guard let type = pasteboard.availableType(from: Self.imageTypes),
              let data = pasteboard.data(forType: type)
        else { return nil }
        return PasteboardImage(data: data, typeIdentifier: type.rawValue)
    }

    func write(_ content: PasteboardWrite) throws -> Int {
        switch content {
        case .text(let string):
            pasteboard.clearContents()
            guard pasteboard.setString(string, forType: .string) else { throw PasteboardWriteError.rejected }
        case .pngImage(let png):
            // Offer TIFF as well: some older apps only accept TIFF images.
            let tiff = NSBitmapImageRep(data: png)?.tiffRepresentation
            pasteboard.declareTypes(tiff == nil ? [.png] : [.png, .tiff], owner: nil)
            guard pasteboard.setData(png, forType: .png) else { throw PasteboardWriteError.rejected }
            if let tiff { pasteboard.setData(tiff, forType: .tiff) }
        }
        return pasteboard.changeCount
    }
}

/// Attributes clipboard changes to the frontmost app. macOS doesn't report which app wrote
/// to the pasteboard, so this is a best-effort heuristic (see README "Limitations").
final class FrontmostAppProvider: SourceAppProvider {
    func currentSourceApp() -> SourceApp? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return SourceApp(bundleID: app.bundleIdentifier, name: app.localizedName)
    }
}

/// Normalises pasteboard images to PNG and renders a bounded thumbnail with ImageIO.
final class ImageIOProcessor: ImageProcessing {
    func process(_ image: PasteboardImage) throws -> ProcessedImage {
        guard let source = CGImageSourceCreateWithData(image.data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { throw ImageProcessingError.unreadable }

        let png: Data
        if image.typeIdentifier == UTType.png.identifier {
            png = image.data // already PNG; store as-is
        } else {
            guard let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ImageProcessingError.unreadable
            }
            png = try Self.encodePNG(full)
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ImageLimits.thumbnailMaxPixelSize,
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageProcessingError.unreadable
        }
        return ProcessedImage(pngData: png, thumbnailPNGData: try Self.encodePNG(thumbnail),
                              pixelWidth: width, pixelHeight: height)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.png.identifier as CFString, 1, nil)
        else { throw ImageProcessingError.encodingFailed }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ImageProcessingError.encodingFailed }
        return data as Data
    }
}
#endif
