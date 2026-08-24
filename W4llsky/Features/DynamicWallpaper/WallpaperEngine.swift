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
    private var rate: Float = 1
    private var occlusionToken: NSObjectProtocol?

    /// A wallpaper nobody can see is still a whole decode pipeline. Ours sits at the
    /// very bottom of the window stack, so anything the user opens covers it — which
    /// is most of the time — and macOS tells us the moment that changes. Stopping the
    /// player then is the single biggest thing this app does for battery, and it costs
    /// no timer: this is a notification, and playback resumes where it left off.
    init() {
        occlusionToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let window = notification.object as? DesktopWindow,
                      let id = self.windows.first(where: { $0.value === window })?.key else { return }
                self.players[id]?.setRate(self.rate(for: id))
            }
        }
    }

    deinit {
        if let occlusionToken { NotificationCenter.default.removeObserver(occlusionToken) }
    }

    func hasWindow(for displayID: String) -> Bool {
        windows[displayID] != nil
    }

    private func rate(for displayID: String) -> Float {
        guard !isPaused, windows[displayID]?.occlusionState.contains(.visible) == true else { return 0 }
        return rate
    }

    func assign(bookmark: Data, rate: Float, fillMode: FillMode, to screen: NSScreen, displayID: String) {
        self.rate = rate
        remove(displayID: displayID)
        guard let url = SecurityScopedBookmark.resolve(bookmark) else { return }

        let window = DesktopWindow(screen: screen)
        let player = WallpaperPlayer(url: url, fillMode: fillMode)
        window.contentView = player.view
        window.orderFront(nil)
        player.updatePresentation() // the view now has the screen's size
        // Deliberately not gated on occlusion: a window ordered in this instant hasn't
        // been given an occlusion state yet, and reading it here would leave the
        // wallpaper stopped until something else moved. The notification takes over.
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
        players[displayID]?.setRate(rate(for: displayID))
    }

    func setFillMode(_ mode: FillMode, displayID: String) {
        players[displayID]?.setFillMode(mode)
    }

    /// Waking from display or system sleep leaves the video layers detached.
    func handleWake() {
        for (id, player) in players {
            player.reattach()
            windows[id]?.orderFront(nil)
            // Re-derive rather than restore: the occluding window may well have gone
            // away while the display slept, and a stopped wallpaper must never be able
            // to stay stopped just because nothing else moved afterwards.
            player.setRate(rate(for: id))
        }
    }

    func setRate(_ newRate: Float) {
        rate = newRate
        guard !isPaused else { return }
        applyRates()
    }

    func setPaused(_ paused: Bool, resumeRate: Float) {
        isPaused = paused
        rate = resumeRate
        applyRates()
    }

    private func applyRates() {
        for (id, player) in players { player.setRate(rate(for: id)) }
    }
}
