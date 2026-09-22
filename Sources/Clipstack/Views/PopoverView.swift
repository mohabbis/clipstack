#if os(macOS)
import ClipstackCore
import SwiftUI

/// The compact menu-bar popover: search, filter, recent items and capture status.
struct PopoverView: View {
    static let size = NSSize(width: 360, height: 480)

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
            if history.settings.isPaused && !history.items.isEmpty {
                PausedBanner()
                Divider()
            }
            if let notice = history.notice {
                NoticeBanner(notice: notice) { history.dismissNotice() }
                Divider()
            }
            if results.isEmpty {
                EmptyStateView.forResults(history: history, query: state.query, kind: state.kind)
            } else {
                list(results, selectedID: selected?.id)
            }
            Divider()
            footer
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .onAppear { searchFocused = true }
        .onChange(of: state.focusRequest) {
            // Wait a runloop turn: the popover window becomes key after the view updates.
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SearchField(text: $state.query, prompt: "Search history", focus: $searchFocused)
            Picker("Show", selection: $state.kind) {
                ForEach(KindFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Filter by type")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
    }

    private func list(_ results: [ClipItem], selectedID: UUID?) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    LazyVStack(spacing: 1) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            ClipRow(item: item,
                                    thumbnailURL: history.thumbnailURL(for: item),
                                    now: context.date,
                                    isSelected: item.id == selectedID,
                                    shortcutNumber: index < 9 ? index + 1 : nil)
                                .id(item.id)
                                .onTapGesture { actions.copyFromPopover(item) }
                                .contextMenu { itemMenu(item) }
                                .help("Click or press Return to copy")
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
            .onChange(of: state.selectedID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(newValue) }
            }
        }
    }

    @ViewBuilder
    private func itemMenu(_ item: ClipItem) -> some View {
        Button("Copy") { actions.copyFromPopover(item) }
        Divider()
        Button("Delete", role: .destructive) { history.delete([item.id]) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            CaptureStatusControl(history: history)
            Spacer()
            Text(history.items.count == 1 ? "1 item" : "\(history.items.count) items")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Menu {
                Button("Open History Window") { actions.showHistoryWindow() }
                Button("Settings…") { actions.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Divider()
                Button("Clear History…", role: .destructive) { actions.confirmClearHistory() }
                    .disabled(history.items.isEmpty)
                Divider()
                Button("Quit Clipstack") { actions.quit() }
                    .keyboardShortcut("q", modifiers: .command)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("More options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
#endif
