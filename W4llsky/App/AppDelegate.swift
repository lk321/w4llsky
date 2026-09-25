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
    private var battery: BatteryMonitor?
    /// On battery and below the user's threshold: nothing decodes, in the app or the saver.
    private var isBatteryLow = false
    /// The saver has to play on the lock screen whatever covers the desktop.
    private var isScreenLocked = false
    /// The unit tests run inside this app. Their host must not tell the real saver to pause.
    private let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

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
                    // Displays first, and read fresh. Sleeping at the office and waking at
                    // home can deliver this before the screen-parameters notification, and
                    // then the cached list still names the office monitors: waking first
                    // would re-attach and order front the office windows at office
                    // coordinates over the home desktop until the displays were
                    // re-announced. A race in the code, not one seen happening; it matters
                    // now that W4llsky draws every display.
                    self.displayObserver.resync()
                    self.reconcile(self.displayObserver.current)
                    // Unconditionally, *not* via setSuspended(false): a wake can arrive
                    // with nothing suspended — an unlock that beat it to clearing the
                    // flag, or a KVM/monitor input switch with no sleep notification at
                    // all — and skipping the re-attach there is the "wallpaper reverted
                    // to the desktop picture" bug this observer exists to prevent.
                    self.engine.handleWake()
                    // Woken on the lock screen (a key press on a sleeping, locked Mac):
                    // nothing of ours is visible yet, and unlocking has to find the engine
                    // suspended, or it skips the surface rebuild and the desktop comes
                    // back frozen.
                    if self.isScreenLocked { self.engine.setSuspended(true) }
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
                MainActor.assumeIsolated { self?.screenLockChanged(locked: suspended) }
            })
        }
        wakeTokens.append(DistributedNotificationCenter.default().addObserver(
            forName: LockScreenLibrary.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.lockVideoChanged() }
        })

        // However many displays and videos there are, the wallpaper yields before the Mac
        // chokes: stop decoding under memory warning or heat, release every decoder under
        // critical memory, and rebuild only once memory is back to normal.
        pressure = SystemPressure { [weak self] level in
            guard let self else { return }
            self.engine.setThrottled(level != .normal)
            self.reconcile(self.displayObserver.current)
        }
        engine.setThrottled(pressure?.level != .normal)

        // Low battery frees the decoders the same way critical memory does. IOKit calls
        // back on every percent, so only a change of verdict reconciles.
        battery = BatteryMonitor { [weak self] in self?.powerChanged() }
        isBatteryLow = BatteryMonitor.isLow(BatteryMonitor.read(), threshold: store.configuration.batteryThreshold)

        if !isTestHost { ScreenSaverInstaller.installIfOutdated() } // a test run would install its Debug saver
        SystemScreenSaver.removeRedundantScreenSaverSelection()
        reconcile(displayObserver.current)

        menuBar = MenuBarController(engine: engine, store: store, displayObserver: displayObserver)
        menuBar?.pressureLevel = { [weak self] in self?.pressure?.level ?? .normal }
        menuBar?.isBatteryLow = { [weak self] in self?.isBatteryLow ?? false }
        menuBar?.onPowerSettingsChanged = { [weak self] in self?.powerChanged() }
        refreshLockHotKey()
        menuBar?.onLockSetupChanged = { [weak self] in self?.lockSetupChanged() }
    }

    /// Hands the saver's pause back while nothing of ours is drawing. Only a clean quit
    /// gets here; see `LockScreenLibrary.coverURL` for the crash case.
    func applicationWillTerminate(_ notification: Notification) {
        publishCover(false)
        if !isTestHost { LockScreenLibrary.setPowerSaving(false) }
    }

    private func powerChanged() {
        let low = BatteryMonitor.isLow(BatteryMonitor.read(), threshold: store.configuration.batteryThreshold)
        guard low != isBatteryLow else { return }
        isBatteryLow = low
        reconcile(displayObserver.current)
    }

    /// The desktop hands over to the lock screen and back. On lock the saver takes the
    /// playhead from us, so the lock screen continues the frame the desktop was showing;
    /// on unlock we take it back, extrapolated over however long the Mac stayed locked,
    /// which is where the lock screen's copy got to.
    private func screenLockChanged(locked: Bool) {
        isScreenLocked = locked
        let lockVideo = VideoPipeline.existing(for: LockScreenLibrary.videoURL)
        if locked {
            if let lockVideo, !isTestHost {
                LockScreenLibrary.savePlayhead(.init(
                    position: lockVideo.position,
                    hostTime: CACurrentMediaTime(),
                    rate: store.configuration.playbackRate
                ))
            }
            publishCover(false)
            engine.setSuspended(true)
        } else {
            engine.setSuspended(false)
            if let lockVideo, let playhead = LockScreenLibrary.loadPlayhead() {
                lockVideo.seek(to: playhead.position(at: CACurrentMediaTime()))
            }
            reconcile(displayObserver.current)
        }
    }

    private func publishCover(_ covered: Bool) {
        guard !isTestHost else { return }
        LockScreenLibrary.setDesktopCovered(covered)
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
        if !isTestHost { LockScreenLibrary.setPowerSaving(isBatteryLow) }
        // Critical memory or low battery: every window goes, and with it every decoder.
        // None is built until it's over. What shows through is the saver's still frame
        // (it releases too) or the system's own desktop picture.
        guard pressure?.level != .release, !isBatteryLow else {
            engine.removeAllForMissingDisplays(currentIDs: [])
            publishCover(false)
            return
        }

        let ids = Set(snapshots.map(\.id))
        engine.removeAllForMissingDisplays(currentIDs: ids)

        // When the video is the system wallpaper, macOS is supposed to draw it on every
        // display and behind the lock screen. On the desktop it doesn't, reliably: the saver
        // decodes at 60 fps while the screen moves about once every few seconds, on every
        // display including an uncovered primary (`displayed: 0–3` per 6s, `55` once). Our
        // own window is smooth on the same setup, so we draw every display ourselves: its
        // own assignment, or else the lock screen video. The system copy stays up for the
        // lock screen and keeps decoding underneath (~6.5%), which is the price of a warm
        // lock. Measured on macOS 27.0 (26A428), laptop plus two 1080p monitors.
        let lockVideo = SystemScreenSaver.isDesktopWallpaper ? LockScreenLibrary.load() : nil

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

            if assignment == nil, lockVideo == nil {
                // Nothing of ours belongs here — including a stand-in left over from
                // before "Play on the Lock Screen" was turned off.
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
            } else if let lockVideo {
                engine.assign(
                    url: LockScreenLibrary.videoURL,
                    rate: store.configuration.playbackRate,
                    fillMode: lockVideo.fillMode,
                    to: screen,
                    displayID: snapshot.id
                )
            }
        }

        // From what the engine actually holds, after the loop, so a rebuild's
        // remove-then-assign never shows the saver a gap. The saver's pipeline is shared by
        // all its views, so it may pause only if *every* display is ours.
        publishCover(
            lockVideo != nil && !isScreenLocked && !snapshots.isEmpty
                && snapshots.allSatisfy { engine.hasWindow(for: $0.id) }
        )
    }

    /// `install` swaps LockScreen.mp4 for a new inode at the same path, so a stand-in
    /// window would keep playing the old file. Unassigned displays only ever hold
    /// stand-ins (`removeVideo` drops the rest), so rebuild exactly those.
    /// ponytail: rebuilds on speed/scaling changes too, a brief restart of the clip;
    /// compare file identity first if that ever bothers anyone.
    private func lockVideoChanged() {
        for snapshot in displayObserver.current where store.configuration.assignments[snapshot.id] == nil {
            engine.remove(displayID: snapshot.id)
        }
        reconcile(displayObserver.current)
    }
}
