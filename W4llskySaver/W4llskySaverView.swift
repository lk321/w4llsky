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
    }

    @objc private func configChanged() {
        let updated = LockScreenLibrary.load()
        // Scaling and speed apply to the running pipeline; a different file needs a new
        // one, and so does the video being removed.
        if updated?.videoName != config?.videoName { teardown() }
        config = updated
        syncPlayback()
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
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
        syncPlayback()
    }

    override func stopAnimation() {
        super.stopAnimation() // flips the inherited `isAnimating` that syncPlayback reads
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

    /// Builds the video pipeline only while this view is animating in a real window, and
    /// throws it away the moment it isn't. Building it in `init` instead left a decoder
    /// running for every view WallpaperAgent happened to make, and it makes more than
    /// one — see `SystemScreenSaver.removeRedundantScreenSaverSelection()`, which stops
    /// the duplicates at the source, since nothing here can tell them apart.
    private func syncPlayback() {
        let level = pressure?.level ?? .normal
        guard isAnimating, let config, window != nil, !bounds.isEmpty, level != .release else {
            teardown()
            return
        }

        if player == nil {
            let player = WallpaperPlayer(url: LockScreenLibrary.videoURL, fillMode: config.fillMode)
            player.view.frame = bounds
            player.view.autoresizingMask = [.width, .height]
            addSubview(player.view)
            player.updatePresentation()
            self.player = player
            Self.playingViews += 1
            Self.log.debug("pid \(getpid()): \(Self.playingViews) views, \(VideoPipeline.liveCount) decoders")
        }
        player?.setFillMode(config.fillMode) // may have changed under an existing player
        // Covered by W4llsky's own windows, nobody sees this copy, but the lock screen needs
        // it the instant the Mac locks. Rate 0 keeps the decoder warm; releasing it would
        // mean a cold 4K start behind the password field.
        let covered = LockScreenLibrary.isDesktopCovered && !Self.isLocked
        player?.setRate(level == .throttle || covered ? 0 : config.rate)
    }

    /// Releasing the player is what frees the decoder — setting its rate to 0 does not.
    private func teardown() {
        guard let player else { return }
        player.view.removeFromSuperview()
        self.player = nil
        Self.playingViews -= 1
        Self.log.debug("pid \(getpid()): \(Self.playingViews) views, \(VideoPipeline.liveCount) decoders")
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
