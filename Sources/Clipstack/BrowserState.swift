#if os(macOS)
import ClipstackCore
import Foundation
import Observation

/// Search, filter and selection state for one history list (popover or window).
@MainActor
@Observable
final class BrowserState {
    var query = ""
    var kind: KindFilter = .all
    var selectedID: UUID?
    /// Incremented each time the popover opens so the view can refocus the search field.
    var focusRequest = 0

    func results(in history: ClipboardHistory) -> [ClipItem] {
        history.search(query, kind: kind)
    }

    /// The selected item if it's visible, otherwise the first result.
    func effectiveSelection(in results: [ClipItem]) -> ClipItem? {
        if let selectedID, let item = results.first(where: { $0.id == selectedID }) { return item }
        return results.first
    }

    func moveSelection(by delta: Int, in results: [ClipItem]) {
        guard !results.isEmpty else { return }
        let current = effectiveSelection(in: results).flatMap { item in results.firstIndex { $0.id == item.id } } ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedID = results[next].id
    }

    func reset() {
        query = ""
        selectedID = nil
        focusRequest += 1
    }
}

/// Transient app-level status shown in Settings.
@MainActor
@Observable
final class AppStatus {
    var hotKeyUnavailable = false
}
#endif
