#if os(macOS)
import AppKit
import ClipstackCore
import SwiftUI

/// One history entry. Text and image items share a layout but differ in their leading tile.
struct ClipRow: View {
    let item: ClipItem
    let thumbnailURL: URL?
    let now: Date
    var isSelected = false
    /// Shows "⌘1" … "⌘9" for the first rows in the popover.
    var shortcutNumber: Int?
    var titleLineLimit = 2

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            leadingTile
            VStack(alignment: .leading, spacing: 3) {
                title
                metadata
            }
            Spacer(minLength: 4)
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.22)
                      : isHovering ? Color.primary.opacity(0.05) : .clear)
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var leadingTile: some View {
        switch item.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.quaternary))
        case .image:
            ThumbnailView(url: thumbnailURL)
                .frame(width: 34, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    @ViewBuilder private var title: some View {
        switch item.kind {
        case .text:
            let preview = item.previewText
            Text(preview.isEmpty ? "Whitespace" : preview)
                .font(.system(size: 13))
                .italic(preview.isEmpty)
                .foregroundStyle(preview.isEmpty ? Color.secondary : Color.primary)
                .lineLimit(titleLineLimit)
                .truncationMode(.tail)
        case .image:
            Text(item.dimensionsText.map { "Image  \($0)" } ?? "Image")
                .font(.system(size: 13))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private var metadata: some View {
        HStack(spacing: 4) {
            KindBadge(kind: item.kind)
            if let app = item.sourceAppName {
                Text("·")
                Text(app).lineLimit(1)
            }
            Text("·")
            Text(TimeText.short(for: item.createdAt, now: now))
                .help(item.createdAt.formatted(date: .complete, time: .standard))
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var accessibilityText: String {
        let what = item.kind == .text ? item.previewText : "Image \(item.dimensionsText ?? "")"
        let from = item.sourceAppName.map { ", from \($0)" } ?? ""
        return "\(what)\(from), copied \(TimeText.short(for: item.createdAt, now: now))"
    }
}

/// Small type label: "Text" or "Image", tinted differently so the two kinds scan apart.
struct KindBadge: View {
    let kind: ClipKind

    var body: some View {
        Text(kind.displayName.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .kerning(0.4)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .foregroundStyle(kind == .image ? Color.purple : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(kind == .image ? Color.purple.opacity(0.14) : Color.primary.opacity(0.07))
            )
    }
}

/// Loads a stored thumbnail PNG, with an in-memory cache.
struct ThumbnailView: View {
    let url: URL?

    var body: some View {
        if let url, let image = ThumbnailCache.shared.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
        }
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 300
    }

    func image(for url: URL) -> NSImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView {
    /// The right empty state for the current history, filter and query.
    @MainActor
    static func forResults(history: ClipboardHistory, query: String, kind: KindFilter) -> EmptyStateView {
        if history.items.isEmpty {
            if history.settings.isPaused {
                return EmptyStateView(symbol: "pause.circle", title: "Capture is paused",
                                      message: "Clipstack isn’t saving anything you copy.",
                                      actionTitle: "Resume Capture", action: { history.setPaused(false) })
            }
            return EmptyStateView(symbol: "list.clipboard", title: "Nothing copied yet",
                                  message: "Copy some text or an image and it will appear here. History stays on this Mac.")
        }
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return EmptyStateView(symbol: kind == .images ? "photo" : "text.alignleft",
                                  title: "No \(kind.title.lowercased()) yet",
                                  message: "Nothing of this type is in your history.")
        }
        return EmptyStateView(symbol: "magnifyingglass", title: "No matches",
                              message: "Nothing in your history matches “\(query)”.")
    }
}

/// Search field styled for compact utility windows.
struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12, weight: .medium))
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(focus)
                .accessibilityLabel("Search clipboard history")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focus.wrappedValue ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08),
                          lineWidth: focus.wrappedValue ? 1.5 : 0.5))
    }
}

/// Recording / Paused indicator with a one-click toggle. Kept visible in both windows.
struct CaptureStatusControl: View {
    let history: ClipboardHistory

    var body: some View {
        let paused = history.settings.isPaused
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Circle()
                    .fill(paused ? Color.orange : Color.green)
                    .frame(width: 7, height: 7)
                Text(paused ? "Paused" : "Recording")
                    .font(.system(size: 12, weight: .medium))
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(paused ? "Capture paused" : "Capture on")
            Button(paused ? "Resume" : "Pause") {
                history.setPaused(!paused)
            }
            .controlSize(.small)
            .help(paused ? "Start saving what you copy" : "Stop saving what you copy")
        }
    }
}

/// Content-free status messages from the history (skipped items, storage errors).
struct NoticeBanner: View {
    let notice: HistoryNotice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.level == .error ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(notice.level == .error ? Color.red : Color.secondary)
            Text(notice.message)
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(notice.level == .error ? Color.red.opacity(0.08) : Color.primary.opacity(0.04))
    }
}

/// Orange strip shown while capture is paused, so the state is hard to miss.
struct PausedBanner: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            Text("Capture is paused. New copies aren’t being saved.")
                .font(.system(size: 11))
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.1))
    }
}

enum ByteText {
    static func string(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
#endif
