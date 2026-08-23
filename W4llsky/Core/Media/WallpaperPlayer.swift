//
//  WallpaperPlayer.swift
//  W4llsky
//
//  Wraps a single looping, muted video pipeline. AVPlayerLooper owns the loop —
//  no manual seek-to-zero timers, no frame stepping. `rate` is the single
//  control point for pause (0), normal (1) and speed changes.
//

import AVFoundation

final class WallpaperPlayer {
    let layer: AVPlayerLayer

    private let queuePlayer: AVQueuePlayer
    private let looper: AVPlayerLooper

    init(url: URL) {
        let item = AVPlayerItem(url: url)
        let player = AVQueuePlayer()
        player.isMuted = true
        player.actionAtItemEnd = .none // AVPlayerLooper drives looping, not item-end handling

        self.looper = AVPlayerLooper(player: player, templateItem: item)
        self.queuePlayer = player
        self.layer = AVPlayerLayer(player: player)
        self.layer.videoGravity = .resizeAspectFill // Fill by default per spec
    }

    func setRate(_ rate: Float) {
        queuePlayer.rate = rate
    }

    deinit {
        looper.disableLooping()
        queuePlayer.pause()
    }
}
