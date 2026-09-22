import Foundation

/// The kinds of clipboard content Clipstack stores.
public enum ClipKind: String, Codable, CaseIterable, Sendable {
    case text
    case image

    public var displayName: String {
        switch self {
        case .text: return "Text"
        case .image: return "Image"
        }
    }
}

/// On-disk details for an image item. The pixels themselves live in separate files.
public struct ImageInfo: Codable, Equatable, Sendable {
    public var fileName: String
    public var thumbnailFileName: String
    public var pixelWidth: Int
    public var pixelHeight: Int

    public init(fileName: String, thumbnailFileName: String, pixelWidth: Int, pixelHeight: Int) {
        self.fileName = fileName
        self.thumbnailFileName = thumbnailFileName
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// One entry in the clipboard history.
public struct ClipItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let kind: ClipKind
    public let createdAt: Date
    /// Full text for `.text` items; `nil` for images.
    public let text: String?
    /// File references for `.image` items; `nil` for text.
    public let image: ImageInfo?
    /// Size of the stored payload (UTF-8 bytes for text, PNG bytes for images).
    public let byteCount: Int
    /// Non-cryptographic fingerprint used only to detect consecutive duplicates.
    public let fingerprint: String
    public let sourceBundleID: String?
    public let sourceAppName: String?

    public init(
        id: UUID = UUID(),
        kind: ClipKind,
        createdAt: Date,
        text: String? = nil,
        image: ImageInfo? = nil,
        byteCount: Int,
        fingerprint: String,
        sourceBundleID: String? = nil,
        sourceAppName: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.text = text
        self.image = image
        self.byteCount = byteCount
        self.fingerprint = fingerprint
        self.sourceBundleID = sourceBundleID
        self.sourceAppName = sourceAppName
    }

    /// A single-line preview: the start of the text with runs of whitespace collapsed.
    public var previewText: String {
        guard let text else { return "" }
        let head = text.prefix(600)
        return head
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    public var lineCount: Int {
        guard let text, !text.isEmpty else { return 0 }
        return text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
    }

    /// A short description for image items, e.g. "1920 × 1080".
    public var dimensionsText: String? {
        guard let image else { return nil }
        return "\(image.pixelWidth) × \(image.pixelHeight)"
    }
}

/// Builds fingerprints for duplicate detection (64-bit FNV-1a plus length).
/// This is not a security hash; it is only compared against the most recent item.
public enum ContentFingerprint {
    public static func make(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        data.withUnsafeBytes { buffer in
            for byte in buffer {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return String(hash, radix: 16) + "-" + String(data.count)
    }

    public static func make(_ text: String) -> String {
        make(Data(text.utf8))
    }
}
