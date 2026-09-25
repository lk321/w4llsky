//
//  SaverPlayback.swift
//  W4llsky — shared by the app and the screen saver bundle.
//
//  What one saver view shows, decided in one pure place so every combination is
//  tested. It lives in Shared/ only so the app's test target can reach it.
//

/// Every way this has broken so far was a reason to stop that nothing ever took back:
/// a memory warning macOS holds for hours, a `startAnimation` that never arrived. So
/// every input here must have an event that clears it (see CLAUDE.md).
nonisolated enum SaverPlayback: Equatable {
    /// No player and no still frame: nothing to show, or macOS stopped us (display sleep).
    case none
    /// Decoder released, one frozen frame instead: saving battery or out of memory.
    /// Not black: a black lock screen reads as broken, a still one as a choice.
    case still
    /// Decoder warm at rate 0: W4llsky covers the desktop, or the Mac is hot.
    case paused
    case playing(Float)

    static func decide(
        inWindow: Bool, hasVideo: Bool, stopped: Bool, released: Bool,
        throttled: Bool, covered: Bool, locked: Bool, rate: Float
    ) -> SaverPlayback {
        guard inWindow, hasVideo, !stopped else { return .none }
        if released { return .still }
        // The lock screen is all there is to see, and W4llsky is suspended while locked,
        // so neither heat nor the cover stops it.
        if locked { return .playing(rate) }
        if throttled || covered { return .paused }
        return .playing(rate)
    }
}
