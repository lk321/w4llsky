//
//  LockHotCorner.swift
//  W4llsky
//
//  The video can only be started *before* the screen locks (see
//  `SystemScreenSaver.startNow()`), and a hot key is the only combination we can
//  claim. macOS's own "Start Screen Saver" hot corner is the one other gesture that
//  goes through the saver instead of straight past it — it locks behind the video
//  exactly like ⌃⌘Q does — so offering to set it up is how W4llsky covers locking
//  with the mouse. It's plain Dock configuration: no event tap, no Accessibility
//  permission, and it keeps working when W4llsky isn't running.
//

import AppKit

enum LockHotCorner {
    enum Corner: String, CaseIterable {
        case topLeft = "tl", topRight = "tr", bottomLeft = "bl", bottomRight = "br"

        var title: String {
            switch self {
            case .topLeft: "Top Left"
            case .topRight: "Top Right"
            case .bottomLeft: "Bottom Left"
            case .bottomRight: "Bottom Right"
            }
        }
    }

    /// The Dock's action id for "Start Screen Saver". 1 is its "do nothing".
    private static let startScreenSaver = 5
    private static let disabled = 1
    private static let dock = "com.apple.dock" as CFString

    static var active: Corner? {
        Corner.allCases.first { action(at: $0) == startScreenSaver }
    }

    /// Passing nil clears whichever corner is currently set to start the saver.
    static func use(_ corner: Corner?) {
        for existing in Corner.allCases where action(at: existing) == startScreenSaver {
            write(disabled, at: existing)
        }
        if let corner { write(startScreenSaver, at: corner) }
        CFPreferencesSynchronize(dock, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)

        // Same ordering rule as WallpaperAgent: the Dock holds these in memory and
        // would flush its stale copy back over ours, so restart it after writing.
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock")
            .forEach { $0.forceTerminate() }
    }

    private static func action(at corner: Corner) -> Int {
        CFPreferencesCopyValue(
            "wvous-\(corner.rawValue)-corner" as CFString, dock,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        ) as? Int ?? disabled
    }

    private static func write(_ action: Int, at corner: Corner) {
        CFPreferencesSetValue(
            "wvous-\(corner.rawValue)-corner" as CFString, action as CFNumber, dock,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
        // Without clearing the modifier the corner only fires while a key is held.
        CFPreferencesSetValue(
            "wvous-\(corner.rawValue)-modifier" as CFString, 0 as CFNumber, dock,
            kCFPreferencesCurrentUser, kCFPreferencesAnyHost
        )
    }
}
