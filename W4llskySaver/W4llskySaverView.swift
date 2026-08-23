//
//  W4llskySaverView.swift
//  W4llsky screen saver
//
//  The lock screen / idle-time half of W4llsky. macOS gives no public way to
//  draw on the lock screen itself, so the video is delivered the way the system
//  supports it: a screen saver bundle the app installs into
//  ~/Library/Screen Savers and the user picks once in Screen Saver settings.
//
//  Rendering is the exact same WallpaperPlayer the desktop wallpaper uses, so
//  scaling behaves identically on every display.
//

import AppKit
import AVFoundation
import ScreenSaver

@objc(W4llskySaverView)
final class W4llskySaverView: ScreenSaverView {
    private var player: WallpaperPlayer?
    private var rate: Float = 1

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)

        // Nothing is drawn per frame — AVFoundation composites the video itself.
        // The framework still wants a valid interval; keep its timer near-idle.
        animationTimeInterval = 1
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        autoresizesSubviews = true

        guard let config = LockScreenLibrary.load() else { return }
        rate = config.rate

        let player = WallpaperPlayer(url: LockScreenLibrary.videoURL, fillMode: config.fillMode)
        player.view.frame = bounds
        player.view.autoresizingMask = [.width, .height]
        addSubview(player.view)
        player.updatePresentation()
        self.player = player
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("screen savers are instantiated with init(frame:isPreview:)") }

    override func startAnimation() {
        super.startAnimation()
        player?.setRate(rate)
    }

    override func stopAnimation() {
        player?.setRate(0)
        super.stopAnimation()
    }

    override var hasConfigureSheet: Bool { false }
    override var configureSheet: NSWindow? { nil }
}
