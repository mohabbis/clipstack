import XCTest
@testable import ClipstackCore

@MainActor
final class DuplicateTests: XCTestCase {
    func testConsecutiveDuplicateTextIsSkipped() async {
        let h = Harness()
        h.pasteboard.copyText("same")
        h.history.poll()
        h.pasteboard.copyText("same")
        XCTAssertEqual(h.history.poll(), .duplicate)
        XCTAssertEqual(h.history.items.count, 1)
    }

    func testNonConsecutiveRepeatIsKept() async {
        let h = Harness()
        for value in ["a", "b", "a"] {
            h.pasteboard.copyText(value)
            h.history.poll()
        }
        XCTAssertEqual(h.history.items.map(\.text), ["a", "b", "a"])
    }

    func testDuplicateCheckIsCaseAndWhitespaceSensitive() async {
        let h = Harness()
        for value in ["Value", "value", "value "] {
            h.pasteboard.copyText(value)
            h.history.poll()
        }
        XCTAssertEqual(h.history.items.count, 3)
    }

    func testConsecutiveDuplicateImageIsSkippedBeforeProcessing() async {
        let h = Harness()
        h.pasteboard.copyImage(Data([1, 2, 3]))
        h.history.poll()
        h.pasteboard.copyImage(Data([1, 2, 3]))
        XCTAssertEqual(h.history.poll(), .duplicate)
        XCTAssertEqual(h.images.processCount, 1)
        XCTAssertEqual(h.files(in: "Images").count, 1)
    }

    func testTextAfterImageWithSameBytesIsNotADuplicate() async {
        let h = Harness()
        h.pasteboard.copyImage(Data("abc".utf8))
        h.history.poll()
        h.pasteboard.copyText("abc")
        guard case .captured = h.history.poll() else { return XCTFail("different kinds are never duplicates") }
    }

    func testDuplicateOfDeletedItemIsCapturedAgain() async {
        let h = Harness()
        h.pasteboard.copyText("x")
        h.history.poll()
        h.history.delete([h.history.items[0].id])
        h.pasteboard.copyText("x")
        guard case .captured = h.history.poll() else { return XCTFail("expected capture") }
    }
}
