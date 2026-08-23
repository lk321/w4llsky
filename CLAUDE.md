# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

W4llsky is a native macOS Swift app (SwiftUI + AppKit) that plays local `.mp4` files as
per-display dynamic wallpapers, controlled entirely from a menu bar item. It's an MVP:
only the Dynamic Wallpaper feature exists. The architecture is meant to grow into a small
Developer Toolkit (Clipboard Manager, QR Generator, System Monitor, ...) later, but no
scaffolding for those exists yet and none should be added speculatively.

Absolute priority order for any change: **stability → resource usage → macOS integration →
UX → features.** Never trade efficiency for a visual flourish. This app is meant to run for
many hours in the background with near-zero idle CPU/GPU/battery impact — no polling, no
permanent timers, no `CVDisplayLink`/render loop of our own (AVFoundation/Core Animation do
that work).

## Build / run / test

Requires a full Xcode install (not just Command Line Tools). If `xcode-select -p` points at
`CommandLineTools`, scope `DEVELOPER_DIR` per-command instead of changing the global selection:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

# Build
xcodebuild -project W4llsky.xcodeproj -scheme W4llsky -configuration Debug build

# Test (XCTest; no meaningful tests exist yet, just the template)
xcodebuild -project W4llsky.xcodeproj -scheme W4llsky -destination 'platform=macOS' test

# Run the built app via LaunchServices — NOT by exec'ing the binary directly.
# Direct exec from a shell has caused file-picker/sandbox-adjacent grants to misbehave
# during development; `open -a` launches through the normal process chain.
open -a "$(xcodebuild -project W4llsky.xcodeproj -scheme W4llsky -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ TARGET_BUILD_DIR /{print $2; exit}')/W4llsky.app"
```

Xcode uses **file-system-synchronized groups** (`PBXFileSystemSynchronizedRootGroup`) — dropping
a new `.swift` file into `App/`, `Core/`, or `Features/` on disk is enough; there's no need to
manually add it to `project.pbxproj`.

The app is a **menu-bar-only utility**: `NSApp.setActivationPolicy(.accessory)` is set in
`AppDelegate`, and there is deliberately no `WindowGroup` in `W4llskyApp` (a `WindowGroup`
auto-opens a window at launch regardless of activation policy). The main scene is an empty
`Settings {}` scene purely to satisfy the `App` protocol; the one real window (opened via
"Open W4llsky" in the menu) is created on demand by `MenuBarController` with a plain
`NSWindow` + `NSHostingView`, not a SwiftUI `Scene`.

## Architecture

Feature-first, deliberately flat — no DI framework, no repository/factory/service-locator
layers, no protocol abstractions except at real AppKit/AVFoundation boundaries.

```
App/                    AppDelegate: wires everything together, no logic of its own
Core/
  Display/              DisplaySnapshot (value type) + DisplayObserver
  Media/                WallpaperPlayer (AVQueuePlayer/AVPlayerLooper/AVPlayerLayer wrapper)
  Performance/           AppResourceMonitor (self CPU%/RSS via mach task/thread info)
  Persistence/           WallpaperStore (Codable config in UserDefaults), SecurityScopedBookmark,
                          LaunchAtLogin (SMAppService wrapper)
Features/
  DynamicWallpaper/      DesktopWindow, WallpaperEngine (owns window+player per display id)
  MenuBar/                MenuBarController — the entire UI lives here as an NSMenu
```

`Core/` must never know about a specific feature. `Features/DynamicWallpaper` must never
know about future tools (Clipboard, QR, SystemMonitor) — each future tool gets its own
`Features/<Tool>/` folder with no cross-dependencies. Don't create empty folders for tools
that don't exist yet.

### Wallpaper engine

One `DesktopWindow` (borderless `NSWindow`) + one `WallpaperPlayer` per display id, tracked
in `WallpaperEngine`'s two dictionaries keyed by a **persistent display id**
(`DisplaySnapshot.id`, derived from `CGDisplayCreateUUIDFromDisplayID`, not from
`NSScreen` object identity or the transient screen number — those change across
sleep/wake/reconnect). `AppDelegate` reconciles `WallpaperEngine` against
`DisplayObserver.current` on every `NSApplication.didChangeScreenParametersNotification`
(connect/disconnect/resolution/scale/main-display/arrangement/mirroring all funnel through
this one notification) — create windows for newly-connected displays with a saved
assignment, reposition existing ones, tear down windows for displays that vanished.
`NSScreen` references are never cached; always re-resolved via `DisplayObserver.screen(forID:)`.

The desktop window's level is the load-bearing detail:
`CGWindowLevelForKey(.desktopIconWindow) - 1` — one level below desktop icons, one above
the system's own desktop-picture window. Setting it to exactly `.desktopWindow` ties with
(and often loses to) macOS's own desktop picture layer and renders invisible.

Playback: `AVQueuePlayer` + `AVPlayerLooper` own the loop (no manual seek/timers). A single
`rate` property is the only control point — `0` = paused, `1` = normal, `>1` = sped up —
used uniformly for pause/resume and the menu's playback-speed picker.

### Menu bar

`MenuBarController` rebuilds the whole `NSMenu` in `menuNeedsUpdate(_:)`, right before it's
shown. This doubles as the performance-stats refresh (`AppResourceMonitor.sample()` is called
there) — there is intentionally no running `Timer`; stats are only ever computed when the
menu is about to be displayed.

### Sandbox status

App Sandbox is currently **disabled** (`ENABLE_APP_SANDBOX = NO`), and file bookmarks are
plain (non-security-scoped) — `SecurityScopedBookmark` despite its name no longer calls
`start/stopAccessingSecurityScopedResource`. This was a deliberate workaround: on the dev
machine, macOS's Powerbox (`com.apple.appkit.xpc.openAndSavePanelService`) failed to issue
sandbox extensions system-wide (confirmed via unrelated system daemons failing the same way,
surviving a reboot and logout/login), which made `bookmarkData(options: .withSecurityScope)`
fail with EPERM on every attempt. If re-enabling sandbox for distribution later, re-verify
this isn't still an issue and restore `.withSecurityScope` bookmarks +
`ENABLE_USER_SELECTED_FILES = readonly`.

### Concurrency

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set at the project level — types are
MainActor-isolated by default without explicit annotation. Exception: closures passed to
plain (non-Swift-concurrency) APIs like `NotificationCenter.addObserver(..., queue: .main) { }`
are *not* inferred as MainActor-isolated by the compiler even though they're guaranteed to
run on the main thread; wrap the body in `MainActor.assumeIsolated { }` rather than adding
`await`/restructuring.
