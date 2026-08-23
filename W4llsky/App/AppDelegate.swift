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
        menuBar?.onLockHotKeyChanged = { [weak self] in self?.refreshLockHotKey() }
    }

    /// Claimed only while the user wants it, so the plain macOS lock stays available
    /// by turning the menu item off.
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

        for snapshot in snapshots {
            guard let screen = displayObserver.screen(forID: snapshot.id) else { continue }

            if engine.hasWindow(for: snapshot.id) {
                engine.reposition(displayID: snapshot.id, screen: screen)
            } else if let assignment = store.configuration.assignments[snapshot.id] {
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
}
