//
//  WallpaperContentView.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  Layer-backed host for the video: a blurred backdrop layer underneath, the
//  AVPlayerLayer on top. Manually added sublayers inherit neither the view's
//  size nor its contentsScale, so both are re-synced on every geometry or
//  backing-property change — a sublayer left at contentsScale 1 renders the
//  video at half resolution on a Retina display.
//

import AVFoundation
import AppKit

final class WallpaperContentView: NSView {
    let videoLayer: AVPlayerLayer
    let backdropLayer = CALayer()

    init(videoLayer: AVPlayerLayer) {
        self.videoLayer = videoLayer
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        backdropLayer.contentsGravity = .resizeAspectFill
        backdropLayer.masksToBounds = true
        backdropLayer.isHidden = true

        layer?.addSublayer(backdropLayer)
        layer?.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        syncLayers()
    }

    override func layout() {
        super.layout()
        syncLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncLayers()
    }

    private func syncLayers() {
        let scale = window?.backingScaleFactor ?? layer?.contentsScale ?? 2
        // Resolution/arrangement changes would otherwise animate the layers into
        // place over ~0.25s, which reads as a glitch on a wallpaper.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [backdropLayer, videoLayer as CALayer] {
            sublayer.frame = bounds
            sublayer.contentsScale = scale
        }
        CATransaction.commit()
    }
}
