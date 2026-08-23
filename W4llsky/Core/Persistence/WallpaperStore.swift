//
//  WallpaperStore.swift
//  W4llsky
//
//  Lightweight Codable config in UserDefaults — no database needed for this size of data.
//  The lock screen video is not stored here: it lives in LockScreenLibrary, the
//  one place the sandboxed screen saver can also read.
//

import Foundation

struct WallpaperAssignment: Codable, Equatable {
    var bookmarkData: Data
    var videoName: String
    var fillMode: FillMode = .auto
}

struct WallpaperConfiguration: Codable {
    var assignments: [String: WallpaperAssignment] = [:] // keyed by DisplaySnapshot.id
    var playbackRate: Float = 1.0
    /// Optional so older stored configurations still decode — the synthesized
    /// decoder ignores property defaults but tolerates a missing optional.
    var lockHotKey: Bool?

    var usesLockHotKey: Bool { lockHotKey ?? true }
}

final class WallpaperStore {
    private let defaultsKey = "com.personal.W4llsky.configuration"

    var configuration: WallpaperConfiguration

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(WallpaperConfiguration.self, from: data) {
            configuration = decoded
        } else {
            configuration = WallpaperConfiguration()
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
