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

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu-bar-only: no Dock icon, no Cmd+Tab

        displayObserver.onChange = { [weak self] snapshots in
            self?.reconcile(snapshots)
        }
        reconcile(displayObserver.current)

        menuBar = MenuBarController(engine: engine, store: store, displayObserver: displayObserver)
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
                    to: screen,
                    displayID: snapshot.id
                )
            }
        }
    }
}
