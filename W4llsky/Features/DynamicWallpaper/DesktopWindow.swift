//
//  DesktopWindow.swift
//  W4llsky
//
//  A borderless window pinned to one screen, sitting at desktop level —
//  behind normal app windows, above the desktop picture, never stealing focus.
//

import AppKit
import CoreGraphics

final class DesktopWindow: NSWindow {

    init(screen: NSScreen) {
        // Designated initializer on this SDK takes no `screen:` — position explicitly after.
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false

        // One level below desktop icons, one level above the system desktop picture —
        // sitting exactly at .desktopWindow would tie with (and often lose to) macOS's
        // own desktop picture window, making this invisible.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)

        // Present on every Space, don't get swept into Exposé/Cmd+Tab/Mission Control cycling.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        contentView = NSView(frame: screen.frame)
        contentView?.wantsLayer = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
