//
//  LockScreenLibrary.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  The lock screen video lives at a fixed path both processes can reach:
//    ~/Library/Application Support/W4llsky/LockScreen.mp4  (+ LockScreen.json)
//
//  Why a copy instead of the original path or a bookmark:
//  the legacy screen saver host runs sandboxed. It holds a read-only exception
//  for the whole filesystem, but TCC still blocks Desktop/Documents/Downloads,
//  and app-scoped bookmarks can't be handed to another process. A hard link
//  (falling back to a copy across volumes) into our own, unprotected folder is
//  readable in every case and costs no extra disk when it links.
//
//  NSHomeDirectory() would resolve to the saver's sandbox container, so the real
//  home directory is read from the passwd entry — that is identical in both
//  processes.
//

import Darwin
import Foundation

struct LockScreenConfig: Codable {
    var videoName: String
    var rate: Float
    var fillMode: FillMode
}

enum LockScreenLibrary {
    /// The saver reads this config once, when *WallpaperAgent* decides to build its
    /// view — which can be hours ago. Without a nudge, changing the scaling or the
    /// speed writes a file nobody re-reads and nothing moves on screen. Every writer
    /// below posts it, so there is one path and no way to forget it.
    static let changedNotification = Notification.Name("com.personal.W4llsky.lockScreenConfigChanged")

    static var folder: URL {
        realHome.appendingPathComponent("Library/Application Support/W4llsky", isDirectory: true)
    }

    static var videoURL: URL { folder.appendingPathComponent("LockScreen.mp4") }
    static var configURL: URL { folder.appendingPathComponent("LockScreen.json") }

    static var hasVideo: Bool {
        FileManager.default.fileExists(atPath: videoURL.path)
    }

    /// True when `url` is the very file the system wallpaper is playing. `install`
    /// hard-links the source, so the two are one file on disk whenever they share a
    /// volume — comparing paths would miss that, since the whole point of this folder
    /// is that the video is *not* at its original path any more.
    static func isSameFile(as url: URL) -> Bool {
        guard let mine = try? videoURL.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let theirs = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return false }
        return mine.isEqual(theirs)
    }

    static func load() -> LockScreenConfig? {
        guard hasVideo,
              let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(LockScreenConfig.self, from: data) else { return nil }
        return config
    }

    static func save(_ config: LockScreenConfig) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(config).write(to: configURL, options: .atomic)
        postChanged()
    }

    static func install(video source: URL, rate: Float, fillMode: FillMode) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: videoURL.path) {
            try fileManager.removeItem(at: videoURL)
        }
        do {
            try fileManager.linkItem(at: source, to: videoURL)
        } catch {
            try fileManager.copyItem(at: source, to: videoURL)
        }
        try save(LockScreenConfig(videoName: source.lastPathComponent, rate: rate, fillMode: fillMode))
    }

    static func clear() {
        try? FileManager.default.removeItem(at: videoURL)
        try? FileManager.default.removeItem(at: configURL)
        postChanged()
    }

    // MARK: - Desktop handoff

    /// W4llsky draws every display itself while the video is the system wallpaper (the
    /// system copy barely moves on the desktop), so the saver underneath decodes for
    /// nobody. This file exists exactly while that is true and the Mac is unlocked. The
    /// saver pauses at rate 0 while it exists, keeping its decoder warm for the lock screen.
    /// A file rather than only a notification: WallpaperAgent builds saver views
    /// whenever it likes, and a new view has to know the state without waiting for news.
    /// ponytail: a crash leaves the file behind. The desktop copy then stays paused until
    /// W4llsky relaunches; the lock screen still plays, since the saver overrides on lock.
    static let coverChangedNotification = Notification.Name("com.personal.W4llsky.desktopCoverChanged")
    static var coverURL: URL { folder.appendingPathComponent("DesktopCovered") }

    static var isDesktopCovered: Bool {
        FileManager.default.fileExists(atPath: coverURL.path)
    }

    static func setDesktopCovered(_ covered: Bool) {
        setFlag(coverURL, covered)
    }

    /// Exists while W4llsky is saving battery: the saver swaps its video for a still frame
    /// and frees the decoder, like W4llsky's own windows. The app decides because the
    /// battery is read through IOKit, which the sandboxed saver host may not reach. Same
    /// notification as the cover, and the same crash caveat.
    static var powerSavingURL: URL { folder.appendingPathComponent("PowerSaving") }

    static var isPowerSaving: Bool {
        FileManager.default.fileExists(atPath: powerSavingURL.path)
    }

    static func setPowerSaving(_ saving: Bool) {
        setFlag(powerSavingURL, saving)
    }

    /// Compares against the file, not a cached flag, so it is right after a crash too.
    private static func setFlag(_ url: URL, _ on: Bool) {
        guard on != FileManager.default.fileExists(atPath: url.path) else { return }
        if on {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { return }
        } else {
            try? FileManager.default.removeItem(at: url)
        }
        DistributedNotificationCenter.default().postNotificationName(
            coverChangedNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    /// Where the desktop's copy of the lock screen video was when the Mac locked. The lock
    /// screen continues from there instead of from wherever the paused saver stopped.
    /// Both processes read the same host clock, so "now" means the same thing on both sides.
    struct Playhead: Codable {
        var position: Double
        var hostTime: Double
        var rate: Float

        func position(at now: Double) -> Double {
            position + (now - hostTime) * Double(rate)
        }
    }

    static var playheadURL: URL { folder.appendingPathComponent("Playhead.json") }

    static func savePlayhead(_ playhead: Playhead) {
        try? JSONEncoder().encode(playhead).write(to: playheadURL, options: .atomic)
    }

    static func loadPlayhead() -> Playhead? {
        guard let data = try? Data(contentsOf: playheadURL) else { return nil }
        return try? JSONDecoder().decode(Playhead.self, from: data)
    }

    /// Distributed, because the reader is another process (the sandboxed saver host).
    private static func postChanged() {
        DistributedNotificationCenter.default().postNotificationName(
            changedNotification, object: nil, userInfo: nil, deliverImmediately: true
        )
    }

    private static var realHome: URL {
        if let home = getpwuid(getuid())?.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
