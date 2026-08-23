//
//  VideoPresentation.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  How a video is mapped onto a display whose aspect ratio doesn't match it.
//  Pure math + one one-shot image generation; no state, no timers.
//

import AVFoundation
import CoreImage

enum FillMode: String, Codable, CaseIterable {
    /// Fill unless that would crop away too much of the frame, then letterbox.
    case auto
    /// Always cover the display (crops).
    case fill
    /// Never crop (letterboxes onto the blurred backdrop).
    case fit

    var title: String {
        switch self {
        case .auto: "Auto"
        case .fill: "Fill (crop)"
        case .fit: "Fit (no crop)"
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
        case .auto:
            // Until the track size is known, filling is the safer guess (no bars).
            guard let video else { return .resizeAspectFill }
            return visibleFraction(video: video, in: bounds) >= autoFillThreshold ? .resizeAspectFill : .resizeAspect
        }
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
