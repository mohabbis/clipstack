import Foundation
import Observation

/// Why a poll did or did not add an item. Returned for tests and diagnostics;
/// it never carries clipboard content.
public enum CaptureOutcome: Equatable {
    case unchanged
    case ownWrite
    case paused
    case concealed
    case excluded(bundleID: String)
    case unsupported
    case imagesDisabled
    case duplicate
    case tooLarge(bytes: Int)
    case failed
    case captured(ClipItem)
}

/// A short, content-free message shown in the UI (e.g. a skipped item or a storage error).
public struct HistoryNotice: Equatable, Identifiable {
    public enum Level: Equatable { case info, error }
    public let id = UUID()
    public let level: Level
    public let message: String

    public init(level: Level, message: String) {
        self.level = level
        self.message = message
    }

    public static func == (lhs: HistoryNotice, rhs: HistoryNotice) -> Bool {
        lhs.level == rhs.level && lhs.message == rhs.message
    }
}

/// Coordinates the pasteboard, capture policy, retention and storage.
/// UI code observes `items`, `settings` and `notice`.
@MainActor
@Observable
public final class ClipboardHistory {
    public private(set) var items: [ClipItem] = []
    public private(set) var settings: ClipstackSettings
    public private(set) var notice: HistoryNotice?

    @ObservationIgnored private let pasteboard: PasteboardSource
    @ObservationIgnored private let sourceApps: SourceAppProvider
    @ObservationIgnored private let store: HistoryStoring
    @ObservationIgnored private let imageProcessor: ImageProcessing
    @ObservationIgnored private let settingsStorage: SettingsStorage
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastSeenChangeCount: Int
    @ObservationIgnored private var ownWriteChangeCount: Int?

    public init(
        pasteboard: PasteboardSource,
        sourceApps: SourceAppProvider,
        store: HistoryStoring,
        imageProcessor: ImageProcessing,
        settingsStorage: SettingsStorage,
        now: @escaping () -> Date = Date.init
    ) {
        self.pasteboard = pasteboard
        self.sourceApps = sourceApps
        self.store = store
        self.imageProcessor = imageProcessor
        self.settingsStorage = settingsStorage
        self.now = now
        self.settings = settingsStorage.loadSettings()
        // Whatever is on the clipboard at launch was copied before Clipstack was watching;
        // its source app is unknown, so it is deliberately not captured.
        self.lastSeenChangeCount = pasteboard.changeCount
    }

    public var storageDirectory: URL { store.directoryURL }

    // MARK: - Lifecycle

    /// Loads stored history and removes anything that expired while the app was not running.
    public func load() {
        do {
            items = try store.loadItems().sorted { $0.createdAt > $1.createdAt }
        } catch {
            items = []
            notice = HistoryNotice(level: .error, message: "Couldn't read saved history. New items will still be recorded.")
        }
        applyRetention()
    }

    // MARK: - Capture

    /// Checks the pasteboard once. Call on a timer (Clipstack uses 0.5 s).
    @discardableResult
    public func poll() -> CaptureOutcome {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastSeenChangeCount else { return .unchanged }
        lastSeenChangeCount = changeCount

        if changeCount == ownWriteChangeCount { return .ownWrite }
        // Order matters: nothing below reads clipboard *content* until pause, privacy
        // markers and exclusions have been checked.
        if settings.isPaused { return .paused }

        let types = pasteboard.currentTypes()
        if PasteboardTypes.containsPrivacyMarker(types) { return .concealed }

        let source = sourceApps.currentSourceApp()
        if let bundleID = source?.bundleID, settings.isExcluded(bundleID: bundleID) {
            return .excluded(bundleID: bundleID)
        }
        if PasteboardTypes.containsFiles(types) { return .unsupported }

        if let text = pasteboard.readText(), !text.isEmpty {
            return captureText(text, source: source)
        }
        if let image = pasteboard.readImage() {
            guard settings.captureImages else { return .imagesDisabled }
            return captureImage(image, source: source)
        }
        return .unsupported
    }

    private func captureText(_ text: String, source: SourceApp?) -> CaptureOutcome {
        let bytes = text.utf8.count
        guard bytes <= settings.maxItemBytes else { return skippedTooLarge(bytes) }
        let fingerprint = ContentFingerprint.make(text)
        if let latest = items.first, latest.kind == .text, latest.fingerprint == fingerprint, latest.text == text {
            return .duplicate
        }
        let item = ClipItem(kind: .text, createdAt: now(), text: text, byteCount: bytes,
                            fingerprint: fingerprint,
                            sourceBundleID: source?.bundleID, sourceAppName: source?.name)
        return insert(item)
    }

    private func captureImage(_ raw: PasteboardImage, source: SourceApp?) -> CaptureOutcome {
        guard raw.data.count <= ImageLimits.maxRawInputBytes else { return skippedTooLarge(raw.data.count) }
        // Fingerprint the raw bytes so duplicates are detected before any decoding work.
        let fingerprint = ContentFingerprint.make(raw.data)
        if let latest = items.first, latest.kind == .image, latest.fingerprint == fingerprint {
            return .duplicate
        }
        let processed: ProcessedImage
        do {
            processed = try imageProcessor.process(raw)
        } catch {
            notice = HistoryNotice(level: .info, message: "Skipped an image that couldn't be read.")
            return .failed
        }
        guard processed.pngData.count <= settings.maxItemBytes else {
            return skippedTooLarge(processed.pngData.count)
        }
        let id = UUID()
        let info: ImageInfo
        do {
            info = try store.storeImage(id: id, image: processed)
        } catch {
            notice = HistoryNotice(level: .error, message: "Couldn't save an image to disk.")
            return .failed
        }
        let item = ClipItem(id: id, kind: .image, createdAt: now(), image: info,
                            byteCount: processed.pngData.count, fingerprint: fingerprint,
                            sourceBundleID: source?.bundleID, sourceAppName: source?.name)
        return insert(item)
    }

    private func insert(_ item: ClipItem) -> CaptureOutcome {
        items.insert(item, at: 0)
        let expired = trimToPolicy()
        guard persist(afterRemoving: expired) else {
            // Roll back so memory matches disk.
            items.removeAll { $0.id == item.id }
            store.removeFiles(of: [item])
            return .failed
        }
        return .captured(item)
    }

    private func skippedTooLarge(_ bytes: Int) -> CaptureOutcome {
        notice = HistoryNotice(level: .info, message: "Skipped an item larger than the \(Self.formatBytes(settings.maxItemBytes)) limit.")
        return .tooLarge(bytes: bytes)
    }

    // MARK: - Actions

    /// Puts an item back on the system clipboard. Clipstack never simulates ⌘V.
    @discardableResult
    public func copyToClipboard(_ item: ClipItem) -> Bool {
        do {
            let content: PasteboardWrite
            switch item.kind {
            case .text:
                content = .text(item.text ?? "")
            case .image:
                content = .pngImage(try store.imageData(for: item))
            }
            let count = try pasteboard.write(content)
            // Don't record our own write as a new item.
            ownWriteChangeCount = count
            lastSeenChangeCount = count
            return true
        } catch {
            notice = HistoryNotice(level: .error, message: "Couldn't copy that item to the clipboard.")
            return false
        }
    }

    public func delete(_ ids: Set<UUID>) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        persist(afterRemoving: removed)
    }

    public func clearHistory() {
        items = []
        do {
            try store.removeAll()
        } catch {
            store.removeIndex()
            notice = HistoryNotice(level: .error, message: "Some history files couldn't be removed from disk.")
        }
    }

    public func setPaused(_ paused: Bool) {
        updateSettings { $0.isPaused = paused }
    }

    public func updateSettings(_ change: (inout ClipstackSettings) -> Void) {
        var updated = settings
        change(&updated)
        guard updated != settings else { return }
        let wasPaused = settings.isPaused
        settings = updated
        settingsStorage.saveSettings(updated)
        if wasPaused && !updated.isPaused {
            // Anything copied while paused must not be captured on resume.
            lastSeenChangeCount = pasteboard.changeCount
        }
        applyRetention()
    }

    /// Removes expired items. Called at launch, after each capture, when settings change, and on a timer.
    public func applyRetention() {
        let expired = trimToPolicy()
        if !expired.isEmpty { persist(afterRemoving: expired) }
    }

    public func dismissNotice() {
        notice = nil
    }

    // MARK: - Queries

    public func search(_ query: String, kind: KindFilter) -> [ClipItem] {
        HistorySearch.filter(items, query: query, kind: kind)
    }

    public func thumbnailURL(for item: ClipItem) -> URL? {
        store.thumbnailURL(for: item)
    }

    public func imageData(for item: ClipItem) -> Data? {
        try? store.imageData(for: item)
    }

    public func diskUsage() -> Int {
        store.diskUsage()
    }

    // MARK: - Private

    private func trimToPolicy() -> [ClipItem] {
        let result = RetentionPolicy.apply(to: items, retention: settings.retention,
                                           maxItems: settings.maxItems, now: now())
        if !result.expired.isEmpty { items = result.kept }
        return result.expired
    }

    /// Saves the index, then deletes files of removed items. If the index can't be saved after a
    /// removal, the index file is deleted rather than leaving removed text on disk; the in-memory
    /// history is written again on the next successful save.
    @discardableResult
    private func persist(afterRemoving removed: [ClipItem]) -> Bool {
        defer { store.removeFiles(of: removed) }
        do {
            try store.saveItems(items)
            return true
        } catch {
            if !removed.isEmpty { store.removeIndex() }
            notice = HistoryNotice(level: .error, message: "Couldn't save history to disk.")
            return false
        }
    }

    static func formatBytes(_ bytes: Int) -> String {
        if bytes >= 1024 * 1024 { return "\(bytes / (1024 * 1024)) MB" }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) bytes"
    }
}
