import Foundation

/// How long history items are kept before they expire.
public enum RetentionPeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case oneDay
    case oneWeek
    case oneMonth
    case threeMonths
    case forever

    public var id: String { rawValue }

    /// Maximum item age, or `nil` for no age limit.
    public var maxAge: TimeInterval? {
        let day: TimeInterval = 24 * 60 * 60
        switch self {
        case .oneDay: return day
        case .oneWeek: return 7 * day
        case .oneMonth: return 30 * day
        case .threeMonths: return 90 * day
        case .forever: return nil
        }
    }

    public var title: String {
        switch self {
        case .oneDay: return "1 Day"
        case .oneWeek: return "1 Week"
        case .oneMonth: return "30 Days"
        case .threeMonths: return "90 Days"
        case .forever: return "Until Deleted"
        }
    }
}

/// Preset global shortcuts for opening the popover. Registered with Carbon's
/// `RegisterEventHotKey`, which does not need Accessibility permission.
public enum GlobalShortcut: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case controlOptionCommandV
    case shiftCommandV
    case optionCommandV

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .off: return "None"
        case .controlOptionCommandV: return "⌃⌥⌘V"
        case .shiftCommandV: return "⇧⌘V"
        case .optionCommandV: return "⌥⌘V"
        }
    }
}

public struct ClipstackSettings: Codable, Equatable, Sendable {
    public var isPaused: Bool
    public var retention: RetentionPeriod
    public var maxItems: Int
    /// Items larger than this are not captured (UTF-8 bytes for text, PNG bytes for images).
    public var maxItemBytes: Int
    public var captureImages: Bool
    public var excludedBundleIDs: [String]
    public var globalShortcut: GlobalShortcut

    public static let maxItemsOptions = [100, 250, 500, 1000]
    public static let maxItemBytesOptions = [256 * 1024, 1024 * 1024, 5 * 1024 * 1024, 10 * 1024 * 1024]

    /// Password managers excluded out of the box. Most of these also mark their copies with
    /// concealed pasteboard types, which Clipstack honours regardless of this list.
    public static let defaultExcludedBundleIDs = [
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.bitwarden.desktop",
        "org.keepassxc.keepassxc",
        "com.apple.keychainaccess",
        "com.apple.Passwords",
    ]

    public static let `default` = ClipstackSettings()

    public init(
        isPaused: Bool = false,
        retention: RetentionPeriod = .oneMonth,
        maxItems: Int = 500,
        maxItemBytes: Int = 5 * 1024 * 1024,
        captureImages: Bool = true,
        excludedBundleIDs: [String] = ClipstackSettings.defaultExcludedBundleIDs,
        globalShortcut: GlobalShortcut = .controlOptionCommandV
    ) {
        self.isPaused = isPaused
        self.retention = retention
        self.maxItems = maxItems
        self.maxItemBytes = maxItemBytes
        self.captureImages = captureImages
        self.excludedBundleIDs = excludedBundleIDs
        self.globalShortcut = globalShortcut
    }

    /// Bundle identifiers are compared case-insensitively.
    public func isExcluded(bundleID: String) -> Bool {
        let needle = bundleID.lowercased()
        return excludedBundleIDs.contains { $0.lowercased() == needle }
    }

    /// Adds a bundle identifier to the exclusion list.
    /// Returns `false` if it is empty, malformed, or already present.
    @discardableResult
    public mutating func addExclusion(_ bundleID: String) -> Bool {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPlausibleBundleID(trimmed), !isExcluded(bundleID: trimmed) else { return false }
        excludedBundleIDs.append(trimmed)
        return true
    }

    public mutating func removeExclusion(_ bundleID: String) {
        let needle = bundleID.lowercased()
        excludedBundleIDs.removeAll { $0.lowercased() == needle }
    }

    public static func isPlausibleBundleID(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 255 else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        return value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // Decoding tolerates missing keys and unknown enum values so that settings written by
    // other versions never reset the user's exclusions or pause state.
    private enum CodingKeys: String, CodingKey {
        case isPaused, retention, maxItems, maxItemBytes, captureImages, excludedBundleIDs, globalShortcut
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipstackSettings()
        isPaused = (try? c.decodeIfPresent(Bool.self, forKey: .isPaused)) ?? d.isPaused
        retention = (try? c.decodeIfPresent(String.self, forKey: .retention))
            .flatMap(RetentionPeriod.init(rawValue:)) ?? d.retention
        maxItems = max(1, (try? c.decodeIfPresent(Int.self, forKey: .maxItems)) ?? d.maxItems)
        maxItemBytes = max(1, (try? c.decodeIfPresent(Int.self, forKey: .maxItemBytes)) ?? d.maxItemBytes)
        captureImages = (try? c.decodeIfPresent(Bool.self, forKey: .captureImages)) ?? d.captureImages
        excludedBundleIDs = (try? c.decodeIfPresent([String].self, forKey: .excludedBundleIDs)) ?? d.excludedBundleIDs
        globalShortcut = (try? c.decodeIfPresent(String.self, forKey: .globalShortcut))
            .flatMap(GlobalShortcut.init(rawValue:)) ?? d.globalShortcut
    }
}

/// Where settings are persisted. Settings never contain clipboard content.
public protocol SettingsStorage: AnyObject {
    func loadSettings() -> ClipstackSettings
    func saveSettings(_ settings: ClipstackSettings)
}

public final class UserDefaultsSettingsStorage: SettingsStorage {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "ClipstackSettings.v1") {
        self.defaults = defaults
        self.key = key
    }

    public func loadSettings() -> ClipstackSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(ClipstackSettings.self, from: data)
        else { return .default }
        return settings
    }

    public func saveSettings(_ settings: ClipstackSettings) {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: key)
        }
    }
}

public final class InMemorySettingsStorage: SettingsStorage {
    public var stored: ClipstackSettings

    public init(_ settings: ClipstackSettings = .default) {
        stored = settings
    }

    public func loadSettings() -> ClipstackSettings { stored }
    public func saveSettings(_ settings: ClipstackSettings) { stored = settings }
}
