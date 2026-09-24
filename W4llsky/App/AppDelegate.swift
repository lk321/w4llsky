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
    private var pressure: SystemPressure?

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
                    // Unconditionally, *not* via setSuspended(false): a wake can arrive
                    // with nothing suspended — an unlock that beat it to clearing the
                    // flag, or a KVM/monitor input switch with no sleep notification at
                    // all — and skipping the re-attach there is the "wallpaper reverted
                    // to the desktop picture" bug this observer exists to prevent.
                    self.engine.handleWake()
                    self.reconcile(self.displayObserver.current)
                }
            })
        }

        // The mirror image, and the one nothing was doing: while the displays sleep the
        // players keep decoding at full rate into a surface that no longer exists. One
        // pipeline per display, for as long as the Mac is asleep.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            wakeTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.setSuspended(true) }
            })
        }

        // Same waste, different cause: the lock screen's shield takes the surface too,
        // and occlusion never reports it — nothing is *covering* our window, so AppKit
        // still calls it visible. These two are distributed notifications; loginwindow
        // is another process.
        for (name, suspended) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            wakeTokens.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.engine.setSuspended(suspended) }
            })
        }
        // However many displays and videos there are, the wallpaper yields before the Mac
        // chokes: stop decoding under memory warning or heat, release every decoder under
        // critical memory, and rebuild only once memory is back to normal.
        pressure = SystemPressure { [weak self] level in
            guard let self else { return }
            self.engine.setThrottled(level != .normal)
            self.reconcile(self.displayObserver.current)
        }
        engine.setThrottled(pressure?.level != .normal)

        ScreenSaverInstaller.installIfOutdated()
        SystemScreenSaver.removeRedundantScreenSaverSelection()
        reconcile(displayObserver.current)

        menuBar = MenuBarController(engine: engine, store: store, displayObserver: displayObserver)
        menuBar?.pressureLevel = { [weak self] in self?.pressure?.level ?? .normal }
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
        // Critical memory: every window goes, and none is built until it's over. The
        // system's own desktop picture shows through meanwhile.
        guard pressure?.level != .release else {
            engine.removeAllForMissingDisplays(currentIDs: [])
            return
        }

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

        // Resolved once instead of per display: `screen(forID:)` maps *every* NSScreen
        // through CGDisplayCreateUUIDFromDisplayID and `localizedName` to find one, so
        // calling it in this loop is N² IOKit round-trips per screen-parameters change.
        let screens = Dictionary(
            NSScreen.screens.map { (DisplaySnapshotFactory.snapshot(for: $0).id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        for snapshot in snapshots {
            guard let screen = screens[snapshot.id] else { continue }
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
