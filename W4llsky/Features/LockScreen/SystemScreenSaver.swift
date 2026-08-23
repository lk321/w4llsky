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

    /// True only when every screen-saver slot points at a legacy saver whose
    /// configuration names W4llsky. Reading the blob as bytes rather than
    /// decoding it keeps this working whatever shape Apple encodes it in.
    static var isSelected: Bool {
        guard let store = loadStore() else { return false }
        let choices = idleChoices(in: store)
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
        // Not `URL(fileURLWithPath:)`: a .saver is a directory, so that would append a
        // trailing slash and no longer match what System Settings writes.
        let module = ["relative": URL(fileURLWithPath: bundlePath.path, isDirectory: false).absoluteString]
        let configuration = try PropertyListSerialization.data(
            fromPropertyList: ["module": module],
            format: .binary,
            options: 0
        )
        let choice: [String: Any] = ["Provider": choiceProvider, "Configuration": configuration, "Files": []]

        let updated = replacingIdleChoices(in: store, with: choice)
        let data = try PropertyListSerialization.data(fromPropertyList: updated, format: .binary, options: 0)
        try data.write(to: storeURL, options: .atomic)

        // Order matters: WallpaperAgent keeps the store in memory and flushes it back
        // on its own schedule, so killing it *after* the write is what makes the change
        // stick — kill it first and the copy it reloads in the meantime overwrites us.
        // It relaunches on demand and reads the file we just wrote.
        stopAgent()

        guard isSelected else {
            throw failure("macOS didn't accept the change. Pick W4llsky yourself in Wallpaper settings.")
        }
    }

    static func replacingIdleChoices(in node: [String: Any], with choice: [String: Any]) -> [String: Any] {
        var result = node
        for (key, value) in node {
            guard let child = value as? [String: Any] else { continue }
            if key == "Idle", let content = child["Content"] as? [String: Any] {
                var idle = child
                var updated = content
                updated["Choices"] = [choice]
                idle["Content"] = updated
                idle["LastSet"] = Date()
                result[key] = idle
            } else {
                result[key] = replacingIdleChoices(in: child, with: choice)
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

    /// How long the Mac must sit idle — locked or not — before macOS starts the
    /// screen saver. Locking does *not* start it: loginwindow reschedules this timer
    /// instead ("reset after screen lock, do not launch screen saver … scheduling
    /// idle timer in 1200.0s"), and it refuses an external start once the screen is
    /// already locked, so this delay is the whole answer to "how soon after I lock".
    /// macOS 26 still reads the pre-14 per-host preference; the daemon re-reads it on
    /// every check, so no restart is needed.
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
    /// behind it, which is the whole trick: locking first would rule the saver out.
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
        guard let login = dlopen("/System/Library/PrivateFrameworks/login.framework/login", RTLD_LAZY),
              let symbol = dlsym(login, "SACScreenSaverStartNow") else { return false }
        typealias StartNow = @convention(c) () -> Int32
        return unsafeBitCast(symbol, to: StartNow.self)() == 0
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

    /// Every "Idle" node in the tree, at any depth: the global one, one per
    /// display, and one per Space. A saver picked for only some of them isn't
    /// really selected.
    static func idleChoices(in node: [String: Any]) -> [[String: Any]] {
        var found: [[String: Any]] = []
        for (key, value) in node {
            guard let child = value as? [String: Any] else { continue }
            if key == "Idle" {
                found += (child["Content"] as? [String: Any])?["Choices"] as? [[String: Any]] ?? []
            } else {
                found += idleChoices(in: child)
            }
        }
        return found
    }
}
