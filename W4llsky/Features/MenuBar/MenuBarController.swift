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
    /// Which display (nil = lock screen) a scaling menu item applies to.
    private struct ScalingChoice {
        let displayID: String?
        let mode: FillMode
    }

    private let engine: WallpaperEngine
    private let store: WallpaperStore
    private let displayObserver: DisplayObserver
    private let resourceMonitor = AppResourceMonitor()

    /// Lets AppDelegate re-claim or release the ⌃⌘Q hot key.
    /// Anything that changes who draws the lock screen / wallpaper: the hot key has
    /// to be re-claimed and the desktop windows re-reconciled against it.
    var onLockSetupChanged: (() -> Void)?

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

        let about = NSMenuItem(title: "About W4llsky", action: #selector(openAboutWindow), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        // Our own selector rather than `terminate:`: macOS 26 recognises the standard
        // one and draws a symbol next to it, which is the only icon in a menu that has
        // none anywhere else.
        let quit = NSMenuItem(title: "Quit W4llsky", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
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

            if let assignment {
                menu.addItem(submenuItem(
                    title: "Scaling",
                    submenu: buildScalingMenu(current: assignment.fillMode, displayID: display.id)
                ))

                let remove = NSMenuItem(title: "Remove Wallpaper", action: #selector(removeVideo(_:)), keyEquivalent: "")
                remove.target = self
                remove.representedObject = display.id
                menu.addItem(remove)
            }

            menu.addItem(.separator())
        }

        return menu
    }

    /// Auto keeps the video uncropped when the display's aspect ratio is far from
    /// the video's (an ultrawide showing a 16:9 clip), and fills when it's close.
    private func buildScalingMenu(current: FillMode, displayID: String?) -> NSMenu {
        let menu = NSMenu()
        for mode in FillMode.allCases {
            let item = NSMenuItem(title: mode.title, action: #selector(setFillMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ScalingChoice(displayID: displayID, mode: mode)
            item.state = mode == current ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    /// The mouse counterpart to ⌃⌘Q: macOS's own screen-saver corner is the only other
    /// gesture that locks *through* the saver rather than past it.
    private func buildHotCornerMenu() -> NSMenu {
        let menu = NSMenu()
        let active = LockHotCorner.active

        let off = NSMenuItem(title: "Off", action: #selector(setHotCorner(_:)), keyEquivalent: "")
        off.target = self
        off.state = active == nil ? .on : .off
        menu.addItem(off)

        for corner in LockHotCorner.Corner.allCases {
            let item = NSMenuItem(title: corner.title, action: #selector(setHotCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = corner
            item.state = corner == active ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    private func buildIdleDelayMenu() -> NSMenu {
        let menu = NSMenu()
        let current = SystemScreenSaver.idleDelay
        for minutes in [1, 2, 5, 10, 20] {
            let item = NSMenuItem(title: minutes == 1 ? "1 minute" : "\(minutes) minutes",
                                  action: #selector(setIdleDelay(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes * 60
            item.state = current == minutes * 60 ? .on : .off
            menu.addItem(item)
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
        let lock = LockScreenLibrary.load()

        menu.addItem(infoItem(lock.map { "   \($0.videoName)" } ?? "No video set"))
        if lock != nil, SystemScreenSaver.isDesktopWallpaper, differsFromDesktopVideo {
            // macOS stops a wallpaper it can't see at all — measured: zero decode
            // pipelines while our own window covers it — so locking has to cold-start a
            // 4K decoder in front of the user. Matching the two videos is the fix, and
            // the menu is where they'd notice.
            menu.addItem(infoItem("   ⚠︎ Differs from the desktop video — starts cold"))
        }

        let choose = NSMenuItem(
            title: lock == nil ? "Choose Video…" : "Change Video…",
            action: #selector(chooseLockScreenVideo),
            keyEquivalent: ""
        )
        choose.target = self
        menu.addItem(choose)

        if let lock {
            menu.addItem(submenuItem(
                title: "Scaling",
                submenu: buildScalingMenu(current: lock.fillMode, displayID: nil)
            ))

            let remove = NSMenuItem(title: "Remove", action: #selector(removeLockScreenVideo), keyEquivalent: "")
            remove.target = self
            menu.addItem(remove)
        }

        menu.addItem(.separator())

        // The one item that matters: macOS 26 draws the lock screen from the desktop
        // wallpaper, so this is what actually puts the video there — whatever locks
        // the Mac, and with nothing else switched on.
        let onLockScreen = NSMenuItem(
            title: "Play on the Lock Screen",
            action: #selector(toggleDesktopWallpaper), keyEquivalent: ""
        )
        onLockScreen.target = self
        onLockScreen.state = SystemScreenSaver.isDesktopWallpaper ? .on : .off
        menu.addItem(onLockScreen)

        // Everything below is the screen-saver fallback, and it is genuinely inert while
        // the video is the wallpaper — worse than inert, since a saver selected in both
        // slots makes macOS run two copies of it. Hide it rather than leave switches that
        // do nothing.
        guard !SystemScreenSaver.isDesktopWallpaper else {
            let settings = NSMenuItem(title: "Open Wallpaper Settings…", action: #selector(openScreenSaverSettings), keyEquivalent: "")
            settings.target = self
            menu.addItem(settings)
            return menu
        }

        menu.addItem(.separator())

        let installed = ScreenSaverInstaller.isInstalled
        let selected = SystemScreenSaver.isSelected
        menu.addItem(infoItem(installed ? "Screen saver: installed" : "Screen saver: not installed"))
        menu.addItem(infoItem(selected ? "Selected in macOS: yes" : "Selected in macOS: NO — pick it below"))

        if !installed || !selected {
            let enable = NSMenuItem(title: "Enable W4llsky Screen Saver", action: #selector(enableScreenSaverFromMenu), keyEquivalent: "")
            enable.target = self
            menu.addItem(enable)
        } else {
            let reinstall = NSMenuItem(title: "Reinstall Screen Saver", action: #selector(installScreenSaver), keyEquivalent: "")
            reinstall.target = self
            menu.addItem(reinstall)
        }

        // Only the *unlocked* idle timeout: LockStartTrigger shortens it to a couple
        // of seconds for as long as the screen is actually locked.
        menu.addItem(submenuItem(title: "Starts After (When Unlocked)", submenu: buildIdleDelayMenu()))

        // ⌃⌘Q normally locks straight to the static lock screen; claiming it starts
        // the video instead, which locks behind itself.
        let hotKey = NSMenuItem(title: "⌃⌘Q Plays the Video", action: #selector(toggleLockHotKey), keyEquivalent: "")
        hotKey.target = self
        hotKey.state = store.configuration.usesLockHotKey ? .on : .off
        menu.addItem(hotKey)

        menu.addItem(submenuItem(title: "Hot Corner Plays the Video", submenu: buildHotCornerMenu()))

        let test = NSMenuItem(title: "Play Now (locks the Mac)", action: #selector(testScreenSaver), keyEquivalent: "")
        test.target = self
        menu.addItem(test)

        let settings = NSMenuItem(title: "Open Wallpaper Settings…", action: #selector(openScreenSaverSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        return menu
    }

    /// True when no connected display plays the same file the system wallpaper does, so
    /// W4llsky's own window is covering it and macOS has stopped it.
    private var differsFromDesktopVideo: Bool {
        let assigned = displayObserver.current.compactMap { store.configuration.assignments[$0.id] }
        guard !assigned.isEmpty else { return false }
        return !assigned.contains { assignment in
            SecurityScopedBookmark.resolve(assignment.bookmarkData).map(LockScreenLibrary.isSameFile(as:)) ?? false
        }
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
        guard let bookmark = SecurityScopedBookmark.makeBookmark(for: url) else {
            report("W4llsky couldn't keep a reference to that file.")
            return
        }

        let fillMode = store.configuration.assignments[displayID]?.fillMode ?? .fill
        store.configuration.assignments[displayID] = WallpaperAssignment(
            bookmarkData: bookmark,
            videoName: url.lastPathComponent,
            fillMode: fillMode
        )
        store.save()
        engine.assign(
            bookmark: bookmark,
            rate: store.configuration.playbackRate,
            fillMode: fillMode,
            to: screen,
            displayID: displayID
        )
    }

    @objc private func removeVideo(_ sender: NSMenuItem) {
        guard let displayID = sender.representedObject as? String else { return }
        store.configuration.assignments[displayID] = nil
        store.save()
        engine.remove(displayID: displayID)
    }

    @objc private func setFillMode(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ScalingChoice else { return }

        if let displayID = choice.displayID {
            store.configuration.assignments[displayID]?.fillMode = choice.mode
            store.save()
            engine.setFillMode(choice.mode, displayID: displayID)
            // An assigned display with no window of ours is one macOS is drawing itself,
            // from the same file — so the pixels come from the saver, and the mode has to
            // reach LockScreenLibrary or the menu changes nothing anyone can see.
            guard !engine.hasWindow(for: displayID) else { return }
        }

        guard var config = LockScreenLibrary.load() else { return }
        config.fillMode = choice.mode
        do { try LockScreenLibrary.save(config) } catch { report(error.localizedDescription) }
    }

    @objc private func setSpeed(_ sender: NSMenuItem) {
        guard let speed = sender.representedObject as? Float else { return }
        store.configuration.playbackRate = speed
        store.save()
        engine.setRate(speed)

        if var lock = LockScreenLibrary.load() {
            lock.rate = speed
            try? LockScreenLibrary.save(lock)
        }
    }

    @objc private func chooseLockScreenVideo() {
        guard let url = pickVideoURL(message: "Choose a video for the Lock Screen saver") else { return }

        let fillMode = LockScreenLibrary.load()?.fillMode ?? .fill
        do {
            try LockScreenLibrary.install(video: url, rate: store.configuration.playbackRate, fillMode: fillMode)
            try enableScreenSaver()
        } catch {
            report("Couldn't set that video for the lock screen.", detail: error.localizedDescription)
            return
        }

        onLockSetupChanged?()
        offerTest(
            "Lock screen video set.",
            detail: "macOS only shows a screen saver on a lock that the saver itself started, so use ⌃⌘Q or the hot corner below — locking any other way gets the static lock screen, and no setting changes that."
        )
    }

    @objc private func removeLockScreenVideo() {
        LockScreenLibrary.clear()
    }

    /// The one step macOS keeps for itself: there is no API to select a screen saver,
    /// so say exactly where the switch is instead of pretending it happened.
    @objc private func showHowToSelect() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "One step left: pick W4llsky as your screen saver."
        alert.informativeText = """
        macOS only plays the screen saver you select yourself, and macOS 26 removed the         Screen Saver pane — it now lives inside Wallpaper settings.

        Open Wallpaper settings, scroll down to Screen Saver, and pick W4llsky in the         Other section (below macOS's own screen savers).
        """
        alert.addButton(withTitle: "Open Wallpaper Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            SystemScreenSaver.openSettings()
        }
    }

    @objc private func testScreenSaver() {
        SystemScreenSaver.startNow()
    }

    @objc private func toggleLockHotKey() {
        store.configuration.lockHotKey = !store.configuration.usesLockHotKey
        store.save()
        onLockSetupChanged?()
    }

    @objc private func setHotCorner(_ sender: NSMenuItem) {
        LockHotCorner.use(sender.representedObject as? LockHotCorner.Corner)
    }

    @objc private func toggleDesktopWallpaper() {
        let enable = !SystemScreenSaver.isDesktopWallpaper
        do {
            // Only *installed*, deliberately not selected as the screen saver: being
            // chosen in both slots is what makes macOS run two copies of the video.
            if enable, !ScreenSaverInstaller.isInstalled { try ScreenSaverInstaller.install() }
            try SystemScreenSaver.useAsDesktopWallpaper(enable, bundlePath: ScreenSaverInstaller.installedURL)
        } catch {
            report(enable ? "Couldn't put the video on the lock screen."
                          : "Couldn't restore your wallpaper.",
                   detail: error.localizedDescription)
        }
        onLockSetupChanged?()
    }

    @objc private func setIdleDelay(_ sender: NSMenuItem) {
        guard let seconds = sender.representedObject as? Int else { return }
        SystemScreenSaver.idleDelay = seconds
    }

    @objc private func enableScreenSaverFromMenu() {
        do {
            try enableScreenSaver()
        } catch {
            report("Couldn't enable the W4llsky screen saver.", detail: error.localizedDescription)
            showHowToSelect()
            return
        }
        offerTest(
            "W4llsky is now your screen saver.",
            detail: "macOS only shows a screen saver on a lock that the saver itself started, so use ⌃⌘Q or the hot corner below — locking any other way gets the static lock screen, and no setting changes that."
        )
    }

    /// Installing the .saver only lists it — macOS still runs whatever is *selected*.
    private func enableScreenSaver() throws {
        if !ScreenSaverInstaller.isInstalled {
            try ScreenSaverInstaller.install()
        }
        if !SystemScreenSaver.isSelected {
            try SystemScreenSaver.select(bundlePath: ScreenSaverInstaller.installedURL)
        }
    }

    @objc private func installScreenSaver() {
        do {
            try ScreenSaverInstaller.install()
        } catch {
            report("Couldn't install the screen saver.", detail: error.localizedDescription)
            return
        }
        report("W4llsky screen saver reinstalled.", style: .informational)
    }

    @objc private func openScreenSaverSettings() {
        SystemScreenSaver.openSettings()
    }

    @objc private func togglePause() {
        isPaused.toggle()
        engine.setPaused(isPaused, resumeRate: store.configuration.playbackRate)
    }

    @objc private func toggleLaunchAtLogin() {
        LaunchAtLogin.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openAboutWindow() {
        NSApp.activate(ignoringOtherApps: true)

        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let content = NSHostingView(rootView: ContentView())
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: content.fittingSize),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "About W4llsky"
        window.contentView = content
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

    private func report(_ message: String, detail: String = "", style: NSAlert.Style = .warning) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    /// Seeing it run is the only real confirmation, so always offer it.
    private func offerTest(_ message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: "Test Now")
        alert.addButton(withTitle: "Done")
        if alert.runModal() == .alertFirstButtonReturn {
            SystemScreenSaver.startNow()
        }
    }
}
