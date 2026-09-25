//
//  W4llskySaverView.swift
//  W4llsky screen saver
//
//  The lock screen half of W4llsky. macOS gives no public way to draw on the lock
//  screen itself, so the video is delivered the way the system supports it: a screen
//  saver bundle the app installs into ~/Library/Screen Savers and then selects as the
//  *wallpaper*, which is what the lock screen actually draws.
//
//  Rendering is the exact same WallpaperPlayer the desktop wallpaper uses, so scaling
//  behaves identically on every display.
//

import AppKit
import AVFoundation
import ScreenSaver
import os

@objc(W4llskySaverView)
final class W4llskySaverView: ScreenSaverView {
    private var player: WallpaperPlayer?
    private var config: LockScreenConfig?
    /// Every saver process reacts on its own, so this holds however WallpaperAgent splits
    /// displays across `legacyScreenSaver` instances.
    private var pressure: SystemPressure?
    /// Only an explicit `stopAnimation` idles the view. `isAnimating` can't be the gate:
    /// WallpaperAgent logs "starting animation" before the respawned process has a view to
    /// tell, so `startAnimation` never arrives and the lock screen stayed black. With the
    /// decoder shared per process, a view that plays without being asked costs one layer.
    private var isStopped = false
    private var still: Task<Void, Never>?
    private var lastDecision: SaverPlayback?

    /// How many views WallpaperAgent has animating in this process, against how many
    /// decoders they share. Views climbing with pipelines at 1 is the design working;
    /// pipelines climbing is the stacking bug back. `log stream --level debug
    /// --predicate 'subsystem == "com.personal.W4llsky.saver"'` shows it live.
    private static var playingViews = 0
    /// Process-wide, because WallpaperAgent builds new views at lock time too, and a view
    /// born after the notification still has to know.
    private static var isLocked = false
    private static let log = Logger(subsystem: "com.personal.W4llsky.saver", category: "playback")

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)

        // Nothing is drawn per frame — AVFoundation composites the video itself.
        // The framework still wants a valid interval; keep its timer near-idle.
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true

        config = LockScreenLibrary.load()
        pressure = SystemPressure { [weak self] _ in self?.syncPlayback() }

        // The shield replaces the display's surface out from under our video layer, and
        // nothing in AVFoundation notices: the player keeps decoding into nothing until
        // the loop happens to roll over. This is the only warning we get that it is about
        // to happen. .deliverImmediately because this process is never frontmost.
        // The selector API on purpose: the block-based one has no suspensionBehavior,
        // and the default holds notifications for a process that is never frontmost —
        // which this one never is.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenLocked),
            name: .init("com.apple.screenIsLocked"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(screenUnlocked),
            name: .init("com.apple.screenIsUnlocked"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // W4llsky draws the desktop itself and tells us when it covers every display.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(coverChanged),
            name: LockScreenLibrary.coverChangedNotification, object: nil,
            suspensionBehavior: .deliverImmediately
        )

        // WallpaperAgent decides when this view is built, and that can be hours before
        // the user picks a different scaling in the menu. Without this the config read
        // above is the only one that ever happens, so every change in the menu wrote a
        // file nobody re-read — the scaling looked broken because nothing applied it.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(configChanged),
            name: LockScreenLibrary.changedNotification, object: nil,
            suspensionBehavior: .deliverImmediately
        )
        // WallpaperAgent stops us on display sleep and is meant to start us on wake, but
        // its start is exactly the message that has been seen to get lost.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensWoke),
            name: NSWorkspace.screensDidWakeNotification, object: nil
        )
    }

    @objc private func screensWoke() {
        isStopped = false
        syncPlayback()
    }

    @objc private func configChanged() {
        let updated = LockScreenLibrary.load()
        // Scaling and speed apply to the running pipeline; a different file needs a new
        // one, and so does the video being removed.
        if updated?.videoName != config?.videoName {
            teardown()
            hideStill()
        }
        config = updated
        syncPlayback()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        if player != nil { MainActor.assumeIsolated { Self.playingViews -= 1 } }
    }

    /// Once the shield has actually taken the display — the notification is sent while
    /// the lock is still going up, so acting on it immediately is too early.
    ///
    /// Resumes at once (a paused pipeline is still warm, so there is no cold start) and
    /// continues from the frame the desktop was showing, which W4llsky wrote down as the
    /// Mac locked. A playhead that isn't from this lock is ignored, and the video resumes
    /// where it paused.
    @objc private func screenLocked() {
        Self.isLocked = true
        syncPlayback()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            let now = CACurrentMediaTime()
            let playhead = LockScreenLibrary.loadPlayhead().flatMap { abs(now - $0.hostTime) < 5 ? $0 : nil }
            self?.player?.restartLoop(at: playhead?.position(at: now))
        }
    }

    @objc private func screenUnlocked() {
        Self.isLocked = false
        syncPlayback()
    }

    @objc private func coverChanged() {
        syncPlayback()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("screen savers are instantiated with init(frame:isPreview:)") }

    override func startAnimation() {
        super.startAnimation()
        isStopped = false
        syncPlayback()
    }

    override func stopAnimation() {
        super.stopAnimation()
        isStopped = true
        syncPlayback()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncPlayback()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncPlayback()
        player?.updatePresentation() // a size change can flip fill vs. letterbox
    }

    /// Builds the video pipeline only while `SaverPlayback` says to play, and throws it
    /// away the moment it doesn't. Building it in `init` once left a decoder running for
    /// every view WallpaperAgent happened to make, and it makes more than one — see
    /// `SystemScreenSaver.removeRedundantScreenSaverSelection()`, which stops the
    /// duplicates at the source, since nothing here can tell them apart.
    private func syncPlayback() {
        let level = pressure?.level ?? .normal
        let decision = SaverPlayback.decide(
            inWindow: window != nil && !bounds.isEmpty,
            hasVideo: config != nil,
            stopped: isStopped,
            released: level == .release || LockScreenLibrary.isPowerSaving,
            throttled: level == .throttle,
            covered: LockScreenLibrary.isDesktopCovered,
            locked: Self.isLocked,
            rate: config?.rate ?? 1
        )
        if decision != lastDecision {
            lastDecision = decision
            Self.log.notice("pid \(getpid()): \(String(describing: decision), privacy: .public)")
        }

        switch decision {
        case .none:
            teardown()
            hideStill()
        case .still:
            showStill(at: player?.position)
            teardown()
        case .paused, .playing:
            guard let config else { return }
            hideStill()
            if player == nil {
                let player = WallpaperPlayer(url: LockScreenLibrary.videoURL, fillMode: config.fillMode)
                player.view.frame = bounds
                player.view.autoresizingMask = [.width, .height]
                addSubview(player.view)
                player.updatePresentation()
                self.player = player
                Self.playingViews += 1
                Self.log.notice("pid \(getpid()): \(Self.playingViews) views, \(VideoPipeline.liveCount) decoders")
            }
            player?.setFillMode(config.fillMode) // may have changed under an existing player
            if case .playing(let rate) = decision { player?.setRate(rate) } else { player?.setRate(0) }
        }
    }

    /// The frame that was showing, frozen on this view's own layer (underneath the player's
    /// view), so releasing the decoder never leaves the desktop or the lock screen black.
    /// ponytail: `.smart` and `.auto` freeze as a plain fill, and the frame is black for the
    /// ~0.1s it takes to decode; neither is worth keeping a decoder alive for.
    private func showStill(at position: Double?) {
        guard still == nil, layer?.contents == nil, let config else { return }
        let seconds = position ?? LockScreenLibrary.loadPlayhead()?.position ?? 1
        // Points, not pixels: a Retina-sized frame weighs as much as the paused decoder it
        // replaces, and saving memory is the point. A still behind the clock can be soft.
        let size = bounds.size
        let asset = AVURLAsset(url: LockScreenLibrary.videoURL)
        let gravity: CALayerContentsGravity = config.fillMode == .fit ? .resizeAspect : .resizeAspectFill
        still = Task { [weak self] in
            let image = await VideoPresentation.frame(of: asset, at: seconds, maxSize: size)
            guard let self, !Task.isCancelled else { return }
            self.layer?.contentsGravity = gravity
            self.layer?.contents = image
            self.still = nil
        }
    }

    private func hideStill() {
        still?.cancel()
        still = nil
        layer?.contents = nil
    }

    /// Releasing the player is what frees the decoder — setting its rate to 0 does not.
    private func teardown() {
        guard player != nil else { return }
        // No local binding and a drained pool, so the count logged below is the real one:
        // either would keep the player, and its decoder, alive until this returns.
        autoreleasepool {
            player?.view.removeFromSuperview()
            player = nil
        }
        Self.playingViews -= 1
        Self.log.notice("pid \(getpid()): \(Self.playingViews) views, \(VideoPipeline.liveCount) decoders")
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
