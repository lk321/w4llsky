//
//  MenuBarController.swift
//  W4llsky
//
//  The whole app is controllable from here without opening any SwiftUI window.
//  Menu content is rebuilt in menuNeedsUpdate right before it opens — that
//  doubles as the performance-stats refresh, so there's no timer at all.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

final class MenuBarController: NSObject, NSMenuDelegate {
    private let engine: WallpaperEngine
    private let store: WallpaperStore
    private let displayObserver: DisplayObserver
    private let resourceMonitor = AppResourceMonitor()

    private let statusItem: NSStatusItem
    private var isPaused = false
    private var mainWindow: NSWindow?

    init(engine: WallpaperEngine, store: WallpaperStore, displayObserver: DisplayObserver) {
        self.engine = engine
        self.store = store
        self.displayObserver = displayObserver
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "play.rectangle.on.rectangle", accessibilityDescription: "W4llsky")
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu construction

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(submenuItem(title: "Displays", submenu: buildDisplaysMenu()))
        menu.addItem(submenuItem(title: "Playback Speed", submenu: buildSpeedMenu()))
        menu.addItem(submenuItem(title: "Lock Screen", submenu: buildLockScreenMenu()))

        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: isPaused ? "Resume Wallpapers" : "Pause Wallpapers",
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        menu.addItem(pause)

        menu.addItem(.separator())

        let usage = resourceMonitor.sample()
        menu.addItem(infoItem(String(format: "CPU: %.1f%%", usage.cpuPercent)))
        menu.addItem(infoItem(String(format: "Memory: %.0f MB", usage.memoryMB)))

        menu.addItem(.separator())

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = LaunchAtLogin.isEnabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())

        let open = NSMenuItem(title: "Open W4llsky", action: #selector(openMainWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        menu.addItem(NSMenuItem(title: "Quit W4llsky", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func buildDisplaysMenu() -> NSMenu {
        let menu = NSMenu()
        let displays = displayObserver.current

        guard !displays.isEmpty else {
            menu.addItem(infoItem("No displays detected"))
            return menu
        }

        for display in displays {
            let assignment = store.configuration.assignments[display.id]
            let resolution = "\(Int(display.frame.width))×\(Int(display.frame.height))"
            let header = infoItem("\(display.name) — \(resolution)\(display.isMain ? "  (Main)" : "")")
            menu.addItem(header)

            if let assignment {
                menu.addItem(infoItem("   \(assignment.videoName)"))
            }

            let choose = NSMenuItem(
                title: assignment == nil ? "Choose Video…" : "Change Video…",
                action: #selector(chooseVideo(_:)),
                keyEquivalent: ""
            )
            choose.target = self
            choose.representedObject = display.id
            menu.addItem(choose)

            if assignment != nil {
                let remove = NSMenuItem(title: "Remove Wallpaper", action: #selector(removeVideo(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = display.id
                menu.addItem(remove)
            }

            menu.addItem(.separator())
        }

        return menu
    }

    private func buildSpeedMenu() -> NSMenu {
        let menu = NSMenu()
        for speed: Float in [0.5, 1.0, 1.5, 2.0] {
            let item = NSMenuItem(title: "\(speed.formatted())×", action: #selector(setSpeed(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = speed
            item.state = store.configuration.playbackRate == speed ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func buildLockScreenMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(infoItem("Requires enabling the W4llsky screen saver once"))

        let lock = store.configuration.lockScreen
        if let lock {
            menu.addItem(infoItem("   \(lock.videoName)"))
        }

        let choose = NSMenuItem(
            title: lock == nil ? "Choose Video…" : "Change Video…",
            action: #selector(chooseLockScreenVideo),
            keyEquivalent: ""
        )
        choose.target = self
        menu.addItem(choose)

        if lock != nil {
            let remove = NSMenuItem(title: "Remove", action: #selector(removeLockScreenVideo), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }

        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Open Screen Saver Settings…", action: #selector(openScreenSaverSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        return menu
    }

    private func submenuItem(title: String, submenu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private func infoItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func chooseVideo(_ sender: NSMenuItem) {
        guard let displayID = sender.representedObject as? String,
              let screen = displayObserver.screen(forID: displayID) else { return }

        guard let url = pickVideoURL(message: "Choose a video for \(screen.localizedName)") else { return }
        guard let bookmark = SecurityScopedBookmark.makeBookmark(for: url) else { return }

        store.configuration.assignments[displayID] = WallpaperAssignment(bookmarkData: bookmark, videoName: url.lastPathComponent)
        store.save()
        engine.assign(bookmark: bookmark, rate: store.configuration.playbackRate, to: screen, displayID: displayID)
    }

    @objc private func removeVideo(_ sender: NSMenuItem) {
        guard let displayID = sender.representedObject as? String else { return }
        store.configuration.assignments[displayID] = nil
        store.save()
        engine.remove(displayID: displayID)
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Float else { return }
        store.configuration.playbackRate = speed
        store.save()
        engine.setRate(speed)
    }

    @objc private func chooseLockScreenVideo() {
        guard let url = pickVideoURL(message: "Choose a video for the Lock Screen saver") else { return }
        guard let bookmark = SecurityScopedBookmark.makeBookmark(for: url) else { return }
        store.configuration.lockScreen = WallpaperAssignment(bookmarkData: bookmark, videoName: url.lastPathComponent)
        store.save()
    }

    @objc private func removeLockScreenVideo() {
        store.configuration.lockScreen = nil
        store.save()
    }

    @objc private func openScreenSaverSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Screen-Saver-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func togglePause() {
        isPaused.toggle()
        engine.setPaused(isPaused, resumeRate: store.configuration.playbackRate)
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "W4llsky"
        window.contentView = NSHostingView(rootView: ContentView())
        window.isReleasedWhenClosed = false
        window.center()
        mainWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func pickVideoURL(message: String) -> URL? {
        // Accessory (menu-bar-only) apps aren't "active" by default; an inactive process
        // sometimes doesn't get the sandbox's file-access grant attached properly when
        // the panel returns. Activating first makes the grant stick.
        NSApp.activate(ignoringOtherApps: true)

        let panel = NSOpenPanel()
        panel.message = message
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
