//
//  DisplaySnapshot.swift
//  W4llsky
//
//  Immutable value describing one connected display at a point in time.
//  Never hold onto an NSScreen itself — re-resolve it by id when needed.
//

import AppKit
import CoreGraphics

struct DisplaySnapshot: Identifiable, Equatable {
    /// Stable across sleep/wake and disconnect/reconnect of the same physical display.
    /// Falls back to the transient screen number for virtual/unusual displays.
    let id: String
    let name: String
    let frame: CGRect
    let backingScaleFactor: CGFloat
    let isMain: Bool
}

enum DisplaySnapshotFactory {
    static func snapshot(for screen: NSScreen) -> DisplaySnapshot {
        let displayID = screenNumber(for: screen)
        return DisplaySnapshot(
            id: persistentID(for: displayID) ?? "screen-\(displayID)",
            name: screen.localizedName,
            frame: screen.frame,
            backingScaleFactor: screen.backingScaleFactor,
            isMain: screen == NSScreen.main
        )
    }

    private static func screenNumber(for screen: NSScreen) -> CGDirectDisplayID {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private static func persistentID(for displayID: CGDirectDisplayID) -> String? {
        guard displayID != 0, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}
