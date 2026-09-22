import XCTest
@testable import ClipstackCore

@MainActor
final class CaptureTests: XCTestCase {
    func testCapturesTextWithSourceApp() async {
        let h = Harness()
        h.pasteboard.copyText("hello")

        guard case .captured(let item) = h.history.poll() else { return XCTFail("expected capture") }
        XCTAssertEqual(item.text, "hello")
        XCTAssertEqual(item.kind, .text)
        XCTAssertEqual(item.sourceAppName, "TextEdit")
        XCTAssertEqual(h.history.items.map(\.text), ["hello"])
    }

    func testNoChangeMeansNoWork() async {
        let h = Harness()
        XCTAssertEqual(h.history.poll(), .unchanged)
        XCTAssertEqual(h.pasteboard.contentReads, 0)
    }

    func testClipboardContentPresentAtLaunchIsNotCaptured() async {
        let h = Harness()
        h.pasteboard.copyText("copied before launch")
        h.relaunch()
        XCTAssertEqual(h.history.poll(), .unchanged)
        XCTAssertTrue(h.history.items.isEmpty)
    }

    func testCapturesImagesAndStoresFiles() async {
        let h = Harness()
        h.pasteboard.copyImage(Data([1, 2, 3, 4, 5]))

        guard case .captured(let item) = h.history.poll() else { return XCTFail("expected capture") }
        XCTAssertEqual(item.kind, .image)
        XCTAssertEqual(item.dimensionsText, "10 × 5")
        XCTAssertEqual(h.history.imageData(for: item), Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(h.files(in: "Images").count, 1)
        XCTAssertEqual(h.files(in: "Thumbnails").count, 1)
    }

    func testPrefersTextWhenBothTextAndImageArePresent() async {
        let h = Harness()
        h.pasteboard.copyText("cells")
        h.pasteboard.image = PasteboardImage(data: Data([9]), typeIdentifier: "public.png")
        guard case .captured(let item) = h.history.poll() else { return XCTFail("expected capture") }
        XCTAssertEqual(item.kind, .text)
    }

    func testImagesCanBeTurnedOff() async {
        var settings = ClipstackSettings()
        settings.captureImages = false
        let h = Harness(settings: settings)
        h.pasteboard.copyImage(Data([1, 2, 3]))
        XCTAssertEqual(h.history.poll(), .imagesDisabled)
        XCTAssertEqual(h.images.processCount, 0)
        XCTAssertTrue(h.files(in: "Images").isEmpty)
    }

    func testFileCopiesAreNotCaptured() async {
        let h = Harness()
        h.pasteboard.copyText("Report.pdf", extraTypes: [PasteboardTypes.fileURL])
        XCTAssertEqual(h.history.poll(), .unsupported)
        XCTAssertTrue(h.history.items.isEmpty)
    }

    func testEmptyClipboardIsUnsupported() async {
        let h = Harness()
        h.pasteboard.copyText("")
        XCTAssertEqual(h.history.poll(), .unsupported)
    }

    // MARK: Size limit

    func testTextOverSizeLimitIsSkipped() async {
        var settings = ClipstackSettings()
        settings.maxItemBytes = 10
        let h = Harness(settings: settings)

        h.pasteboard.copyText(String(repeating: "x", count: 11))
        XCTAssertEqual(h.history.poll(), .tooLarge(bytes: 11))
        XCTAssertTrue(h.history.items.isEmpty)
        XCTAssertEqual(h.history.notice?.level, .info)
        XCTAssertFalse(h.history.notice?.message.contains("xxx") ?? true, "notices must not contain content")

        h.pasteboard.copyText(String(repeating: "x", count: 10))
        guard case .captured = h.history.poll() else { return XCTFail("item at the limit should be kept") }
    }

    func testImageOverSizeLimitIsSkippedAndNotWritten() async {
        var settings = ClipstackSettings()
        settings.maxItemBytes = 4
        let h = Harness(settings: settings)
        h.pasteboard.copyImage(Data([1, 2, 3, 4, 5]))
        XCTAssertEqual(h.history.poll(), .tooLarge(bytes: 5))
        XCTAssertTrue(h.files(in: "Images").isEmpty)
    }

    func testUnreadableImageIsSkipped() async {
        let h = Harness()
        h.images.shouldFail = true
        h.pasteboard.copyImage(Data([1, 2]))
        XCTAssertEqual(h.history.poll(), .failed)
        XCTAssertTrue(h.history.items.isEmpty)
    }

    // MARK: Copy back

    func testCopyingAnItemBackIsNotRecapturedAsNew() async {
        let h = Harness()
        h.pasteboard.copyText("first")
        h.history.poll()
        h.pasteboard.copyText("second")
        h.history.poll()

        let first = h.history.items[1]
        XCTAssertTrue(h.history.copyToClipboard(first))
        XCTAssertEqual(h.pasteboard.writes, [.text("first")])
        XCTAssertEqual(h.history.poll(), .unchanged)
        XCTAssertEqual(h.history.items.map(\.text), ["second", "first"])

        // A later external copy is captured normally.
        h.pasteboard.copyText("third")
        guard case .captured = h.history.poll() else { return XCTFail("expected capture") }
    }

    func testCopyingImageBackWritesStoredPNG() async {
        let h = Harness()
        h.pasteboard.copyImage(Data([7, 7, 7]))
        h.history.poll()
        XCTAssertTrue(h.history.copyToClipboard(h.history.items[0]))
        XCTAssertEqual(h.pasteboard.writes, [.pngImage(Data([7, 7, 7]))])
    }
}
