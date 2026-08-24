//
//  SystemScreenSaver.swift
//  W4llsky
//
//  Installing a .saver only puts it in the list. macOS runs whatever is
//  *selected*, and an installed-but-unselected saver does nothing at all —
//  that was the whole "lock screen doesn't work" bug.
//
//  There is no API to make the selection. Since macOS 14 it lives in
//  WallpaperAgent's own store:
//    ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist
//  The choice's `Configuration` is a binary plist holding a *URL wrapper* around
//  the .saver bundle — `{"module": {"relative": "file:///…/W4llsky.saver"}}` —
//  copied verbatim from what System Settings itself writes. Reconstructions from
//  `ScreenSaverModule.dictionaryRepresentation` (moduleName/path/type) are all
//  rejected and make macOS fall back to its default saver, so don't "improve"
//  this shape without checking a selection made through the UI first.
//

import AppKit

enum SystemScreenSaver {
    static let choiceProvider = "com.apple.wallpaper.choice.screen-saver"
    static let idleSlot = "Idle"
    static let desktopSlot = "Desktop"

    /// True only when every screen-saver slot points at a legacy saver whose
    /// configuration names W4llsky. Reading the blob as bytes rather than
    /// decoding it keeps this working whatever shape Apple encodes it in.
    static var isSelected: Bool {
        guard let store = loadStore() else { return false }
        let choices = choices(in: store, slot: idleSlot)
        guard !choices.isEmpty else { return false }
        return choices.allSatisfy { choice in
            choice["Provider"] as? String == choiceProvider && mentionsW4llsky(choice)
        }
    }

    /// Points every screen-saver slot at our bundle, then re-reads the file to
    /// confirm — writing this is only worth doing if it took.
    static func select(bundlePath: URL) throws {
        guard let store = loadStore() else {
            throw failure("W4llsky couldn't read the system's screen saver settings.")
        }
        try write(replacingChoices(in: store, slot: idleSlot, with: saverChoice(bundlePath: bundlePath)))

        guard isSelected else {
            throw failure("macOS didn't accept the change. Pick W4llsky yourself in Wallpaper settings.")
        }
    }

    /// `slot` is "Idle" for the screen saver and "Desktop" for the wallpaper — the
    /// store nests both, once globally and again per Space and per display.
    /// Not `URL(fileURLWithPath:)`: a .saver is a directory, so that would append a
    /// trailing slash and no longer match what System Settings writes.
    private static func saverChoice(bundlePath: URL) -> [String: Any] {
        let module = ["relative": URL(fileURLWithPath: bundlePath.path, isDirectory: false).absoluteString]
        let configuration = (try? PropertyListSerialization.data(
            fromPropertyList: ["module": module], format: .binary, options: 0
        )) ?? Data()
        return ["Provider": choiceProvider, "Configuration": configuration, "Files": []]
    }

    private static func write(_ store: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: store, format: .binary, options: 0)
        try data.write(to: storeURL, options: .atomic)

        // Order matters: WallpaperAgent keeps the store in memory and flushes it back
        // on its own schedule, so killing it *after* the write is what makes the change
        // stick — kill it first and the copy it reloads in the meantime overwrites us.
        // It relaunches on demand and reads the file we just wrote.
        stopAgent()
    }

    /// A nil `choice` empties the slot, which is how we hand it back to macOS.
    static func replacingChoices(in node: [String: Any], slot: String, with choice: [String: Any]?) -> [String: Any] {
        var result = node
        for (key, value) in node {
            guard let child = value as? [String: Any] else { continue }
            if key == slot, let content = child["Content"] as? [String: Any] {
                var idle = child
                var updated = content
                updated["Choices"] = choice.map { [$0] } ?? []
                // A wallpaper slot carries options for the provider it used to hold;
                // leaving them behind makes WallpaperAgent decode them for the new one.
                updated["EncodedOptionValues"] = "$null"
                idle["Content"] = updated
                idle["LastSet"] = Date()
                result[key] = idle
            } else {
                result[key] = replacingChoices(in: child, slot: slot, with: choice)
            }
        }
        return result
    }

    /// SIGKILL on purpose (`forceTerminate`): a clean exit would give the agent the
    /// chance to write its cached store back over the file we just wrote.
    private static func stopAgent() {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.wallpaper.agent")
            .forEach { $0.forceTerminate() }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "com.personal.W4llsky", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// macOS 26 has no Screen Saver pane any more — screen savers moved into
    /// Wallpaper settings, so the old pane id silently opened General instead.
    /// `?screenSaver` is the anchor that pane's own App Intents declare.
    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension?screenSaver") else { return }
        NSWorkspace.shared.open(url)
    }

    /// How long the Mac must sit idle before macOS starts the screen saver. macOS 26
    /// still reads the pre-14 per-host preference, and `ScreenSaverDaemon` re-reads it
    /// on every check, so no restart is needed — but it only *checks* on its own
    /// timer. It only ever governs an *unlocked* idle Mac — see the note on
    /// `startNow()` for why nothing can start the saver after a manual lock.
    static var idleDelay: Int {
        get {
            let value = CFPreferencesCopyValue(
                "idleTime" as CFString, "com.apple.screensaver" as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            ) as? Int
            return value ?? 1200
        }
        set {
            CFPreferencesSetValue(
                "idleTime" as CFString, newValue as CFNumber, "com.apple.screensaver" as CFString,
                kCFPreferencesCurrentUser, kCFPreferencesCurrentHost
            )
            CFPreferencesSynchronize("com.apple.screensaver" as CFString, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost)
        }
    }

    /// Runs the selected screen saver right now. Starting it also locks the screen
    /// behind it, and that order is not a convenience — it is the only order that
    /// works. `LWScreenLock` records *why* the screen locked in `_lockReqestedBy`,
    /// and that is what decides whether the shield shows a saver or the static lock
    /// screen. A lock the user asked for directly is `kLWLockFromDirectLock` (8),
    /// which outranks every `kLWLockFromScreenSaver…` value and cannot be lowered
    /// ("requestedby:4 < _lockReqestedBy:8 so don't do anything"). Once it is 8:
    ///   - the idle timer refuses outright — "lockRequestedBy: 8 > screensaver, so do
    ///     not launch screen saver" — so shortening `idleDelay` changes nothing;
    ///   - `SACScreenSaverStartNow` is *accepted* and runs the identical daemon
    ///     sequence as a working idle launch, but no saver is ever drawn, and the
    ///     daemon is left reporting `screenSaverIsRunning = 1` forever, which then
    ///     no-ops the next real launch. Do not call it on `com.apple.screenIsLocked`.
    /// So the video can only be started *before* the lock, by us — which is what the
    /// ⌃⌘Q hot key and a "Start Screen Saver" hot corner both do.
    ///
    /// ScreenSaverEngine.app only forwards this same call to loginwindow, and
    /// launching an app costs a few hundred milliseconds we don't have when racing
    /// the system's own ⌃⌘Q — so ask loginwindow directly and keep the app launch
    /// as the fallback.
    static func startNow() {
        if startViaLoginWindow() { return }
        let engine = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: engine, configuration: NSWorkspace.OpenConfiguration())
    }

    private static func startViaLoginWindow() -> Bool {
        guard let symbol = loginSymbol("SACScreenSaverStartNow") else { return false }
        typealias StartNow = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: StartNow.self)() == 0
    }

    private static let loginFramework = dlopen(
        "/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY
    )

    private static func loginSymbol(_ name: String) -> UnsafeMutableRawPointer? {
        loginFramework.flatMap { dlsym($0, name) }
    }

    // MARK: - The saver as the desktop wallpaper (what puts it on the lock screen)

    /// macOS 26 does not draw the lock screen itself: the moment loginwindow locks it
    /// takes a WallpaperAgent assertion with `contentType: desktop`, so what you see
    /// behind the password field is the **desktop wallpaper**. A screen saver selected
    /// as the wallpaper — the same arrangement as Apple's own aerials — therefore plays
    /// on the lock screen with none of the screen-saver machinery involved: no hot key,
    /// no idle timer, and none of the `_lockReqestedBy` gating described on `startNow()`.
    /// This is the only route that survives locking the Mac any way you like.
    static var isDesktopWallpaper: Bool {
        guard let store = loadStore() else { return false }
        let desktop = choices(in: store, slot: desktopSlot)
        guard !desktop.isEmpty else { return false }
        return desktop.allSatisfy { $0["Provider"] as? String == choiceProvider && mentionsW4llsky($0) }
    }

    /// Holds whatever wallpaper the user had, so turning this back off restores it
    /// rather than leaving them on a default picture.
    private static let previousWallpaperKey = "com.personal.W4llsky.previousWallpaperChoice"

    static func useAsDesktopWallpaper(_ enabled: Bool, bundlePath: URL) throws {
        guard let store = loadStore() else {
            throw failure("W4llsky couldn't read the system's wallpaper settings.")
        }
        let choice: [String: Any]
        if enabled {
            if !isDesktopWallpaper, let previous = choices(in: store, slot: desktopSlot).first {
                UserDefaults.standard.set(
                    try PropertyListSerialization.data(fromPropertyList: previous, format: .binary, options: 0),
                    forKey: previousWallpaperKey
                )
            }
            choice = saverChoice(bundlePath: bundlePath)
        } else {
            guard let data = UserDefaults.standard.data(forKey: previousWallpaperKey),
                  let previous = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
                throw failure("W4llsky doesn't know which wallpaper to put back. Pick one in Wallpaper settings.")
            }
            choice = previous
        }

        var updated = replacingChoices(in: store, slot: desktopSlot, with: choice)
        updated = replacingChoices(in: updated, slot: idleSlot,
                                   with: enabled ? nil : saverChoice(bundlePath: bundlePath))
        try write(updated)

        guard isDesktopWallpaper == enabled else {
            throw failure("macOS didn't accept the change.")
        }
        if !enabled { UserDefaults.standard.removeObject(forKey: previousWallpaperKey) }
    }

    /// One choice, one slot.
    ///
    /// WallpaperAgent builds a live wallpaper for *every* slot our saver is chosen for and
    /// animates all of them — two identical 4K decode pipelines here, only one of which is
    /// ever on screen. They cannot be told apart from inside the saver: same window class
    /// (`NSServiceViewControllerWindow`), same frame, same alpha, same occlusion state,
    /// and `stopAnimation()` is never called on the spare. So the duplicate has to be
    /// prevented rather than detected, and the screen-saver slot is the one to give up:
    /// with the video set as the wallpaper the lock screen already draws it, whatever
    /// starts the lock.
    ///
    /// Called at launch as well, because the two settings are written at different times
    /// and only this pairing is a state the app should ever leave behind.
    static func removeRedundantScreenSaverSelection() {
        guard isDesktopWallpaper, isSelected, let store = loadStore() else { return }
        try? write(replacingChoices(in: store, slot: idleSlot, with: nil))
    }

    // MARK: - Store reading

    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.apple.wallpaper/Store/Index.plist")
    }

    private static func loadStore() -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        return plist as? [String: Any]
    }

    private static func mentionsW4llsky(_ choice: [String: Any]) -> Bool {
        if let configuration = choice["Configuration"] as? Data,
           String(decoding: configuration, as: UTF8.self).contains("W4llsky") {
            return true
        }
        let files = choice["Files"] as? [String] ?? []
        return files.contains { $0.contains("W4llsky") }
    }

    /// Every node of one kind in the tree, at any depth: the global one, one per
    /// display, and one per Space. A saver picked for only some of them isn't
    /// really selected.
    static func choices(in node: [String: Any], slot: String) -> [[String: Any]] {
        var found: [[String: Any]] = []
        for (key, value) in node {
            guard let child = value as? [String: Any] else { continue }
            if key == slot {
                found += (child["Content"] as? [String: Any])?["Choices"] as? [[String: Any]] ?? []
            } else {
                found += choices(in: child, slot: slot)
            }
        }
        return found
    }
}
