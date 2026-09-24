# Clipstack

A local-first clipboard history for macOS. Clipstack lives in the menu bar, quietly keeps
recent **text and images** you copy, and lets you search and put any of them back on the
clipboard. Everything stays on your Mac: no accounts, sync, telemetry or network access.

- **Menu-bar popover.** Recent items with text previews, image thumbnails, a type label, the source app and when each item was copied.
- **Search and filter.** Search is case- and accent-insensitive and matches both text and source-app names. Filter by All, Text or Images.
- **Keyboard first.** Type to search, use ↑/↓ to move, press Return to copy. Press ⌘1–⌘9 to copy one of the first nine items directly.
- **History window.** A resizable list with a full preview of text or the image, plus metadata.
- **Privacy controls.** Pause and resume capture in one click, with the state always shown. You can exclude apps and delete individual items or clear the whole history. You can also set retention and a size limit per item.
- **No Accessibility permission.** Clipstack only *puts items on the clipboard*. You press ⌘V yourself; it never simulates keystrokes.

## Requirements

- macOS 14 Sonoma or later (Apple silicon or Intel)
- Xcode 15 or later, or the matching Swift 5.9+ command-line tools, to build

## Build and run

```sh
# Run the unit tests
swift test

# Build a signed, sandboxed app bundle at build/Clipstack.app
scripts/build-app.sh
open build/Clipstack.app

# Optional: universal binary, or sign with your own identity
UNIVERSAL=1 scripts/build-app.sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
```

`build-app.sh` builds the release executable with SwiftPM and wraps it in an app bundle with
`Resources/Info.plist`. The `Info.plist` sets `LSUIElement`, so there's no Dock icon. The script then
signs the bundle ad hoc (or with `SIGN_IDENTITY`) using the App Sandbox entitlement in
`Resources/Clipstack.entitlements`. An ad-hoc-signed build runs on the Mac that built it. To
distribute Clipstack you need a Developer ID signature and notarization.

For development you can also open `Package.swift` in Xcode, or run `swift run Clipstack`.
A `swift run` build isn't a bundle, so it runs **unsandboxed**, stores data in a different
folder (see below), and can't register itself as a login item.

On Linux, only `ClipstackCore` and its tests are built. The app target compiles to a stub.

## Releasing

The website's **Download for Mac** button links to
`https://github.com/mohabbis/clipstack/releases/latest/download/Clipstack.zip`. That link works
only after a published GitHub release includes an asset named exactly `Clipstack.zip`.

1. On a Mac, run `UNIVERSAL=1 scripts/build-app.sh`. It writes `build/Clipstack.app` and `build/Clipstack.zip`.
2. Open the built app and check that it works.
3. Create a GitHub release (for example tag `v0.1.0`) and upload `build/Clipstack.zip` as its asset.

An ad-hoc-signed build isn't notarized. People who download it see macOS's
**“Clipstack” Not Opened** dialog, with **Move to Trash** and **Done**. The website's
install steps tell them to click **Done**, then **System Settings → Privacy & Security →
Open Anyway**. The zip also includes `How to open Clipstack.txt` with the same steps.
On macOS 14, Control-click → **Open** still works. On macOS 15 and later, Privacy & Security
is the way through.
To remove that step, sign with a Developer ID (`SIGN_IDENTITY=…`) and notarize the zip with
`xcrun notarytool submit build/Clipstack.zip --wait`. For a zipped app you can't staple the
ticket; Gatekeeper checks it online on first launch.

## Website

`site/index.html` is the landing page, deployed by Vercel from this repository. `vercel.json`
serves the `site/` folder as static files, with no build step, and sets strict security headers.
The page loads no external resources and uses no cookies or analytics.

## Using Clipstack

| Action | How |
| --- | --- |
| Open history | Click the menu-bar icon, or press the global shortcut (default **⌃⌥⌘V**, change or turn off in Settings) |
| Search | Just type; the search field is focused when the popover opens |
| Move selection | ↑ / ↓ |
| Copy selected item | Return, or click the item |
| Copy item 1–9 | ⌘1 … ⌘9 |
| Delete selected item | ⌘⌫ (popover), Delete (history window), or right-click → Delete |
| Clear search / close | Esc (first clears the search, then closes) |
| Pause / resume capture | The **Pause** button in the popover footer, or right-click the menu-bar icon |
| History window, Settings, Clear History, Quit | The ⋯ menu in the popover footer, or right-click the menu-bar icon |

After you copy an item from the popover, the popover closes and focus returns to the app you
were using, so you can press ⌘V straight away.

The menu-bar icon shows a clipboard while recording and a pause symbol while paused. A banner
in the popover and history window also shows when capture is paused.

## Privacy

Clipboard history can include passwords, private messages and financial details, so Clipstack
is conservative by default.

**What is stored**
- Plain text (UTF-8), including text from rich-text sources (formatting is dropped).
- Images (PNG, TIFF, JPEG, HEIC, GIF on the clipboard), converted to PNG, plus a thumbnail up to 320 px.
- For each item: when it was copied, its size, and the bundle ID and name of the frontmost app at that moment.

**What is never captured**
- Anything copied while capture is **paused**. While paused, Clipstack doesn't read clipboard contents at all. Content copied during a pause isn't picked up when you resume.
- Anything copied while an **excluded app** is frontmost. Clipstack checks exclusions before it reads the content. By default the list includes 1Password, Bitwarden, KeePassXC, Keychain Access and Passwords. You can manage the list in **Settings → Privacy**, either by bundle ID or by picking from running apps.
- Items an app marks with the [nspasteboard.org](http://nspasteboard.org) `ConcealedType`, `TransientType` or `AutoGeneratedType` markers. Most password managers use these.
- File copies from Finder, which are unsupported in this version.
- Whatever was already on the clipboard when Clipstack launched.
- Items larger than the per-item size limit (default 5 MB; options are 256 KB, 1 MB, 5 MB and 10 MB).

**Where it is stored**

All history is stored in Application Support, inside the app's sandbox container:

```
~/Library/Containers/io.github.mohabbis.Clipstack/Data/Library/Application Support/io.github.mohabbis.Clipstack/
    history.json        text items and metadata for all items
    Images/<id>.png     full images
    Thumbnails/<id>.png list thumbnails
```

When you run Clipstack unsandboxed (`swift run`), the same files go in
`~/Library/Application Support/io.github.mohabbis.Clipstack/`. **Settings → Storage** shows
the exact folder and has a **Show in Finder** button. Settings (pause state, exclusions and
limits) live in the app's `UserDefaults` and never contain clipboard content.

**Protection**
- The folder is created with owner-only permissions: `0700` for directories and `0600` for the index.
- The folder is excluded from Time Machine backups.
- **Content is not encrypted by Clipstack.** It's protected by your macOS account and, if enabled, FileVault full-disk encryption. Other processes running as your user may be able to read it, subject to macOS privacy protections for app containers.
- The app runs in the App Sandbox **without** the network-client entitlement, so macOS blocks outgoing connections. Clipstack contains no networking, analytics or logging of clipboard contents. Status messages such as "Skipped an item larger than 5 MB" never include content.

**Deletion and expiry**
- When you delete an item, or it expires, Clipstack rewrites the index without it and removes its image files.
- If the index can't be rewritten after a deletion (for example, because the disk is full), Clipstack deletes the index file instead of leaving deleted text on disk. It writes a fresh one on the next successful save.
- Expired items are removed at launch, after every capture, when you change retention settings, and once a minute.
- Stray image files that no item refers to are removed at launch.
- Like any app, Clipstack can't erase copies that other software already made, such as an APFS snapshot or a backup taken before you excluded the folder. Deleted data may also linger in free disk space until it's overwritten.

## Settings

- **General:** pause capture, save images on or off, global shortcut (None, ⌃⌥⌘V, ⇧⌘V or ⌥⌘V), open at login.
- **Privacy:** excluded apps, and a summary of what is always skipped.
- **Storage:** retention (1 day, 1 week, 30 days, 90 days or until deleted; default 30 days), maximum item count (100, 250, 500 or 1000; default 500), per-item size limit, disk usage, storage location, and Clear History.

The global shortcut uses Carbon's `RegisterEventHotKey`. This API watches for one key
combination only, so it needs **no Accessibility or Input Monitoring permission**. If another app already owns
the combination, Settings says so and you can pick another. Clipstack requests no permissions.

## Architecture

```
Sources/ClipstackCore/        Foundation-only logic, unit tested (builds on macOS and Linux)
  ClipItem.swift              item model, previews, duplicate fingerprints
  Pasteboard.swift            PasteboardSource / SourceAppProvider protocols, privacy marker types
  ClipboardHistory.swift      capture policy + orchestration (pause, exclusions, dedupe, limits, copy-back)
  HistoryStore.swift          JSON index + PNG files, atomic writes, orphan cleanup
  RetentionPolicy.swift       age and count expiry
  HistorySearch.swift         local search and type filter
  Settings.swift              settings model, exclusion list, UserDefaults persistence
  ImageProcessing.swift       image-normalisation protocol and limits
  TimeText.swift              "5m ago" style labels
Sources/Clipstack/            macOS app (AppKit lifecycle + SwiftUI views)
  AppDelegate.swift           status item, popover, windows, timers, keyboard routing, menus
  SystemAdapters.swift        NSPasteboard source, frontmost-app provider, ImageIO processor
  GlobalHotKey.swift          Carbon hot key
  BrowserState.swift          search/filter/selection state
  Views/                      popover, history window, settings, shared components
Tests/ClipstackCoreTests/     capture, duplicates, pause, exclusions, retention, deletion, search
```

Clipboard access goes through the `PasteboardSource` protocol, so the capture policy is tested
against a fake pasteboard. The fake counts content reads, which lets the tests assert that
nothing is read while paused or when the source app is excluded. Polling (every 0.5 s),
storage, search and UI are separate components.

## Limitations

- **Source-app attribution is a heuristic.** macOS doesn't say which app wrote to the clipboard. Clipstack uses the frontmost app when it notices the change (within about 0.5 s), so exclusions can miss copies from background tools or scripts. Concealed-type markers are the reliable signal, and most password managers set them.
- **Polling.** macOS has no clipboard-change notification. Clipstack checks the change counter every 0.5 s. If you copy twice within one interval, it records only the last copy.
- Only plain text and images are captured. There's no rich text, HTML, files or multiple items per copy yet. Images are always stored and restored as PNG (with TIFF also offered when restoring), so animated GIFs become still images.
- Text history is kept in one JSON file that is rewritten on each change. That's fine at the default limits (500 items, 5 MB per item), but it isn't designed for very large histories.
- Image decoding for thumbnails runs on the main thread. Very large images may cause a brief hitch when captured.
- No app icon asset is included yet; the bundle uses the generic app icon.
- There's no OCR, sync, AI features or automatic pasting. These are deliberately out of scope.

## Verification status

`ClipstackCore` was built and all of its unit tests pass (`swift test`, Swift 6.0.3, Linux).
The macOS app target (AppKit/SwiftUI) needs the macOS SDK. It has only been syntax-checked so far and
hasn't yet been compiled or run on a Mac. Run `swift test` and `scripts/build-app.sh` on a Mac
to verify it.
