//
//  VideoPresentation.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  How a video is mapped onto a display whose aspect ratio doesn't match it.
//  Pure math + one one-shot image generation; no state, no timers.
//

import AVFoundation
import CoreImage

/// Listed in the order the menu shows them: most cropping first, and `auto` — which
/// only ever picks one of the other two — last.
enum FillMode: String, Codable, CaseIterable {
    /// Always cover the display (crops).
    case fill
    /// Cover the display too, but never crop away more than `autoFillThreshold`
    /// of the frame: whatever cover is still missing becomes (small) blurred bars.
    case smart
    /// Never crop (letterboxes onto the blurred backdrop).
    case fit
    /// Fill unless that would crop away too much of the frame, then letterbox.
    case auto

    var title: String {
        switch self {
        case .fill: "Fill (crop)"
        case .smart: "Smart (crop a little)"
        case .fit: "Fit (no crop)"
        case .auto: "Auto (fill or fit)"
        }
    }
}

enum VideoPresentation {
    /// How much of the frame must survive an aspect-fill crop for `.auto` to still fill.
    /// 0.85 keeps 16:9-on-16:10 filling, and stops 16:9-on-32:9 (5120×1440) from
    /// throwing away half the frame.
    static let autoFillThreshold: CGFloat = 0.85

    /// Fraction of the video that stays on screen when aspect-filling `bounds`.
    /// Aspect-fill scales by the larger axis ratio, so exactly one axis overflows:
    /// the surviving area is the smaller of the two aspect ratios' quotient.
    static func visibleFraction(video: CGSize, in bounds: CGSize) -> CGFloat {
        guard video.width > 0, video.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        let videoAspect = video.width / video.height
        let boundsAspect = bounds.width / bounds.height
        return min(videoAspect / boundsAspect, boundsAspect / videoAspect)
    }

    static func gravity(_ mode: FillMode, video: CGSize?, in bounds: CGSize) -> AVLayerVideoGravity {
        switch mode {
        case .fill:
            return .resizeAspectFill
        case .fit:
            return .resizeAspect
        case .smart:
            // `zoom` does the cropping by enlarging the layer, so the gravity is the
            // uncropped one — until the track size is known, where it would show bars.
            return video == nil ? .resizeAspectFill : .resizeAspect
        case .auto:
            // Until the track size is known, filling is the safer guess (no bars).
            guard let video else { return .resizeAspectFill }
            return visibleFraction(video: video, in: bounds) >= autoFillThreshold ? .resizeAspectFill : .resizeAspect
        }
    }

    /// How much bigger than the view the video layer is drawn — the whole of `.smart`.
    /// Aspect-fit at zoom `z` keeps `1/z` of the frame and covers `z · fill` of the
    /// display, which is the trade `auto` can only take at its two extremes.
    ///
    /// Covering outright is cheap? Take it — bars nobody needed look worse than a crop
    /// nobody notices. Otherwise split the difference exactly: at `1/√fill` both
    /// fractions come out at `√fill`, so a 16:9 clip on a 32:9 display keeps 71% of the
    /// frame *and* covers 71% of the display, instead of choosing which half to lose.
    static func zoom(_ mode: FillMode, video: CGSize?, in bounds: CGSize) -> CGFloat {
        guard mode == .smart, let video else { return 1 }
        let fill = visibleFraction(video: video, in: bounds)
        guard fill < autoFillThreshold else { return 1 / fill }
        return 1 / fill.squareRoot()
    }

    /// Pixel dimensions as displayed — `naturalSize` alone is wrong for rotated recordings.
    static func displaySize(of asset: AVAsset) async -> CGSize? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let rotated = size.applying(transform)
        let result = CGSize(width: abs(rotated.width), height: abs(rotated.height))
        return result.width > 0 && result.height > 0 ? result : nil
    }

    /// A single blurred frame used to fill the letterbox bars. Generated once and
    /// then static — no second decode pipeline, so it costs nothing while running.
    /// Rendered small on purpose: it's blurred, upscaling it costs no visible quality.
    static func blurredBackdrop(of asset: AVAsset) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        guard let frame = try? await generator.image(at: CMTime(value: 1, timescale: 1)).image else { return nil }

        let source = CIImage(cgImage: frame)
        let blurred = source
            .clampedToExtent() // otherwise the blur fades the edges to transparent
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 40])
            .cropped(to: source.extent)
            .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.12, kCIInputSaturationKey: 1.15])
        return CIContext().createCGImage(blurred, from: blurred.extent)
    }
}
