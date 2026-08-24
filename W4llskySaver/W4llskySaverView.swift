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

@objc(W4llskySaverView)
final class W4llskySaverView: ScreenSaverView {
    private var player: WallpaperPlayer?
    private var config: LockScreenConfig?

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)

        // Nothing is drawn per frame — AVFoundation composites the video itself.
        // The framework still wants a valid interval; keep its timer near-idle.
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true

        config = LockScreenLibrary.load()

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
    }

    /// Once the shield has actually taken the display — the notification is sent while
    /// the lock is still going up, so acting on it immediately is too early.
    @objc private func screenLocked() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.player?.restartLoop()
        }
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
        guard isAnimating, let config, window != nil, !bounds.isEmpty else {
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
        }
        player?.setFillMode(config.fillMode) // may have changed under an existing player
        player?.setRate(config.rate)
    }

    /// Releasing the player is what frees the decoder — setting its rate to 0 does not.
    private func teardown() {
        player?.view.removeFromSuperview()
        player = nil
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
