#if os(macOS)
import AppKit
import ClipstackCore
import Observation
import SwiftUI

/// Actions the SwiftUI views can trigger.
@MainActor
protocol AppActions: AnyObject {
    /// Copies from the popover, closes it and returns focus to the previously active app.
    func copyFromPopover(_ item: ClipItem)
    func copy(_ item: ClipItem)
    func showHistoryWindow()
    func showSettings()
    func confirmClearHistory()
    func quit()
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, AppActions {
    static let bundleIdentifier = Bundle.main.bundleIdentifier ?? "io.github.mohabbis.Clipstack"
    static let pollInterval: TimeInterval = 0.5

    private var history: ClipboardHistory!
    private let status = AppStatus()
    private let popoverState = BrowserState()
    private let windowState = BrowserState()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var pollTimer: Timer?
    private var retentionTimer: Timer?
    private var hotKey: GlobalHotKey?
    private var registeredShortcut: GlobalShortcut?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var lastPopoverClose = Date.distantPast

    // MARK: - Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        history = makeHistory()
        history.load()

        NSApp.mainMenu = makeMainMenu()
        setUpStatusItem()
        setUpPopover()

        hotKey = GlobalHotKey { [weak self] in
            MainActor.assumeIsolated { self?.togglePopover() }
        }
        applySettings()
        observeSettings()
        startTimers()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        retentionTimer?.invalidate()
        hotKey?.unregister()
    }

    private func makeHistory() -> ClipboardHistory {
        let directory: URL
        do {
            directory = try FileHistoryStore.defaultDirectory(bundleIdentifier: Self.bundleIdentifier)
        } catch {
            // Application Support should always exist; fall back to a private temporary folder.
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(Self.bundleIdentifier)
        }
        return ClipboardHistory(
            pasteboard: SystemPasteboard(),
            sourceApps: FrontmostAppProvider(),
            store: FileHistoryStore(directoryURL: directory),
            imageProcessor: ImageIOProcessor(),
            settingsStorage: UserDefaultsSettingsStorage()
        )
    }

    private func startTimers() {
        let poll = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.history.poll() }
        }
        poll.tolerance = 0.2
        RunLoop.main.add(poll, forMode: .common) // keep polling while menus are open
        pollTimer = poll

        let retention = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.history.applyRetention() }
        }
        retention.tolerance = 10
        RunLoop.main.add(retention, forMode: .common)
        retentionTimer = retention
    }

    // MARK: - Settings observation

    private func observeSettings() {
        withObservationTracking {
            _ = history.settings
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.applySettings()
                    self?.observeSettings()
                }
            }
        }
    }

    private func applySettings() {
        updateStatusItemAppearance()
        let shortcut = history.settings.globalShortcut
        if shortcut != registeredShortcut {
            registeredShortcut = shortcut
            status.hotKeyUnavailable = !(hotKey?.register(shortcut) ?? true)
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        updateStatusItemAppearance()
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        let paused = history.settings.isPaused
        let symbol = paused ? "pause.circle" : "list.clipboard"
        let description = paused ? "Clipstack — capture paused" : "Clipstack — recording clipboard"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = description
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if wantsMenu {
            showStatusMenu()
        } else if !popover.isShown, Date().timeIntervalSince(lastPopoverClose) < 0.25 {
            // The transient popover already closed on mouse-down; don't reopen it on mouse-up.
            return
        } else {
            togglePopover()
        }
    }

    private func showStatusMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        let paused = history.settings.isPaused
        menu.addItem(withTitle: paused ? "Resume Capture" : "Pause Capture",
                     action: #selector(togglePauseFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open History Window", action: #selector(showHistoryWindowFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMenu), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Clear History…", action: #selector(clearHistoryFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Clipstack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        // Attach temporarily so the menu drops down from the status item like a normal menu extra.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePauseFromMenu() { history.setPaused(!history.settings.isPaused) }
    @objc private func showHistoryWindowFromMenu() { showHistoryWindow() }
    @objc private func showSettingsFromMenu() { showSettings() }
    @objc private func clearHistoryFromMenu() { confirmClearHistory() }

    // MARK: - Popover

    private func setUpPopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentSize = PopoverView.size
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(history: history, state: popoverState, actions: self)
        )
    }

    func togglePopover() {
        if popover.isShown {
            closePopover(returnFocus: true)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApp = frontmost
        }
        popoverState.reset()
        // An accessory app must activate for its popover to receive keystrokes.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        installKeyMonitor()
    }

    private func closePopover(returnFocus: Bool) {
        popover.performClose(nil)
        if returnFocus, historyWindow?.isVisible != true, settingsWindow?.isVisible != true {
            previousApp?.activate()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        removeKeyMonitor()
    }

    // MARK: - Keyboard

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent isn't Sendable, so copy out the plain values before entering main-actor code.
            let key = PopoverKey(event)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, let window = key.window,
                      window == self.popover.contentViewController?.view.window.map(ObjectIdentifier.init)
                else { return false }
                return self.handlePopoverKey(key)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Popover shortcuts. Focus stays in the search field, so navigation keys are routed here.
    private func handlePopoverKey(_ key: PopoverKey) -> Bool {
        let results = popoverState.results(in: history)
        let flags = key.modifierFlags

        switch Int(key.keyCode) {
        case 125: // ↓
            popoverState.moveSelection(by: 1, in: results)
            return true
        case 126: // ↑
            popoverState.moveSelection(by: -1, in: results)
            return true
        case 36, 76: // Return, Enter
            if let item = popoverState.effectiveSelection(in: results) { copyFromPopover(item) }
            return true
        case 53: // Esc: clear the search first, then close
            if popoverState.query.isEmpty {
                closePopover(returnFocus: true)
            } else {
                popoverState.query = ""
            }
            return true
        case 51 where flags == .command: // ⌘⌫ deletes the selected item
            if let item = popoverState.effectiveSelection(in: results),
               let index = results.firstIndex(where: { $0.id == item.id }) {
                // Keep the selection in place by moving it to a neighbour.
                let neighbor = results.indices.contains(index + 1) ? results[index + 1]
                    : (index > 0 ? results[index - 1] : nil)
                popoverState.selectedID = neighbor?.id
                history.delete([item.id])
            }
            return true
        default:
            break
        }

        // ⌘1 … ⌘9 copy the nth visible item.
        if flags == .command, let chars = key.characters,
           let digit = Int(chars), (1...9).contains(digit) {
            if results.indices.contains(digit - 1) { copyFromPopover(results[digit - 1]) }
            return true
        }
        return false
    }

    /// The parts of a key-down event the popover needs, as Sendable values.
    private struct PopoverKey: Sendable {
        let keyCode: UInt16
        let modifierFlags: NSEvent.ModifierFlags
        let characters: String?
        let window: ObjectIdentifier?

        init(_ event: NSEvent) {
            keyCode = event.keyCode
            modifierFlags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            characters = event.charactersIgnoringModifiers
            window = event.window.map(ObjectIdentifier.init)
        }
    }

    // MARK: - AppActions

    func copyFromPopover(_ item: ClipItem) {
        guard history.copyToClipboard(item) else { return }
        closePopover(returnFocus: true)
    }

    func copy(_ item: ClipItem) {
        history.copyToClipboard(item)
    }

    func showHistoryWindow() {
        closePopover(returnFocus: false)
        if historyWindow == nil {
            let window = makeWindow(title: "Clipstack History", size: NSSize(width: 860, height: 560),
                                    resizable: true, autosaveName: "ClipstackHistoryWindow")
            window.contentViewController = NSHostingController(
                rootView: HistoryWindowView(history: history, state: windowState, actions: self)
            )
            window.contentMinSize = NSSize(width: 620, height: 380)
            historyWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        closePopover(returnFocus: false)
        if settingsWindow == nil {
            let window = makeWindow(title: "Clipstack Settings", size: NSSize(width: 560, height: 500),
                                    resizable: false, autosaveName: "ClipstackSettingsWindow")
            window.contentViewController = NSHostingController(
                rootView: SettingsView(history: history, status: status, actions: self)
            )
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func confirmClearHistory() {
        closePopover(returnFocus: false)
        // Defer so the alert isn't run from inside a SwiftUI action or menu callback.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.runClearHistoryAlert() }
        }
    }

    private func runClearHistoryAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear clipboard history?"
        let count = history.items.count
        alert.informativeText = "This permanently deletes \(count == 1 ? "1 item" : "\(count) items") and any saved images from this Mac. It can’t be undone."
        alert.addButton(withTitle: "Clear History").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            history.clearHistory()
        }
    }

    func quit() {
        NSApp.terminate(nil)
    }

    @objc private func showSettingsFromMainMenu() { showSettings() }

    // MARK: - Windows & menus

    private func makeWindow(title: String, size: NSSize, resizable: Bool, autosaveName: String) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    /// Menu-bar apps have no visible main menu, but a main menu is still needed so standard
    /// shortcuts (⌘C, ⌘V, ⌘A, ⌘Z, ⌘W, ⌘,) work in text fields and windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Clipstack")
        appMenu.addItem(withTitle: "Settings…", action: #selector(showSettingsFromMainMenu), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Clipstack", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        return main
    }
}
#endif
