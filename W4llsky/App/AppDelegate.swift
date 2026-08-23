//
//  AppDelegate.swift
//  W4llsky
//
//  Wires displays → persisted assignments → wallpaper engine, and hosts the
//  menu bar item. Never opens the main window automatically.
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = WallpaperStore()
    private let engine = WallpaperEngine()
    private let displayObserver = DisplayObserver()
    private var menuBar: MenuBarController?
    private var lockHotKey: LockHotKey?
    private var wakeTokens: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar-only: no Dock icon, no Cmd+Tab

        displayObserver.onChange = { [weak self] snapshots in
            self?.reconcile(snapshots)
        }

        // Display sleep and system sleep both leave the video layers attached to a
        // surface that no longer exists; nothing else tells us to rebuild them.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            wakeTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.engine.handleWake()
                    self.reconcile(self.displayObserver.current)
                }
            })
        }
        reconcile(displayObserver.current)

        menuBar = MenuBarController(engine: engine, store: store, displayObserver: displayObserver)
        refreshLockHotKey()
        menuBar?.onLockSetupChanged = { [weak self] in self?.lockSetupChanged() }
    }

    /// Claimed only while the user wants it, so the plain macOS lock stays available
    /// by turning the menu item off.
    private func lockSetupChanged() {
        refreshLockHotKey()
        reconcile(displayObserver.current)
    }

    private func refreshLockHotKey() {
        guard store.configuration.usesLockHotKey, LockScreenLibrary.hasVideo, SystemScreenSaver.isSelected else {
            lockHotKey = nil
            return
        }
        if lockHotKey == nil {
            lockHotKey = LockHotKey { SystemScreenSaver.startNow() }
        }
    }

    /// Applies persisted assignments to whatever displays are currently connected,
    /// tears down windows for displays that disappeared, and repositions the rest.
    private func reconcile(_ snapshots: [DisplaySnapshot]) {
        let ids = Set(snapshots.map(\.id))
        engine.removeAllForMissingDisplays(currentIDs: ids)

        // macOS draws the video itself when it is selected as the system wallpaper, on
        // every display and behind the lock screen. Drawing our own copy over it would
        // decode the same file a second time for something nobody can see — and worse,
        // it *hides* the system's copy, which macOS then throttles to a couple of frames
        // a second. That throttled pipeline is the one the lock screen inherits, so it
        // has to spin back up to 30 fps while you watch: the stutter for the first
        // seconds of the lock screen was our own window's fault.
        let systemDrawsWallpaper = SystemScreenSaver.isDesktopWallpaper

        for snapshot in snapshots {
            guard let screen = displayObserver.screen(forID: snapshot.id) else { continue }
            let assignment = store.configuration.assignments[snapshot.id]

            if let assignment, systemDrawsWallpaper, systemPlays(assignment) {
                engine.remove(displayID: snapshot.id)
            } else if engine.hasWindow(for: snapshot.id) {
                engine.reposition(displayID: snapshot.id, screen: screen)
            } else if let assignment {
                engine.assign(
                    bookmark: assignment.bookmarkData,
                    rate: store.configuration.playbackRate,
                    fillMode: assignment.fillMode,
                    to: screen,
                    displayID: snapshot.id
                )
            }
        }
    }

    /// Only steps aside for the *same* file: a display given its own video still gets
    /// its own window, since the system wallpaper is one video for the whole Mac.
    private func systemPlays(_ assignment: WallpaperAssignment) -> Bool {
        guard let url = SecurityScopedBookmark.resolve(assignment.bookmarkData) else { return false }
        return LockScreenLibrary.isSameFile(as: url)
    }
}
