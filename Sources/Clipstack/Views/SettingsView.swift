#if os(macOS)
import AppKit
import ClipstackCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let history: ClipboardHistory
    let status: AppStatus
    let actions: AppActions

    var body: some View {
        TabView {
            GeneralSettings(history: history, status: status)
                .tabItem { Label("General", systemImage: "gearshape") }
            PrivacySettings(history: history)
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
            StorageSettings(history: history, actions: actions)
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        .frame(width: 560, height: 500)
    }
}

/// Two-way binding to one settings field, routed through `ClipboardHistory.updateSettings`.
@MainActor
private func settingBinding<T>(_ history: ClipboardHistory, _ keyPath: WritableKeyPath<ClipstackSettings, T>) -> Binding<T> {
    Binding(
        get: { history.settings[keyPath: keyPath] },
        set: { value in history.updateSettings { $0[keyPath: keyPath] = value } }
    )
}

// MARK: - General

private struct GeneralSettings: View {
    let history: ClipboardHistory
    let status: AppStatus

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Pause capture", isOn: settingBinding(history, \.isPaused))
                Toggle("Save images", isOn: settingBinding(history, \.captureImages))
            } header: {
                Text("Capture")
            } footer: {
                Text("While paused, Clipstack doesn’t read the clipboard at all. Anything copied during a pause is never saved, even after you resume.")
                    .settingsFootnote()
            }

            Section {
                Picker("Open Clipstack", selection: settingBinding(history, \.globalShortcut)) {
                    ForEach(GlobalShortcut.allCases) { shortcut in
                        Text(shortcut.title).tag(shortcut)
                    }
                }
                if status.hotKeyUnavailable {
                    Label("That shortcut is already used by another app. Choose a different one.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                }
            } header: {
                Text("Keyboard Shortcut")
            } footer: {
                Text("Uses the standard macOS hot-key API, so no Accessibility or Input Monitoring permission is needed. Clipstack never types or pastes for you — press ⌘V yourself after choosing an item.")
                    .settingsFootnote()
            }

            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginItemError {
                    Text(loginItemError)
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                }
            } header: {
                Text("Startup")
            }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            loginItemError = "Couldn’t update the login item. This works only for the bundled Clipstack.app."
        }
        let actual = SMAppService.mainApp.status == .enabled
        if actual != launchAtLogin { launchAtLogin = actual }
    }
}

// MARK: - Privacy

private struct PrivacySettings: View {
    let history: ClipboardHistory

    @State private var newBundleID = ""
    @State private var inputError: String?

    var body: some View {
        Form {
            Section {
                if history.settings.excludedBundleIDs.isEmpty {
                    Text("No apps are excluded.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(history.settings.excludedBundleIDs, id: \.self) { bundleID in
                        ExcludedAppRow(bundleID: bundleID) {
                            history.updateSettings { $0.removeExclusion(bundleID) }
                        }
                    }
                }
                HStack {
                    TextField("Bundle ID", text: $newBundleID, prompt: Text("com.example.App"))
                        .labelsHidden()
                        .onSubmit(addTypedBundleID)
                    Button("Add", action: addTypedBundleID)
                        .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                    runningAppsMenu
                }
                if let inputError {
                    Text(inputError)
                        .foregroundStyle(.red)
                        .font(.system(size: 11))
                }
            } header: {
                Text("Excluded Apps")
            } footer: {
                Text("Nothing is saved while an excluded app is the frontmost app. Clipstack identifies apps by bundle identifier.")
                    .settingsFootnote()
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Copies an app marks as concealed or transient. Most password managers do this.",
                          systemImage: "eye.slash")
                    Label("Copied files from Finder (only text and images are supported).",
                          systemImage: "doc")
                    Label("Whatever was on the clipboard before Clipstack started.",
                          systemImage: "clock.arrow.circlepath")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            } header: {
                Text("Always Skipped")
            }
        }
        .formStyle(.grouped)
    }

    private var runningAppsMenu: some View {
        Menu("Add Running App") {
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                    && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
                .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
            ForEach(apps, id: \.processIdentifier) { app in
                let bundleID = app.bundleIdentifier ?? ""
                Button(app.localizedName ?? bundleID) {
                    history.updateSettings { $0.addExclusion(bundleID) }
                }
                .disabled(history.settings.isExcluded(bundleID: bundleID))
            }
        }
        .fixedSize()
    }

    private func addTypedBundleID() {
        let value = newBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ClipstackSettings.isPlausibleBundleID(value) else {
            inputError = "Enter a bundle identifier such as com.example.App."
            return
        }
        guard !history.settings.isExcluded(bundleID: value) else {
            inputError = "That app is already excluded."
            return
        }
        history.updateSettings { $0.addExclusion(value) }
        newBundleID = ""
        inputError = nil
    }
}

private struct ExcludedAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                    .resizable()
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(appURL.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                    .lineLimit(1)
                if appURL != nil {
                    Text(bundleID)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Not installed")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button(action: remove) {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from excluded apps")
            .accessibilityLabel("Remove \(bundleID)")
        }
    }
}

// MARK: - Storage

private struct StorageSettings: View {
    let history: ClipboardHistory
    let actions: AppActions

    @State private var diskUsage = 0

    var body: some View {
        Form {
            Section {
                Picker("Keep items for", selection: settingBinding(history, \.retention)) {
                    ForEach(RetentionPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                Picker("Keep at most", selection: settingBinding(history, \.maxItems)) {
                    ForEach(ClipstackSettings.maxItemsOptions, id: \.self) { count in
                        Text("\(count) items").tag(count)
                    }
                }
                Picker("Skip items larger than", selection: settingBinding(history, \.maxItemBytes)) {
                    ForEach(ClipstackSettings.maxItemBytesOptions, id: \.self) { bytes in
                        Text(ByteText.string(bytes)).tag(bytes)
                    }
                }
            } header: {
                Text("History")
            } footer: {
                Text("Older items are deleted automatically, including their image files. Shortening these limits deletes items right away.")
                    .settingsFootnote()
            }

            Section {
                LabeledContent("Stored") {
                    Text("\(history.items.count) items · \(ByteText.string(diskUsage))")
                        .monospacedDigit()
                }
                LabeledContent("Location") {
                    HStack(spacing: 6) {
                        Text(history.storageDirectory.path)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([history.storageDirectory])
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    Spacer()
                    Button("Clear History…", role: .destructive) { actions.confirmClearHistory() }
                        .disabled(history.items.isEmpty)
                }
            } header: {
                Text("On This Mac")
            } footer: {
                Text("Text is stored in history.json and images as PNG files in the folder above, readable only by your user account. Clipstack does not encrypt these files; they are protected by macOS account security and FileVault if you use it. The folder is excluded from Time Machine. Clipstack makes no network connections.")
                    .settingsFootnote()
            }
        }
        .formStyle(.grouped)
        .onAppear { diskUsage = history.diskUsage() }
        .onChange(of: history.items.count) { diskUsage = history.diskUsage() }
    }
}

private extension View {
    func settingsFootnote() -> some View {
        font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
#endif
