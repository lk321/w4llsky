//
//  WallpaperPlayer.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  Two halves. `VideoPipeline` is the decode: one looping, muted AVQueuePlayer per
//  video *file* per process, however many displays show it. `WallpaperPlayer` is one
//  display's view of it: its own AVPlayerLayer, gravity and zoom, attached to the
//  shared pipeline. AVPlayerLooper owns the loop — no manual seek-to-zero timers, no
//  frame stepping. `setRate` is the single control point for pause (0), normal (1)
//  and speed changes.
//

import AVFoundation
import AppKit

/// One AVPlayer drives any number of AVPlayerLayers off a single decode — measured:
/// four 4K layers on one player cost 18 MB / 1.5% CPU against 31 MB / 3.9% for four
/// players, all four frame-locked. Without sharing, every display of ours was a whole
/// 4K decoder of its own, and so was every saver view WallpaperAgent builds in one
/// `legacyScreenSaver`. With it, decoders are bounded to one per file per process and
/// extra views cost a layer each. Whether WallpaperAgent hosts several displays in one
/// process or one each is unverified above one display.
final class VideoPipeline {
    let asset: AVURLAsset
    let player: AVQueuePlayer
    private let looper: AVPlayerLooper
    /// AVPlayer silently drops a rate set before the item is ready to play, and can
    /// drop back to 0 after display sleep. One KVO re-asserts it; no polling.
    private var rateKeeper: NSKeyValueObservation?
    /// Each attached display's wish. The pipeline plays at the highest one: a video
    /// visible on any display has to move, and stops only when nobody can see it.
    private var demands: [ObjectIdentifier: Float] = [:]
    private var lastRestart: TimeInterval = 0
    private(set) lazy var videoSize = Task { [asset] in await VideoPresentation.displaySize(of: asset) }
    private(set) lazy var backdrop = Task { [asset] in await VideoPresentation.blurredBackdrop(of: asset) }

    // ponytail: weak cache keyed by file identity, never evicts by hand — the last
    // WallpaperPlayer to let go frees the decoder.
    private static var live: [String: WeakPipeline] = [:]
    static var liveCount: Int { live.values.filter { $0.value != nil }.count }

    /// Keyed by file identity, not path: `LockScreenLibrary.install` replaces
    /// LockScreen.mp4 *at the same path*, and a path key would hand every rebuilt view
    /// the old video for as long as any other view still held it.
    static func shared(for url: URL) -> VideoPipeline {
        let key = identity(of: url)
        live = live.filter { $0.value.value != nil }
        if let pipeline = live[key]?.value { return pipeline }
        let pipeline = VideoPipeline(url: url)
        live[key] = WeakPipeline(value: pipeline)
        return pipeline
    }

    static func identity(of url: URL) -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes?[.systemNumber], let inode = attributes?[.systemFileNumber] else { return url.path }
        return "\(device):\(inode)"
    }

    private init(url: URL) {
        asset = AVURLAsset(url: url)
        player = AVQueuePlayer()
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
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(asset: asset))
    }

    func setRate(_ rate: Float, for owner: AnyObject) {
        demands[ObjectIdentifier(owner)] = rate
        applyRate()
    }

    func detach(_ owner: ObjectIdentifier) {
        demands[owner] = nil
        applyRate()
    }

    func applyRate() {
        let rate = demands.values.max() ?? 0
        // Tear the old observer down first: it captured the previous rate and would
        // re-assert it the moment this assignment changes timeControlStatus.
        rateKeeper = nil
        player.rate = rate
        guard rate > 0 else { return }
        rateKeeper = player.observe(\.timeControlStatus) { player, _ in
            if player.rate != rate && player.error == nil {
                player.rate = rate
            }
        }
    }

    /// Asks `AVPlayerLooper` for its gapless transition now, instead of waiting for the
    /// end of the clip. Every view on a lock screen asks at once; the pipeline is shared,
    /// so only the first is honoured — N `advanceToNextItem()`s would skip N items.
    ///
    /// The transition lands on the next replica's first frame, which on screen was a jump
    /// back to the start of the clip on every lock and unlock. So it seeks back to where
    /// the video was, or to `position` when the other process knows better (the desktop
    /// handing over to the lock screen and back).
    func restartLoop(at position: Double? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastRestart > 1 else { return }
        lastRestart = now
        let resume = position ?? self.position
        player.advanceToNextItem()
        seek(to: resume)
        applyRate()
    }

    /// Seconds into the clip.
    var position: Double { player.currentTime().seconds }

    /// Exact, so the handoff lands on the frame that was showing. The keyframe interval is
    /// short (1s in the files measured), so this decodes at most a second of video.
    func seek(to seconds: Double) {
        guard let duration = player.currentItem?.duration.seconds, duration > 0, seconds.isFinite else { return }
        let time = CMTime(seconds: seconds.truncatingRemainder(dividingBy: duration), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// The pipeline already playing `url` in this process, without building one.
    static func existing(for url: URL) -> VideoPipeline? {
        live[identity(of: url)]?.value
    }

    deinit {
        rateKeeper = nil
        looper.disableLooping()
        player.pause()
        player.removeAllItems() // frees the decoder even if some layer still holds the player
    }
}

private struct WeakPipeline {
    weak var value: VideoPipeline?
}

final class WallpaperPlayer {
    let view: WallpaperContentView

    private let pipeline: VideoPipeline
    private var videoSize: CGSize?
    private var fillMode: FillMode
    private var hasBackdrop = false

    init(url: URL, fillMode: FillMode) {
        self.fillMode = fillMode
        self.pipeline = VideoPipeline.shared(for: url)

        let layer = AVPlayerLayer(player: pipeline.player)
        layer.videoGravity = VideoPresentation.gravity(fillMode, video: nil, in: .zero)
        self.view = WallpaperContentView(videoLayer: layer)

        let size = pipeline.videoSize
        Task { [weak self] in
            let value = await size.value
            self?.videoSize = value
            self?.updatePresentation()
        }
    }

    func setRate(_ rate: Float) {
        pipeline.setRate(rate, for: self)
    }

    /// Seconds into the clip, so a still frame can freeze the one that was showing.
    var position: Double { pipeline.position }

    /// Rebuilds this layer's video surface.
    ///
    /// Two things take it away: the display going to sleep, and the lock screen's shield
    /// taking over the display. In both cases the player keeps decoding into nothing —
    /// CoreMedia reports "enqueued: 12, displayed: 0" — and no rate KVO can catch it,
    /// because playback never stopped. Left alone it only heals when `AVPlayerLooper`
    /// reaches the end of the clip and its gapless transition builds a fresh image queue,
    /// which is why the lock screen took anywhere from two seconds to a whole loop to
    /// start moving. Re-attaching the player forces that new queue immediately. Per
    /// layer: the shared queue itself is left alone.
    func reattach() {
        let layer = view.videoLayer
        layer.player = nil
        layer.player = pipeline.player
        updatePresentation()
        pipeline.applyRate()
    }

    /// Detaching the layer is the wrong tool for the lock screen: it leaves the orphaned
    /// image queues decoding and takes longer to come back (measured 8s vs 5s). The
    /// looper's transition is what was actually observed rebuilding the surface.
    func restartLoop(at position: Double? = nil) {
        pipeline.restartLoop(at: position)
    }

    func setFillMode(_ mode: FillMode) {
        fillMode = mode
        updatePresentation()
    }

    /// Re-decides fill vs. letterbox for the view's current size. Cheap — call it
    /// after any resize; only the first letterboxed layout pays for a backdrop, and the
    /// backdrop itself is rendered once per file, not per display.
    func updatePresentation() {
        let bounds = view.bounds.size
        let gravity = VideoPresentation.gravity(fillMode, video: videoSize, in: bounds)
        let zoom = VideoPresentation.zoom(fillMode, video: videoSize, in: bounds)
        view.videoLayer.videoGravity = gravity
        view.videoZoom = zoom

        // Fraction of the view an aspect-fitted, `zoom`-enlarged video covers. `.smart`
        // reaches 1 whenever a full cover costs less than the threshold, and then there
        // is nothing for a backdrop to fill.
        let covered = zoom * (videoSize.map { VideoPresentation.visibleFraction(video: $0, in: bounds) } ?? 1)
        let needsBackdrop = gravity == .resizeAspect && covered < 0.999
        view.backdropLayer.isHidden = !needsBackdrop
        guard needsBackdrop, !hasBackdrop else { return }

        hasBackdrop = true
        let backdrop = pipeline.backdrop
        Task { [weak self] in
            let image = await backdrop.value
            self?.view.backdropLayer.contents = image
        }
    }

    deinit {
        // The layer lets go of the player here, not whenever AppKit gets round to
        // releasing the view — a window or view kept alive a little longer must not keep
        // a decoder alive with it.
        view.videoLayer.player = nil
        let pipeline = pipeline
        let id = ObjectIdentifier(self)
        MainActor.assumeIsolated { pipeline.detach(id) }
    }
}
