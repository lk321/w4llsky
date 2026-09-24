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
    /// Set while the displays are asleep or the screen is locked. Occlusion can't see
    /// either one: nothing covers our window, so AppKit still calls it visible while
    /// the shield (or a sleeping display) has taken the surface out from under the
    /// AVPlayerLayer. The player never notices and keeps decoding at full rate into
    /// nothing — CoreMedia reports "enqueued: 12, displayed: 0" — once per display,
    /// for as long as the Mac stays locked. Pure waste, and it scales with monitor
    /// count; it is idle cost only, so it buys nothing back while the Mac is in use.
    private var isSuspended = false
    /// Set while the Mac is short of memory or running hot (`SystemPressure.throttle`).
    private var isThrottled = false
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

    /// Every reason a wallpaper must not be decoding, in one place. Pure so the
    /// combinations can be checked without a display attached.
    static func rate(_ rate: Float, paused: Bool, suspended: Bool, throttled: Bool, visible: Bool) -> Float {
        paused || suspended || throttled || !visible ? 0 : rate
    }

    private func rate(for displayID: String) -> Float {
        Self.rate(
            rate,
            paused: isPaused,
            suspended: isSuspended,
            throttled: isThrottled,
            visible: windows[displayID]?.occlusionState.contains(.visible) == true
        )
    }

    func assign(bookmark: Data, rate: Float, fillMode: FillMode, to screen: NSScreen, displayID: String) {
        guard let url = SecurityScopedBookmark.resolve(bookmark) else {
            self.rate = rate
            remove(displayID: displayID)
            return
        }
        assign(url: url, rate: rate, fillMode: fillMode, to: screen, displayID: displayID)
    }

    func assign(url: URL, rate: Float, fillMode: FillMode, to screen: NSScreen, displayID: String) {
        self.rate = rate
        remove(displayID: displayID)

        let window = DesktopWindow(screen: screen)
        let player = WallpaperPlayer(url: url, fillMode: fillMode)
        window.contentView = player.view
        window.orderFront(nil)
        player.updatePresentation() // the view now has the screen's size
        // Deliberately not gated on occlusion: a window ordered in this instant hasn't
        // been given an occlusion state yet, and reading it here would leave the
        // wallpaper stopped until something else moved. The notification takes over.
        player.setRate(isPaused || isThrottled ? 0 : rate)

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

    /// Stops every player for the duration of a lock, and starts it again on the way
    /// out. Coming back needs the surface rebuilt — the shield took it — so this uses
    /// `restartLoop`, the tool measured to be right for that transition. Display sleep
    /// suspends through here too, but *wakes* through `handleWake` instead, which
    /// re-attaches: the two causes look identical from here and don't share a cure.
    func setSuspended(_ suspended: Bool) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        guard !suspended else {
            applyRates() // rate(for:) now returns 0 for every display
            return
        }
        for player in players.values { player.restartLoop() }
        applyRates()
    }

    /// Waking from display or system sleep leaves the video layers detached.
    func handleWake() {
        isSuspended = false
        for (id, player) in players {
            player.reattach()
            windows[id]?.orderFront(nil)
            // Re-derive rather than restore: the occluding window may well have gone
            // away while the display slept, and a stopped wallpaper must never be able
            // to stay stopped just because nothing else moved afterwards.
            player.setRate(rate(for: id))
        }
    }

    func setThrottled(_ throttled: Bool) {
        guard throttled != isThrottled else { return }
        isThrottled = throttled
        applyRates()
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
