import XCTest
@testable import ClipstackCore

final class SearchTests: XCTestCase {
    private func text(_ value: String, app: String? = nil) -> ClipItem {
        ClipItem(kind: .text, createdAt: Date(), text: value, byteCount: value.utf8.count,
                 fingerprint: ContentFingerprint.make(value), sourceAppName: app)
    }

    private func image(app: String?) -> ClipItem {
        ClipItem(kind: .image, createdAt: Date(),
                 image: ImageInfo(fileName: "a.png", thumbnailFileName: "a.png", pixelWidth: 1, pixelHeight: 1),
                 byteCount: 1, fingerprint: "img", sourceAppName: app)
    }

    private lazy var items = [
        text("Meeting notes for Monday", app: "Notes"),
        text("https://example.com/Café-menu", app: "Safari"),
        image(app: "Preview"),
        text("git commit -m \"fix\"", app: "Terminal"),
    ]

    func testEmptyQueryReturnsEverythingInOrder() {
        XCTAssertEqual(HistorySearch.filter(items, query: "   "), items)
    }

    func testCaseInsensitive() {
        XCTAssertEqual(HistorySearch.filter(items, query: "MEETING").map(\.text), ["Meeting notes for Monday"])
    }

    func testDiacriticInsensitive() {
        XCTAssertEqual(HistorySearch.filter(items, query: "cafe").count, 1)
    }

    func testAllTermsMustMatch() {
        XCTAssertEqual(HistorySearch.filter(items, query: "notes monday").count, 1)
        XCTAssertEqual(HistorySearch.filter(items, query: "notes tuesday").count, 0)
    }

    func testMatchesSourceAppName() {
        XCTAssertEqual(HistorySearch.filter(items, query: "terminal").map(\.text), ["git commit -m \"fix\""])
        XCTAssertEqual(HistorySearch.filter(items, query: "preview").map(\.kind), [.image])
    }

    func testKindFilter() {
        XCTAssertEqual(HistorySearch.filter(items, query: "", kind: .images).count, 1)
        XCTAssertEqual(HistorySearch.filter(items, query: "", kind: .text).count, 3)
        XCTAssertEqual(HistorySearch.filter(items, query: "safari", kind: .images).count, 0)
    }

    func testImagesMatchTheWordImage() {
        XCTAssertEqual(HistorySearch.filter(items, query: "image").map(\.kind), [.image])
    }

    func testPunctuationIsSearchable() {
        XCTAssertEqual(HistorySearch.filter(items, query: "-m \"fix").count, 1)
    }
}

final class ModelTests: XCTestCase {
    func testPreviewCollapsesWhitespace() {
        let item = ClipItem(kind: .text, createdAt: Date(), text: "  line one\n\n\tline two  ",
                            byteCount: 0, fingerprint: "")
        XCTAssertEqual(item.previewText, "line one line two")
        XCTAssertEqual(item.lineCount, 3)
    }

    func testFingerprintDiffersForDifferentContent() {
        XCTAssertEqual(ContentFingerprint.make("abc"), ContentFingerprint.make("abc"))
        XCTAssertNotEqual(ContentFingerprint.make("abc"), ContentFingerprint.make("abd"))
    }

    func testSettingsDecodeToleratesMissingAndUnknownValues() throws {
        let json = #"{"isPaused": true, "retention": "someFutureValue", "excludedBundleIDs": ["a.b"]}"#
        let settings = try JSONDecoder().decode(ClipstackSettings.self, from: Data(json.utf8))
        XCTAssertTrue(settings.isPaused)
        XCTAssertEqual(settings.retention, ClipstackSettings.default.retention)
        XCTAssertEqual(settings.excludedBundleIDs, ["a.b"])
        XCTAssertEqual(settings.maxItems, ClipstackSettings.default.maxItems)
    }

    func testSettingsRoundTripThroughUserDefaults() throws {
        let suite = "ClipstackTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let storage = UserDefaultsSettingsStorage(defaults: defaults)
        XCTAssertEqual(storage.loadSettings(), .default)
        var settings = ClipstackSettings()
        settings.retention = .oneWeek
        settings.globalShortcut = .off
        storage.saveSettings(settings)
        XCTAssertEqual(storage.loadSettings(), settings)
    }

    func testShortTimeText() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // a Friday, 08:00 UTC
        XCTAssertEqual(TimeText.short(for: now.addingTimeInterval(-10), now: now, calendar: calendar), "Just now")
        XCTAssertEqual(TimeText.short(for: now.addingTimeInterval(-300), now: now, calendar: calendar), "5m ago")
        XCTAssertEqual(TimeText.short(for: now.addingTimeInterval(-3 * 3600), now: now, calendar: calendar), "3h ago")
        XCTAssertEqual(TimeText.short(for: now.addingTimeInterval(-24 * 3600), now: now, calendar: calendar), "Yesterday")
    }
}
