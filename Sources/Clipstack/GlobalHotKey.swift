#if os(macOS)
import Carbon.HIToolbox
import ClipstackCore
import Foundation

/// A system-wide shortcut registered with Carbon's `RegisterEventHotKey`.
///
/// This is the long-standing macOS API for app hot keys. Unlike a global `NSEvent` monitor or
/// an event tap, it does not observe other keystrokes and needs no Accessibility or
/// Input Monitoring permission.
final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        unregister()
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }

    /// Registers `shortcut`, replacing any previous one. Returns `false` if macOS refused it
    /// (typically because another app already registered the same combination).
    @discardableResult
    func register(_ shortcut: GlobalShortcut) -> Bool {
        unregister()
        guard let (keyCode, modifiers) = Self.keyCombination(for: shortcut) else { return true }
        installHandlerIfNeeded()
        let id = EventHotKeyID(signature: OSType(0x434C_5053), id: 1) // 'CLPS'
        let status = RegisterEventHotKey(keyCode, modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { hotKey.action() }
            return noErr
        }, 1, &eventType, context, &handlerRef)
    }

    private static func keyCombination(for shortcut: GlobalShortcut) -> (UInt32, UInt32)? {
        let v = UInt32(kVK_ANSI_V)
        switch shortcut {
        case .off: return nil
        case .controlOptionCommandV: return (v, UInt32(controlKey | optionKey | cmdKey))
        case .shiftCommandV: return (v, UInt32(shiftKey | cmdKey))
        case .optionCommandV: return (v, UInt32(optionKey | cmdKey))
        }
    }
}
#endif
