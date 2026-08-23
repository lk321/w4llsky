//
//  LockHotKey.swift
//  W4llsky
//
//  ⌃⌘Q locks the Mac straight to the static lock screen, and macOS refuses to
//  start a screen saver once the screen is already locked. Starting the saver
//  *first* works the other way round: it plays the video and locks behind it.
//  So the only way to get "press the usual keys, see the video" is to claim the
//  shortcut before the system does.
//
//  Carbon's RegisterEventHotKey is the one API that can actually take a key
//  combination system-wide (NSEvent's global monitors observe but can't consume,
//  and they need Accessibility). The C callback can't carry context, hence the
//  single static handler.
//

import AppKit
import Carbon.HIToolbox

final class LockHotKey {
    private static var onPress: (() -> Void)?

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    /// Returns nil when the system refuses the combination.
    init?(onPress: @escaping () -> Void) {
        LockHotKey.onPress = onPress

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var handler: EventHandlerRef?
        let installed = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                // Carbon dispatches this on the main thread.
                MainActor.assumeIsolated { LockHotKey.onPress?() }
                return noErr
            },
            1, &spec, nil, &handler
        )
        guard installed == noErr else { return nil }
        eventHandler = handler

        var reference: EventHotKeyRef?
        let registered = RegisterEventHotKey(
            UInt32(kVK_ANSI_Q),
            UInt32(cmdKey | controlKey),
            EventHotKeyID(signature: OSType(0x57344C4B), id: 1), // 'W4LK'
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard registered == noErr else {
            if let eventHandler { RemoveEventHandler(eventHandler) }
            return nil
        }
        hotKey = reference
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
