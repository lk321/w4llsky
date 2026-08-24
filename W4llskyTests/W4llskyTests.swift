//
//  W4llskyTests.swift
//  W4llskyTests
//
//  The scaling decision is the one piece of real logic here: get it wrong and
//  every wallpaper is either cropped in half or letterboxed for no reason.
//

import AVFoundation
import SwiftUI
import XCTest
@testable import W4llsky

/// The About window sizes itself from its content, so a layout that reports nothing
/// would open as a title bar with a sliver under it — the app's only window, broken.
final class AboutWindowTests: XCTestCase {
    @MainActor
    func testAboutContentReportsARealSize() {
        let size = NSHostingView(rootView: ContentView()).fittingSize
        XCTAssertEqual(size.width, 320, accuracy: 1) // the width the layout pins
        XCTAssertGreaterThan(size.height, 150)       // grows with the version and author lines
    }
}

final class W4llskyTests: XCTestCase {

    private let ultrawide = CGSize(width: 5120, height: 1440)
    private let sixteenNine = CGSize(width: 3840, height: 2160)

    func testAspectFillOnAMatchingDisplayKeepsEverything() {
        XCTAssertEqual(VideoPresentation.visibleFraction(video: ultrawide, in: ultrawide), 1, accuracy: 0.001)
    }

    func testSixteenNineOnUltrawideLosesHalfTheFrame() {
        let fraction = VideoPresentation.visibleFraction(video: sixteenNine, in: ultrawide)
        XCTAssertEqual(fraction, 0.5, accuracy: 0.001)
    }

    func testVisibleFractionIsSymmetric() {
        XCTAssertEqual(
            VideoPresentation.visibleFraction(video: sixteenNine, in: ultrawide),
            VideoPresentation.visibleFraction(video: ultrawide, in: sixteenNine),
            accuracy: 0.001
        )
    }

    func testDegenerateSizesDontDivideByZero() {
        XCTAssertEqual(VideoPresentation.visibleFraction(video: .zero, in: ultrawide), 1)
        XCTAssertEqual(VideoPresentation.visibleFraction(video: sixteenNine, in: .zero), 1)
    }

    func testAutoLetterboxesWhenFillingWouldCropTooMuch() {
        XCTAssertEqual(VideoPresentation.gravity(.auto, video: sixteenNine, in: ultrawide), .resizeAspect)
    }

    func testAutoFillsWhenAspectsAreClose() {
        // 16:9 video on a 16:10 display keeps 90% of the frame — not worth bars.
        let sixteenTen = CGSize(width: 2560, height: 1600)
        XCTAssertEqual(VideoPresentation.gravity(.auto, video: sixteenNine, in: sixteenTen), .resizeAspectFill)
        XCTAssertEqual(VideoPresentation.gravity(.auto, video: ultrawide, in: ultrawide), .resizeAspectFill)
    }

    func testAutoFillsUntilTheTrackSizeIsKnown() {
        XCTAssertEqual(VideoPresentation.gravity(.auto, video: nil, in: ultrawide), .resizeAspectFill)
    }

    func testManualModesIgnoreAspectRatios() {
        XCTAssertEqual(VideoPresentation.gravity(.fill, video: sixteenNine, in: ultrawide), .resizeAspectFill)
        XCTAssertEqual(VideoPresentation.gravity(.fit, video: ultrawide, in: ultrawide), .resizeAspect)
    }

    /// `.smart` on a mismatch auto would letterbox: equal parts crop and blurred bar,
    /// rather than all of one or all of the other.
    func testSmartSplitsTheDifference() {
        let zoom = VideoPresentation.zoom(.smart, video: sixteenNine, in: ultrawide)
        let fill = VideoPresentation.visibleFraction(video: sixteenNine, in: ultrawide)
        let kept = 1 / zoom          // fraction of the frame still on screen
        let covered = zoom * fill    // fraction of the display the video reaches
        XCTAssertEqual(kept, covered, accuracy: 0.001)
        XCTAssertEqual(kept, 0.707, accuracy: 0.001) // √0.5 — better than either extreme
        XCTAssertGreaterThan(kept, fill)             // crops less than Fill
        XCTAssertGreaterThan(covered, fill)          // covers more than Fit
    }

    func testSmartCoversTheDisplayWhenThatCostsLessThanTheThreshold() {
        let sixteenTen = CGSize(width: 2560, height: 1600)
        let fill = VideoPresentation.visibleFraction(video: sixteenNine, in: sixteenTen)
        // Exactly the aspect-fill zoom: full cover, and nothing for a backdrop to fill.
        XCTAssertEqual(VideoPresentation.zoom(.smart, video: sixteenNine, in: sixteenTen), 1 / fill, accuracy: 0.001)
        XCTAssertEqual(VideoPresentation.zoom(.smart, video: ultrawide, in: ultrawide), 1, accuracy: 0.001)
    }

    func testOnlySmartZooms() {
        for mode in FillMode.allCases where mode != .smart {
            XCTAssertEqual(VideoPresentation.zoom(mode, video: sixteenNine, in: ultrawide), 1, "\(mode)")
        }
        // Until the track size is known there is nothing to compute from: fill, no zoom.
        XCTAssertEqual(VideoPresentation.zoom(.smart, video: nil, in: ultrawide), 1)
        XCTAssertEqual(VideoPresentation.gravity(.smart, video: nil, in: ultrawide), .resizeAspectFill)
    }

    func testLockScreenPathsSitOutsideTheSandboxContainer() {
        // The screen saver resolves these from its own (sandboxed) process; if this
        // ever starts pointing at a container, the saver silently plays nothing.
        XCTAssertTrue(LockScreenLibrary.videoURL.path.hasSuffix("/Library/Application Support/W4llsky/LockScreen.mp4"))
        XCTAssertFalse(LockScreenLibrary.videoURL.path.contains("/Library/Containers/"))
    }
}

/// The screen saver selection lives in an undocumented Apple plist; this pins the
/// tree walk that finds every place a screen saver can be chosen, because missing
/// one of them would make the menu claim a selection that isn't really in effect.
final class SystemScreenSaverTests: XCTestCase {

    /// Same shape as ~/Library/Application Support/com.apple.wallpaper/Store/Index.plist:
    /// Idle nodes hang off the global entry, each display, and each Space.
    private func makeStore(provider: String, configuration: Data) -> [String: Any] {
        let idle: [String: Any] = ["Content": ["Choices": [["Provider": provider, "Configuration": configuration, "Files": []]]]]
        let desktop: [String: Any] = ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image", "Files": []]]]]
        return [
            "AllSpacesAndDisplays": ["Idle": idle, "Desktop": desktop, "Type": "idle"],
            "Displays": ["UUID-1": ["Idle": idle, "Desktop": desktop]],
            "Spaces": ["": ["Default": ["Idle": idle], "Displays": ["UUID-1": ["Idle": idle]]]],
            "SystemDefault": ["Idle": idle, "Desktop": desktop],
        ]
    }

    func testFindsEveryIdleSlotAtEveryDepth() {
        let store = makeStore(provider: "default", configuration: Data())
        XCTAssertEqual(SystemScreenSaver.choices(in: store, slot: SystemScreenSaver.idleSlot).count, 5)
    }

    func testIgnoresDesktopWallpaperChoices() {
        let store = makeStore(provider: "default", configuration: Data())
        let providers = SystemScreenSaver.choices(in: store, slot: SystemScreenSaver.idleSlot).compactMap { $0["Provider"] as? String }
        XCTAssertFalse(providers.contains("com.apple.wallpaper.choice.image"))
    }

    /// Writing the Desktop slot is what puts the video on the lock screen, so it has to
    /// reach every node and leave the other slot alone — and it has to drop the previous
    /// provider's options, which WallpaperAgent would otherwise decode against ours.
    func testWritingOneSlotLeavesTheOtherAlone() {
        var store = makeStore(provider: "default", configuration: Data())
        store["Displays"] = ["UUID-1": ["Idle": ["Content": ["Choices": [["Provider": "default"]]]],
                                        "Desktop": ["Content": ["Choices": [["Provider": "com.apple.wallpaper.choice.image"]],
                                                                "EncodedOptionValues": Data([1, 2, 3])]]]]
        let mine: [String: Any] = ["Provider": SystemScreenSaver.choiceProvider]
        let updated = SystemScreenSaver.replacingChoices(in: store, slot: SystemScreenSaver.desktopSlot, with: mine)

        let desktop = SystemScreenSaver.choices(in: updated, slot: SystemScreenSaver.desktopSlot)
        XCTAssertEqual(desktop.count, 3)
        XCTAssertTrue(desktop.allSatisfy { $0["Provider"] as? String == SystemScreenSaver.choiceProvider })

        let idle = SystemScreenSaver.choices(in: updated, slot: SystemScreenSaver.idleSlot)
        XCTAssertEqual(idle.count, 5)
        XCTAssertTrue(idle.allSatisfy { $0["Provider"] as? String == "default" })

        let display = ((updated["Displays"] as? [String: Any])?["UUID-1"] as? [String: Any])
        let content = (display?["Desktop"] as? [String: Any])?["Content"] as? [String: Any]
        XCTAssertEqual(content?["EncodedOptionValues"] as? String, "$null")
    }
}
