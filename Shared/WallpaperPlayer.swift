//
//  WallpaperPlayer.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  Wraps a single looping, muted video pipeline plus the view it renders into.
//  AVPlayerLooper owns the loop — no manual seek-to-zero timers, no frame
//  stepping. `setRate` is the single control point for pause (0), normal (1)
//  and speed changes.
//

import AVFoundation
import AppKit

final class WallpaperPlayer {
    let view: WallpaperContentView

    private let asset: AVURLAsset
    private let queuePlayer: AVQueuePlayer
    private let looper: AVPlayerLooper
    /// AVPlayer silently drops a rate set before the item is ready to play, and can
    /// drop back to 0 after display sleep. One KVO re-asserts it; no polling.
    private var rateKeeper: NSKeyValueObservation?
    private var desiredRate: Float = 0
    private var videoSize: CGSize?
    private var fillMode: FillMode
    private var hasBackdrop = false

    init(url: URL, fillMode: FillMode) {
        self.fillMode = fillMode
        self.asset = AVURLAsset(url: url)

        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none // AVPlayerLooper drives looping, not item-end handling
        // AVPlayer asserts "prevent display sleep" for video by default. For a wallpaper
        // that is backwards: it keeps the display awake forever and stops the screen
        // saver from ever starting (loginwindow logs "PMNoDisplaySleepEnabled so do not
        // launch screen saver").
        player.preventsDisplaySleepDuringVideoPlayback = false
        // The file is local, so there is nothing to buffer and nothing to stall on.
        // Left at its default the player holds the first rate change back while it
        // decides it has "enough" media, which on the lock screen reads as a video
        // that sits on one frame for a second before it starts moving.
        player.automaticallyWaitsToMinimizeStalling = false
        self.looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
        self.queuePlayer = player

        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = VideoPresentation.gravity(fillMode, video: nil, in: .zero)
        self.view = WallpaperContentView(videoLayer: layer)

        let capturedAsset = asset
        Task { [weak self] in
            let size = await VideoPresentation.displaySize(of: capturedAsset)
            self?.videoSize = size
            self?.updatePresentation()
        }
    }

    func setRate(_ rate: Float) {
        desiredRate = rate
        // Tear the old observer down first: it captured the previous rate and would
        // re-assert it the moment this assignment changes timeControlStatus.
        rateKeeper = nil
        queuePlayer.rate = rate
        guard rate > 0 else { return }
        rateKeeper = queuePlayer.observe(\.timeControlStatus) { player, _ in
            if player.rate != rate && player.error == nil {
                player.rate = rate
            }
        }
    }

    /// Rebuilds the layer's video surface.
    ///
    /// Two things take it away: the display going to sleep, and the lock screen's shield
    /// taking over the display. In both cases the player keeps decoding into nothing —
    /// CoreMedia reports "enqueued: 12, displayed: 0" — and no rate KVO can catch it,
    /// because playback never stopped. Left alone it only heals when `AVPlayerLooper`
    /// reaches the end of the clip and its gapless transition builds a fresh image queue,
    /// which is why the lock screen took anywhere from two seconds to a whole loop to
    /// start moving. Re-attaching the player forces that new queue immediately.
    func reattach() {
        let layer = view.videoLayer
        layer.player = nil
        layer.player = queuePlayer
        updatePresentation()
        setRate(desiredRate)
    }

    /// Asks `AVPlayerLooper` for its gapless transition now, instead of waiting for the
    /// end of the clip. Detaching the layer is the wrong tool for the lock screen: it
    /// leaves the orphaned image queues decoding and takes longer to come back (measured
    /// 8s vs 5s). The transition is what was actually observed rebuilding the surface.
    func restartLoop() {
        queuePlayer.advanceToNextItem()
        setRate(desiredRate)
    }

    func setFillMode(_ mode: FillMode) {
        fillMode = mode
        updatePresentation()
    }

    /// Re-decides fill vs. letterbox for the view's current size. Cheap — call it
    /// after any resize; only the first letterboxed layout pays for a backdrop.
    func updatePresentation() {
        let gravity = VideoPresentation.gravity(fillMode, video: videoSize, in: view.bounds.size)
        view.videoLayer.videoGravity = gravity

        let needsBackdrop = gravity == .resizeAspect
        view.backdropLayer.isHidden = !needsBackdrop
        guard needsBackdrop, !hasBackdrop else { return }

        hasBackdrop = true
        let capturedAsset = asset
        Task { [weak self] in
            let image = await VideoPresentation.blurredBackdrop(of: capturedAsset)
            self?.view.backdropLayer.contents = image
        }
    }

    deinit {
        rateKeeper = nil
        looper.disableLooping()
        queuePlayer.pause()
    }
}
