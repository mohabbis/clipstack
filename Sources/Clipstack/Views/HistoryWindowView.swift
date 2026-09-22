#if os(macOS)
import ClipstackCore
import SwiftUI

/// A larger window for browsing: list on the left, full preview and metadata on the right.
struct HistoryWindowView: View {
    let history: ClipboardHistory
    @Bindable var state: BrowserState
    let actions: AppActions

    @FocusState private var searchFocused: Bool

    var body: some View {
        let results = state.results(in: history)
        let selected = state.effectiveSelection(in: results)

        VStack(spacing: 0) {
            header
            Divider()
            if history.settings.isPaused {
                PausedBanner()
                Divider()
            }
            if let notice = history.notice {
                NoticeBanner(notice: notice) { history.dismissNotice() }
                Divider()
            }
            HSplitView {
                listPane(results, selected: selected)
                    .frame(minWidth: 260, idealWidth: 330, maxWidth: 480)
                ItemDetailView(history: history, item: selected, actions: actions)
                    .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 620, minHeight: 380)
    }

    private var header: some View {
        HStack(spacing: 10) {
            SearchField(text: $state.query, prompt: "Search text and app names", focus: $searchFocused)
                .frame(maxWidth: 360)
            Picker("Show", selection: $state.kind) {
                ForEach(KindFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            CaptureStatusControl(history: history)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func listPane(_ results: [ClipItem], selected: ClipItem?) -> some View {
        if results.isEmpty {
            EmptyStateView.forResults(history: history, query: state.query, kind: state.kind)
        } else {
            let selection = Binding<UUID?>(
                get: { selected?.id },
                set: { state.selectedID = $0 }
            )
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List(selection: selection) {
                    ForEach(results) { item in
                        ClipRow(item: item, thumbnailURL: history.thumbnailURL(for: item),
                                now: context.date, titleLineLimit: 2)
                            .tag(item.id)
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: UUID.self) { ids in
                    Button("Copy") { copy(ids, in: results) }
                        .disabled(ids.count != 1)
                    Divider()
                    Button(ids.count > 1 ? "Delete \(ids.count) Items" : "Delete", role: .destructive) {
                        history.delete(ids)
                    }
                } primaryAction: { ids in
                    copy(ids, in: results) // double-click
                }
                .onKeyPress(.return) {
                    guard let selected else { return .ignored }
                    actions.copy(selected)
                    return .handled
                }
                .onDeleteCommand {
                    if let selected { history.delete([selected.id]) }
                }
            }
        }
    }

    private func copy(_ ids: Set<UUID>, in results: [ClipItem]) {
        guard ids.count == 1, let id = ids.first, let item = results.first(where: { $0.id == id }) else { return }
        actions.copy(item)
    }
}

/// Full preview of one item.
struct ItemDetailView: View {
    let history: ClipboardHistory
    let item: ClipItem?
    let actions: AppActions

    /// Rendering megabytes of text in a SwiftUI `Text` is slow; show the start and say so.
    private static let maxPreviewCharacters = 20_000

    @State private var fullImage: NSImage?
    @State private var copiedID: UUID?

    var body: some View {
        if let item {
            VStack(alignment: .leading, spacing: 0) {
                content(item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer(item)
            }
            .task(id: item.id) {
                copiedID = nil
                fullImage = item.kind == .image ? history.imageData(for: item).flatMap(NSImage.init(data:)) : nil
            }
        } else {
            EmptyStateView(symbol: "sidebar.left", title: "No item selected",
                           message: "Select an item to preview it.")
        }
    }

    @ViewBuilder
    private func content(_ item: ClipItem) -> some View {
        switch item.kind {
        case .text:
            let text = item.text ?? ""
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(text.count > Self.maxPreviewCharacters
                         ? String(text.prefix(Self.maxPreviewCharacters)) : text)
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if text.count > Self.maxPreviewCharacters {
                        Text("Preview shows the first \(Self.maxPreviewCharacters.formatted()) characters. Copy puts the full text on the clipboard.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        case .image:
            Group {
                if let fullImage {
                    Image(nsImage: fullImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: CGFloat(item.image?.pixelWidth ?? 0),
                               maxHeight: CGFloat(item.image?.pixelHeight ?? 0))
                        .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.03))
        }
    }

    private func footer(_ item: ClipItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    KindBadge(kind: item.kind)
                    Text(detailSummary(item))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Text(sourceLine(item))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button(role: .destructive) {
                history.delete([item.id])
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete this item from history")
            Button {
                actions.copy(item)
                copiedID = item.id
            } label: {
                Label(copiedID == item.id ? "Copied" : "Copy",
                      systemImage: copiedID == item.id ? "checkmark" : "doc.on.doc")
                    .frame(minWidth: 64)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .buttonStyle(.borderedProminent)
            .help("Put this item on the clipboard (⌘↩)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func detailSummary(_ item: ClipItem) -> String {
        let size = ByteText.string(item.byteCount)
        switch item.kind {
        case .text:
            let characters = (item.text ?? "").count
            let lines = item.lineCount
            return "\(characters.formatted()) characters · \(lines == 1 ? "1 line" : "\(lines.formatted()) lines") · \(size)"
        case .image:
            return "\(item.dimensionsText ?? "") px · PNG · \(size)"
        }
    }

    private func sourceLine(_ item: ClipItem) -> String {
        let when = item.createdAt.formatted(date: .abbreviated, time: .shortened)
        if let app = item.sourceAppName { return "Copied from \(app), \(when)" }
        return "Copied \(when)"
    }
}
#endif
