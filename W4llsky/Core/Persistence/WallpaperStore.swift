//
//  WallpaperStore.swift
//  W4llsky
//
//  Lightweight Codable config in UserDefaults — no database needed for this size of data.
//

import Foundation

enum FillMode: String, Codable {
    case fill, fit
}

struct WallpaperAssignment: Codable, Equatable {
    var bookmarkData: Data
    var videoName: String
    var fillMode: FillMode = .fill
}

struct WallpaperConfiguration: Codable {
    var assignments: [String: WallpaperAssignment] = [:] // keyed by DisplaySnapshot.id
    var lockScreen: WallpaperAssignment?
    var playbackRate: Float = 1.0
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
