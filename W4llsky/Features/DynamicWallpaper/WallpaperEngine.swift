//
//  WallpaperEngine.swift
//  W4llsky
//
//  Owns one desktop window + player per display id. AppDelegate reconciles
//  this against DisplayObserver on every screen-parameters change; the engine
//  itself just does create/remove/reposition for whatever ids it's told about.
//

import AppKit

final class WallpaperEngine {
    private var windows: [String: DesktopWindow] = [:]
    private var players: [String: WallpaperPlayer] = [:]
    private var isPaused = false

    func hasWindow(for displayID: String) -> Bool {
        windows[displayID] != nil
    }

    func assign(bookmark: Data, rate: Float, fillMode: FillMode, to screen: NSScreen, displayID: String) {
        remove(displayID: displayID)
        guard let url = SecurityScopedBookmark.resolve(bookmark) else { return }

        let window = DesktopWindow(screen: screen)
        let player = WallpaperPlayer(url: url, fillMode: fillMode)
        window.contentView = player.view
        window.orderFront(nil)
        player.updatePresentation() // the view now has the screen's size
        player.setRate(isPaused ? 0 : rate)

        windows[displayID] = window
        players[displayID] = player
    }

    func remove(displayID: String) {
        players[displayID] = nil // deinit stops playback
        windows[displayID]?.orderOut(nil)
        windows[displayID] = nil
    }

    func removeAllForMissingDisplays(currentIDs: Set<String>) {
        for id in windows.keys where !currentIDs.contains(id) {
            remove(displayID: id)
        }
    }

    /// Also re-decides fill vs. letterbox: a resolution change can flip the answer.
    func reposition(displayID: String, screen: NSScreen) {
        guard let window = windows[displayID] else { return }
        window.setFrame(screen.frame, display: true)
        players[displayID]?.updatePresentation()
    }

    func setFillMode(_ mode: FillMode, displayID: String) {
        players[displayID]?.setFillMode(mode)
    }

    /// Waking from display or system sleep leaves the video layers detached.
    func handleWake() {
        for (id, player) in players {
            player.reattachAfterWake()
            windows[id]?.orderFront(nil)
        }
    }

    func setRate(_ rate: Float) {
        guard !isPaused else { return }
        players.values.forEach { $0.setRate(rate) }
    }

    func setPaused(_ paused: Bool, resumeRate: Float) {
        isPaused = paused
        players.values.forEach { $0.setRate(paused ? 0 : resumeRate) }
    }
}
