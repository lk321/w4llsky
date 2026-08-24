//
//  ScreenSaverInstaller.swift
//  W4llsky
//
//  Copies the W4llsky.saver bundle out of the app's PlugIns folder into
//  ~/Library/Screen Savers, where System Settings looks for it. Nothing else
//  can install a screen saver on the user's behalf.
//

import Foundation

enum ScreenSaverInstaller {
    static let bundleName = "W4llsky.saver"

    static var bundledURL: URL? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(bundleName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    static var installedURL: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return library.appendingPathComponent("Screen Savers/\(bundleName)")
    }

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: installedURL.path)
    }

    /// The installed bundle is a *copy*, so a new build of the app ships saver code that
    /// nothing would otherwise pick up — the lock screen would keep running whatever was
    /// copied out months ago. Info.plist rather than the executable: it is always there
    /// under a fixed name, and `copyItem` preserves its mtime.
    static func installIfOutdated() {
        guard isInstalled, let source = bundledURL,
              let ours = modified(source), let installed = modified(installedURL),
              ours > installed else { return }
        try? install()
    }

    private static func modified(_ bundle: URL) -> Date? {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        return try? plist.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func install() throws {
        guard let source = bundledURL else {
            throw error("The screen saver plug-in is missing from this build of W4llsky.")
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: installedURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: installedURL.path) {
            try fileManager.removeItem(at: installedURL)
        }
        try fileManager.copyItem(at: source, to: installedURL)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.personal.W4llsky", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
