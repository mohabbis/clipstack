import Foundation

/// Which item kinds to show.
public enum KindFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case images

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .images: return "Images"
        }
    }

    func includes(_ kind: ClipKind) -> Bool {
        switch self {
        case .all: return true
        case .text: return kind == .text
        case .images: return kind == .image
        }
    }
}

/// Local, in-memory search. Nothing leaves the process.
public enum HistorySearch {
    /// Returns items matching every whitespace-separated term in `query`, preserving order.
    /// Matching is case- and diacritic-insensitive and checks the item text and source app name.
    /// Image items can be found by source app name or by typing "image".
    public static func filter(_ items: [ClipItem], query: String, kind: KindFilter = .all) -> [ClipItem] {
        let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        return items.filter { item in
            guard kind.includes(item.kind) else { return false }
            return terms.allSatisfy { matches(item, term: $0) }
        }
    }

    private static func matches(_ item: ClipItem, term: String) -> Bool {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        if let text = item.text, text.range(of: term, options: options) != nil { return true }
        if let app = item.sourceAppName, app.range(of: term, options: options) != nil { return true }
        if item.kind == .image, "image".range(of: term, options: options) != nil { return true }
        return false
    }
}
