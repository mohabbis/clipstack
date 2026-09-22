import XCTest
@testable import ClipstackCore

@MainActor
final class RetentionTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    func testItemsOlderThanRetentionExpire() async {
        var settings = ClipstackSettings()
        settings.retention = .oneDay
        let h = Harness(settings: settings)

        h.pasteboard.copyText("old")
        h.history.poll()
        h.clock.advance(day - 60)
        h.pasteboard.copyText("recent")
        h.history.poll()

        h.clock.advance(120) // "old" is now just over a day old
        h.history.applyRetention()
        XCTAssertEqual(h.history.items.map(\.text), ["recent"])
    }

    func testExpiredContentIsRemovedFromDisk() async {
        var settings = ClipstackSettings()
        settings.retention = .oneDay
        let h = Harness(settings: settings)

        h.pasteboard.copyText("expiring text")
        h.history.poll()
        h.pasteboard.copyImage(Data([1, 2, 3]))
        h.history.poll()
        XCTAssertEqual(h.files(in: "Images").count, 1)

        h.clock.advance(day + 1)
        h.history.applyRetention()

        XCTAssertTrue(h.history.items.isEmpty)
        XCTAssertTrue(h.files(in: "Images").isEmpty)
        XCTAssertTrue(h.files(in: "Thumbnails").isEmpty)
        XCTAssertFalse(h.indexContents.contains("expiring text"))
    }

    func testItemsThatExpiredWhileNotRunningAreRemovedOnLaunch() async {
        var settings = ClipstackSettings()
        settings.retention = .oneWeek
        let h = Harness(settings: settings)
        h.pasteboard.copyText("stale")
        h.history.poll()

        h.clock.advance(8 * day)
        h.relaunch()
        XCTAssertTrue(h.history.items.isEmpty)
        XCTAssertFalse(h.indexContents.contains("stale"))
    }

    func testMaxItemsDropsOldestFirst() async {
        var settings = ClipstackSettings()
        settings.maxItems = 3
        let h = Harness(settings: settings)
        for n in 1...5 {
            h.pasteboard.copyText("item \(n)")
            h.history.poll()
            h.clock.advance(1)
        }
        XCTAssertEqual(h.history.items.map(\.text), ["item 5", "item 4", "item 3"])
    }

    func testShorteningRetentionAppliesImmediately() async {
        let h = Harness()
        h.pasteboard.copyText("two days old")
        h.history.poll()
        h.clock.advance(2 * day)
        h.history.applyRetention()
        XCTAssertEqual(h.history.items.count, 1, "30-day default keeps it")

        h.history.updateSettings { $0.retention = .oneDay }
        XCTAssertTrue(h.history.items.isEmpty)
    }

    func testForeverKeepsOldItems() async {
        var settings = ClipstackSettings()
        settings.retention = .forever
        let h = Harness(settings: settings)
        h.pasteboard.copyText("ancient")
        h.history.poll()
        h.clock.advance(3650 * day)
        h.history.applyRetention()
        XCTAssertEqual(h.history.items.count, 1)
    }

    func testPolicyIsPure() async {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let items = (0..<4).map { i in
            ClipItem(kind: .text, createdAt: now.addingTimeInterval(TimeInterval(-i) * day),
                     text: "\(i)", byteCount: 1, fingerprint: "\(i)")
        }
        let result = RetentionPolicy.apply(to: items.reversed(), retention: .oneWeek, maxItems: 2, now: now)
        XCTAssertEqual(result.kept.map(\.text), ["0", "1"])
        XCTAssertEqual(Set(result.expired.compactMap(\.text)), ["2", "3"])
    }
}

@MainActor
final class DeletionTests: XCTestCase {
    func testDeleteRemovesTextFromIndexAndImageFiles() async {
        let h = Harness()
        h.pasteboard.copyText("private note")
        h.history.poll()
        h.pasteboard.copyImage(Data([4, 5, 6]))
        h.history.poll()

        h.history.delete(Set(h.history.items.map(\.id)))

        XCTAssertTrue(h.history.items.isEmpty)
        XCTAssertFalse(h.indexContents.contains("private note"))
        XCTAssertTrue(h.files(in: "Images").isEmpty)
        XCTAssertTrue(h.files(in: "Thumbnails").isEmpty)
    }

    func testClearHistoryRemovesEverything() async {
        let h = Harness()
        h.pasteboard.copyText("a")
        h.history.poll()
        h.pasteboard.copyImage(Data([1]))
        h.history.poll()

        h.history.clearHistory()
        XCTAssertTrue(h.history.items.isEmpty)
        XCTAssertTrue(h.files(in: "Images").isEmpty)
        XCTAssertEqual(h.indexContents, "")

        h.relaunch()
        XCTAssertTrue(h.history.items.isEmpty)
    }

    func testHistorySurvivesRelaunch() async {
        let h = Harness()
        h.pasteboard.copyText("keep me")
        h.history.poll()
        h.pasteboard.copyImage(Data([1, 2]))
        h.history.poll()

        h.relaunch()
        XCTAssertEqual(h.history.items.count, 2)
        XCTAssertEqual(h.history.items[0].kind, .image)
        XCTAssertEqual(h.history.items[1].text, "keep me")
    }

    func testOrphanedImageFilesAreCleanedUpOnLoad() async throws {
        let h = Harness()
        let orphan = h.directory.appendingPathComponent("Images/\(UUID().uuidString).png")
        try Data([1]).write(to: orphan)
        h.relaunch()
        XCTAssertTrue(h.files(in: "Images").isEmpty)
    }

    func testStorageDirectoryIsOwnerOnly() async throws {
        let h = Harness()
        h.pasteboard.copyText("x")
        h.history.poll()
        let attrs = try FileManager.default.attributesOfItem(atPath: h.directory.appendingPathComponent("Images").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let index = try FileManager.default.attributesOfItem(atPath: h.directory.appendingPathComponent("history.json").path)
        XCTAssertEqual((index[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testFailedSaveAfterDeleteDoesNotLeaveDeletedTextOnDisk() async {
        let h = Harness()
        h.pasteboard.copyText("delete me")
        h.history.poll()

        // A second history over the same files whose saves fail (e.g. disk full).
        let failing = FailingStore(wrapping: h.store)
        let history = ClipboardHistory(pasteboard: h.pasteboard, sourceApps: h.apps, store: failing,
                                       imageProcessor: h.images, settingsStorage: h.settingsStorage)
        history.load()
        failing.failSaves = true
        history.delete([history.items[0].id])

        XCTAssertEqual(history.notice?.level, .error)
        XCTAssertFalse(h.indexContents.contains("delete me"))
    }
}

/// Wraps a real store but can be told to fail saves.
final class FailingStore: HistoryStoring {
    let inner: FileHistoryStore
    var failSaves = false
    init(wrapping inner: FileHistoryStore) { self.inner = inner }

    var directoryURL: URL { inner.directoryURL }
    func loadItems() throws -> [ClipItem] { try inner.loadItems() }
    func saveItems(_ items: [ClipItem]) throws {
        if failSaves { throw CocoaError(.fileWriteNoPermission) }
        try inner.saveItems(items)
    }
    func storeImage(id: UUID, image: ProcessedImage) throws -> ImageInfo { try inner.storeImage(id: id, image: image) }
    func imageData(for item: ClipItem) throws -> Data { try inner.imageData(for: item) }
    func thumbnailURL(for item: ClipItem) -> URL? { inner.thumbnailURL(for: item) }
    func removeFiles(of items: [ClipItem]) { inner.removeFiles(of: items) }
    func removeIndex() { inner.removeIndex() }
    func removeAll() throws { try inner.removeAll() }
    func diskUsage() -> Int { inner.diskUsage() }
}
