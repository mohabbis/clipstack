import Foundation
@testable import ClipstackCore

final class FakePasteboard: PasteboardSource {
    private(set) var changeCount = 0
    var types: [String] = []
    var text: String?
    var image: PasteboardImage?
    private(set) var contentReads = 0
    private(set) var writes: [PasteboardWrite] = []

    func copyText(_ value: String, extraTypes: [String] = []) {
        changeCount += 1
        text = value
        image = nil
        types = ["public.utf8-plain-text"] + extraTypes
    }

    func copyImage(_ data: Data, type: String = "public.png") {
        changeCount += 1
        text = nil
        image = PasteboardImage(data: data, typeIdentifier: type)
        types = [type]
    }

    func currentTypes() -> [String] { types }

    func readText() -> String? {
        contentReads += 1
        return text
    }

    func readImage() -> PasteboardImage? {
        contentReads += 1
        return image
    }

    func write(_ content: PasteboardWrite) throws -> Int {
        writes.append(content)
        changeCount += 1
        switch content {
        case .text(let value):
            text = value
            image = nil
            types = ["public.utf8-plain-text"]
        case .pngImage(let data):
            text = nil
            image = PasteboardImage(data: data, typeIdentifier: "public.png")
            types = ["public.png"]
        }
        return changeCount
    }
}

final class FakeSourceApps: SourceAppProvider {
    var current: SourceApp? = SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit")
    func currentSourceApp() -> SourceApp? { current }
}

/// Pretends every image is a 10×5 PNG whose bytes are the input bytes.
final class FakeImageProcessor: ImageProcessing {
    var shouldFail = false
    private(set) var processCount = 0

    func process(_ image: PasteboardImage) throws -> ProcessedImage {
        processCount += 1
        if shouldFail { throw ImageProcessingError.unreadable }
        return ProcessedImage(pngData: image.data, thumbnailPNGData: Data(image.data.prefix(4)),
                              pixelWidth: 10, pixelHeight: 5)
    }
}

/// A clock tests can move forward.
final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipstackTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
final class Harness {
    let pasteboard = FakePasteboard()
    let apps = FakeSourceApps()
    let images = FakeImageProcessor()
    let settingsStorage: InMemorySettingsStorage
    let clock = TestClock()
    let directory: URL
    let store: FileHistoryStore
    private(set) var history: ClipboardHistory!

    init(settings: ClipstackSettings = ClipstackSettings()) {
        directory = makeTemporaryDirectory()
        store = FileHistoryStore(directoryURL: directory)
        settingsStorage = InMemorySettingsStorage(settings)
        history = makeHistory()
        history.load()
    }

    /// A fresh `ClipboardHistory` over the same disk store, as after an app relaunch.
    func makeHistory() -> ClipboardHistory {
        let clock = self.clock
        return ClipboardHistory(pasteboard: pasteboard, sourceApps: apps, store: store,
                                imageProcessor: images, settingsStorage: settingsStorage,
                                now: { clock.now })
    }

    func relaunch() {
        history = makeHistory()
        history.load()
    }

    func files(in subdirectory: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent(subdirectory).path)) ?? []
    }

    var indexContents: String {
        (try? String(contentsOf: directory.appendingPathComponent("history.json"), encoding: .utf8)) ?? ""
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
