import Foundation

public enum HistoryStoreError: Error, Equatable {
    case unsupportedIndexVersion(Int)
    case missingImage
}

/// Persistence for history items and their image files.
public protocol HistoryStoring: AnyObject {
    /// Location of stored history, shown to the user in Settings.
    var directoryURL: URL { get }
    func loadItems() throws -> [ClipItem]
    func saveItems(_ items: [ClipItem]) throws
    func storeImage(id: UUID, image: ProcessedImage) throws -> ImageInfo
    func imageData(for item: ClipItem) throws -> Data
    func thumbnailURL(for item: ClipItem) -> URL?
    /// Deletes files belonging to the given items. Best effort; never throws.
    func removeFiles(of items: [ClipItem])
    /// Deletes the index file so no text remains on disk. Used if a save fails after a deletion.
    func removeIndex()
    /// Deletes every file Clipstack stored.
    func removeAll() throws
    /// Approximate bytes used on disk.
    func diskUsage() -> Int
}

/// Stores history as a JSON index plus one PNG (and one thumbnail PNG) per image item:
///
///     <directory>/history.json
///     <directory>/Images/<uuid>.png
///     <directory>/Thumbnails/<uuid>.png
///
/// Files are written atomically and the directory is created with owner-only permissions.
/// Content is stored as plain files; it is not encrypted by Clipstack.
public final class FileHistoryStore: HistoryStoring {
    public let directoryURL: URL
    private let fileManager: FileManager
    private static let indexVersion = 1

    private var indexURL: URL { directoryURL.appendingPathComponent("history.json") }
    private var imagesURL: URL { directoryURL.appendingPathComponent("Images", isDirectory: true) }
    private var thumbnailsURL: URL { directoryURL.appendingPathComponent("Thumbnails", isDirectory: true) }

    private struct Index: Codable {
        var version: Int
        var items: [ClipItem]
    }

    public init(directoryURL: URL, fileManager: FileManager = .default) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    /// `~/Library/Application Support/<bundle id>` — inside the app's container when sandboxed.
    public static func defaultDirectory(bundleIdentifier: String, fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                       appropriateFor: nil, create: true)
        return base.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    public func loadItems() throws -> [ClipItem] {
        try prepareDirectories()
        guard fileManager.fileExists(atPath: indexURL.path) else {
            removeOrphanedFiles(keeping: [])
            return []
        }
        let data = try Data(contentsOf: indexURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let index = try decoder.decode(Index.self, from: data)
        guard index.version <= Self.indexVersion else {
            throw HistoryStoreError.unsupportedIndexVersion(index.version)
        }
        // Drop image items whose file went missing, and delete files no item refers to
        // (for example, left behind if the app quit between writing an image and the index).
        let items = index.items.filter { item in
            guard let image = item.image else { return item.kind == .text && item.text != nil }
            return fileManager.fileExists(atPath: imagesURL.appendingPathComponent(image.fileName).path)
        }
        removeOrphanedFiles(keeping: items)
        return items
    }

    public func saveItems(_ items: [ClipItem]) throws {
        try prepareDirectories()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Index(version: Self.indexVersion, items: items))
        try data.write(to: indexURL, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    public func storeImage(id: UUID, image: ProcessedImage) throws -> ImageInfo {
        try prepareDirectories()
        let fileName = id.uuidString + ".png"
        let imageURL = imagesURL.appendingPathComponent(fileName)
        let thumbURL = thumbnailsURL.appendingPathComponent(fileName)
        do {
            try image.pngData.write(to: imageURL, options: .atomic)
            try image.thumbnailPNGData.write(to: thumbURL, options: .atomic)
        } catch {
            try? fileManager.removeItem(at: imageURL)
            try? fileManager.removeItem(at: thumbURL)
            throw error
        }
        return ImageInfo(fileName: fileName, thumbnailFileName: fileName,
                         pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)
    }

    public func imageData(for item: ClipItem) throws -> Data {
        guard let image = item.image else { throw HistoryStoreError.missingImage }
        return try Data(contentsOf: imagesURL.appendingPathComponent(image.fileName))
    }

    public func thumbnailURL(for item: ClipItem) -> URL? {
        guard let image = item.image else { return nil }
        return thumbnailsURL.appendingPathComponent(image.thumbnailFileName)
    }

    public func removeFiles(of items: [ClipItem]) {
        for item in items {
            guard let image = item.image else { continue }
            try? fileManager.removeItem(at: imagesURL.appendingPathComponent(image.fileName))
            try? fileManager.removeItem(at: thumbnailsURL.appendingPathComponent(image.thumbnailFileName))
        }
    }

    public func removeIndex() {
        try? fileManager.removeItem(at: indexURL)
    }

    public func removeAll() throws {
        for url in [indexURL, imagesURL, thumbnailsURL] where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try prepareDirectories()
    }

    public func diskUsage() -> Int {
        var total = 0
        if let size = try? fileManager.attributesOfItem(atPath: indexURL.path)[.size] as? Int {
            total += size
        }
        for dir in [imagesURL, thumbnailsURL] {
            let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names {
                let path = dir.appendingPathComponent(name).path
                total += (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            }
        }
        return total
    }

    // MARK: - Private

    private func prepareDirectories() throws {
        for url in [directoryURL, imagesURL, thumbnailsURL] {
            if !fileManager.fileExists(atPath: url.path) {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
            }
        }
        #if os(macOS)
        // Keep clipboard history out of Time Machine backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directoryURL
        try? url.setResourceValues(values)
        #endif
    }

    private func removeOrphanedFiles(keeping items: [ClipItem]) {
        let referenced = Set(items.compactMap { $0.image?.fileName } + items.compactMap { $0.image?.thumbnailFileName })
        for dir in [imagesURL, thumbnailsURL] {
            let names = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
            for name in names where !referenced.contains(name) {
                try? fileManager.removeItem(at: dir.appendingPathComponent(name))
            }
        }
    }
}
