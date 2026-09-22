#if os(macOS)
import AppKit

// Clipstack uses an AppKit lifecycle (NSStatusItem + NSPopover) with SwiftUI views,
// which gives precise control over popover focus and returning focus to the previous app.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate() // NSApplication holds its delegate weakly; run() keeps this scope alive
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu-bar only; LSUIElement in Info.plist does the same for the bundle
    app.run()
}
#else
print("Clipstack is a macOS app. On this platform only ClipstackCore and its tests are built.")
#endif
