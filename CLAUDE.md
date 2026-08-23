# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

W4llsky is a native macOS Swift app (SwiftUI + AppKit) that plays local `.mp4` files as
per-display dynamic wallpapers, controlled entirely from a menu bar item. It ships a
second product, `W4llsky.saver`, which plays the same kind of video on the lock
screen/idle screen. It's an MVP: only the Dynamic Wallpaper feature exists. The architecture is meant to grow into a small
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

There are two products: `W4llsky.app` and the `W4llskySaver` target's `W4llsky.saver`,
which is copied into the app's `Contents/PlugIns` by an "Embed Screen Saver" phase.
`Shared/` is compiled into *both* targets (it's listed in both targets'
`fileSystemSynchronizedGroups`) — that's the only code the app and the saver have in
common, and nothing target-specific belongs in it.

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
Shared/                 compiled into the app AND the screen saver:
                          VideoPresentation (FillMode + scaling math + blurred backdrop),
                          WallpaperContentView (layer host), WallpaperPlayer (AVQueuePlayer/
                          AVPlayerLooper/AVPlayerLayer wrapper), LockScreenLibrary (the
                          handoff file both processes read)
W4llskySaver/           W4llskySaverView — the .saver bundle's principal class
App/                    AppDelegate: wires everything together, no logic of its own
Core/
  Display/              DisplaySnapshot (value type) + DisplayObserver
  Performance/           AppResourceMonitor (self CPU%/RSS via mach task/thread info)
  Persistence/           WallpaperStore (Codable config in UserDefaults), SecurityScopedBookmark,
                          LaunchAtLogin (SMAppService wrapper)
Features/
  DynamicWallpaper/      DesktopWindow, WallpaperEngine (owns window+player per display id)
  LockScreen/            ScreenSaverInstaller (copies the .saver into ~/Library/Screen Savers)
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
used uniformly for pause/resume and the menu's playback-speed picker. `WallpaperPlayer`
keeps one KVO on `timeControlStatus` to re-assert a non-zero rate: AVPlayer drops a rate
set before the item is ready, and can fall back to 0 after display sleep.

### Scaling (why a video looks right on any display)

`AVPlayerLayer` is *not* added to a window's content view directly — `WallpaperContentView`
owns it, plus a backdrop layer, and re-syncs `frame` **and `contentsScale`** on every
geometry/backing change inside a `CATransaction` with actions disabled. Manually added
sublayers inherit neither: a sublayer left at `contentsScale = 1` renders the video at half
resolution on a Retina display, and an un-synced frame animates into place over 0.25s on
every resolution change.

`FillMode` (per display, and one for the lock screen) picks the gravity:
`.fill` crops, `.fit` letterboxes, and the default `.auto` computes how much of the frame
an aspect-fill would keep (`VideoPresentation.visibleFraction`) and letterboxes below 85%.
That's what stops a 16:9 clip from losing half its frame on a 5120×1440 ultrawide. When it
letterboxes, the bars are filled with one blurred still frame of the video — generated once
via `AVAssetImageGenerator` + Core Image, then static, so there is no second decode
pipeline. The decision is re-run on every reposition, since a resolution change can flip it.

### Sleep and wake

Display sleep (and system sleep) leaves the wallpaper's `AVPlayerLayer` attached to a
surface that no longer exists: the player keeps decoding, but CoreMedia reports
`enqueued: 12, displayed: 0` and the window renders nothing, so the system's desktop
picture shows through again and the wallpaper looks like it reverted. The rate KVO can't
catch this — playback never stopped.

`AppDelegate` observes `NSWorkspace.screensDidWakeNotification` and
`.didWakeNotification` and calls `WallpaperEngine.handleWake()`, which re-attaches each
player to its layer (`layer.player = nil` then back), re-runs the fill decision, re-applies
the rate and re-orders the window front. Verified across two display-sleep cycles: a fresh
CoreMedia context takes over with `displayed` back at ~180 per 6s dump (30 fps).

### Lock screen

macOS exposes no public way to draw on the lock screen, so the supported path is a screen
saver: `W4llskySaver` builds `W4llsky.saver`, the app embeds it, and
`ScreenSaverInstaller` copies it to `~/Library/Screen Savers`.

**Installing is only half of it** — that just puts the saver in the list; macOS runs
whatever is *selected*, and a saver that is installed but not selected does nothing at all.
That was the original "lock screen doesn't work" bug, and it hid behind a second one: the
app opened `x-apple.systempreferences:com.apple.Screen-Saver-Settings.extension`, and
**macOS 26 has no Screen Saver pane** — screen savers moved into Wallpaper settings
(`com.apple.Wallpaper-Settings.extension`; the Lock Screen pane holds the idle timer).
An unknown pane id silently opens General, so the instructions pointed nowhere.

Selecting a screen saver has no API. Since macOS 14 the choice lives in WallpaperAgent's
store, `~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`, in every
`Idle` node (global, per Space, per display). **Writing it does not work and was removed** —
the agent decodes each choice's `Configuration` blob with a private Codable type, and every
shape reconstructed from `ScreenSaverModule.dictionaryRepresentation` (`moduleName`/`path`/
`type`, `name`/`displayName`/`path`, bare name, path in `Files`) was rejected: running the
saver kept launching `WallpaperAerialsExtension`, the system default, instead of
`legacyScreenSaver`. Don't try again without a known-good sample to copy — select a legacy
saver in the UI first and diff that file.

So the selection stays the user's one click, and `SystemScreenSaver` only *reads* the store
to report whether it happened (matching the provider plus "W4llsky" anywhere in the choice's
bytes, so it survives whatever shape Apple encodes). The menu says
"Selected in macOS: NO" rather than pretending, and "Test Now" launches
`ScreenSaverEngine.app` so the result is visible immediately.

The picker lives in **Wallpaper settings** (`com.apple.Wallpaper-Settings.extension`,
anchor `?screenSaver`), not a Screen Saver pane — that pane no longer exists in macOS 26.
Third-party savers appear there under **Other**; `WallpaperLegacyExtension`'s own
localized strings (`OTHER`, `DELETE_CONTEXT_MENU_ITEM`) are for exactly that section.

A legacy saver with no `Contents/Resources/thumbnail.png` gets a blank tile —
`-[ScreenSaverModule thumbnail]` reads that one file (verified: adding it flips the API
from nil to an image), so `W4llskySaver/thumbnail.png` ships in the bundle. Note the
file-system-synchronized group only picks a new resource up on a **clean** build of the
saver target.

`ScreenSaverModule` (private, in ScreenSaver.framework) is the system's own validator:
`moduleWithPath:` on our bundle returns `isScreenSaver=1, isCompatibleWithCurrentArch=1`,
which is what makes it appear in the picker. `canRunAtLoginWindow` is 0 for anything not
signed by Apple — our saver runs for the idle/locked session, not at the pre-login window.

### The lock screen is the *desktop wallpaper*, not a screen saver

macOS 26 does not draw the lock screen background itself. The instant loginwindow locks,
it takes a WallpaperAgent assertion — `Take Assertion 303: display: …, contentType:
desktop` — so what sits behind the password field is whatever the **Desktop** slot of
WallpaperAgent's store resolves to. That is the whole trick other live-wallpaper apps use
("registers it with the system for both the desktop and lock screen"), and it is why they
all require macOS 26: before it, that assertion didn't exist.

So the same `com.apple.wallpaper.choice.screen-saver` choice we already write into every
`Idle` node goes into every `Desktop` node instead, and macOS plays our `.saver` as the
wallpaper — on the desktop *and* on the lock screen, with none of the screen-saver
machinery below: no hot key, no idle timer, no `_lockReqestedBy` gate, and it survives
locking the Mac any way at all. `SystemScreenSaver.useAsDesktopWallpaper(_:bundlePath:)`
does it, stashing the choice it replaced so switching back restores the user's own
wallpaper instead of a default picture.

The store walkers are shared: `choices(in:slot:)` and `replacingChoices(in:slot:with:)`
take `idleSlot` / `desktopSlot`. A `Desktop` slot also carries `EncodedOptionValues` for
whatever provider it used to hold, which must be cleared, or WallpaperAgent decodes the
old provider's options against the new one.

The `.image` provider is no shortcut here: `WallpaperImageExtension` only understands
`type: "imageFile"` and has no video path at all, so pointing it at an mp4 is not an
option. Apple's own video wallpapers go through `com.apple.wallpaper.choice.aerials`,
whose configuration names an asset in the root-owned `com.apple.idleassetsd` catalog
(`/Library/Application Support/com.apple.idleassetsd/Aerial.sqlite`) — adding to it needs
admin rights, which our own `.saver` avoids entirely.

### Who draws what, and why it matters for CPU

There is no separate lock-screen content: WallpaperKit only has `contentType: desktop`
and `contentType: screenSaver`. So once the video is the system wallpaper, **the lock
screen video and the desktop video are necessarily the same file** — there is no
arrangement in which they differ.

That makes overlap the thing to avoid. When the same video is both the system wallpaper
and a display's assignment, `AppDelegate.reconcile` skips creating our own
`DesktopWindow` for it (`LockScreenLibrary.isSameFile(as:)`, compared by
`fileResourceIdentifierKey` — `install` hard-links the source, so paths differ but the
inode does not). Drawing our own copy over the system's would decode the file twice, and
worse: our window *covers* the system's copy, which macOS then throttles to ~1.5 fps
(measured: `enqueued: 8, displayed: 0`). The lock screen inherits that throttled pipeline
and has to spin it back up to 30 fps in front of the user — which is exactly what a
"the wallpaper stutters for the first two seconds after locking" report looks like. If a
display is deliberately given a *different* video, our window stays and so does that
cost; that is inherent, not a bug.

For the windows we do draw, `WallpaperEngine` observes
`NSWindow.didChangeOcclusionStateNotification` and stops the player when the window is
not `.visible`. Note AppKit only reports occlusion when the window is *fully* covered by
opaque windows, so a scattered desktop keeps playing (correctly — you can see it) and a
full-screen app stops it. Every path that can leave a player stopped re-derives the rate
from `rate(for:)` rather than restoring the last one — `handleWake`, `reposition` — so a
paused wallpaper can never stay paused just because nothing else happened to move.

`WallpaperPlayer` sets `automaticallyWaitsToMinimizeStalling = false`: the file is local,
there is nothing to buffer, and the default holds the first rate change back while
AVFoundation decides it has enough media — which reads as a video sitting on one frame
before it starts moving.

### What actually starts the screen saver (and what doesn't)

All of this governs the *screen saver* path only — the fallback for when the video is not
set as the wallpaper above. Locking the Mac does **not** start it, and — the finding that rules out every "just react
to the lock" idea — a manual lock also **blocks** it. `LWScreenLock` records *why* the
screen locked in `_lockReqestedBy`, and that value is what decides whether the shield
shows a saver or the static lock screen. A lock the user asked for is
`kLWLockFromDirectLock` (8); every screen-saver reason is lower
(`kLWLockFromScreenSaverIdleLaunch` = 3, `…OtherLaunch` = 4), and a lower request is
discarded — "requestedby:4 < _lockReqestedBy:8 so don't do anything. returning". It only
resets on unlock. So once the Mac is locked by hand:

- The idle timer refuses outright: "lockRequestedBy: 8 > screensaver, so do not launch
  screen saver", every tick until unlock. `idleDelay` therefore governs only an *unlocked*
  idle Mac; shortening it does nothing for a lock, however the daemon is prodded.
- `SACScreenSaverStartNow` is **accepted** and runs the byte-identical daemon sequence to a
  working idle launch (`_screenSaverStart:` → `_idleTimerCancel` → `_startEventMonitor` →
  `screenSaverDidFade`), yet nothing is ever drawn — the daemon never launches the saver
  itself, WallpaperAgent does, off the lock reason. It leaves the daemon reporting
  `screenSaverIsRunning = 1` forever, which no-ops the *next* real launch. Calling it from
  a `com.apple.screenIsLocked` observer is worse than useless; that watcher was tried,
  measured and removed twice. (The
  `-[LWScreenLock startScreenLock:] | _startLockTime already inited, exit` line it logs is
  a red herring — that is only the redundant lock step being skipped.)

Two side notes worth keeping: `ScreenSaverDaemon` re-reads `idleTime` on every check but
**only** on its own timer — writing the preference produces no log line at all. The one
call that makes it check off-schedule is `SACSetScreenSaverCanRun`, and passing the value
it already holds does the poke without the "saver already running tell it to stop" branch
that `false` takes.

That leaves exactly one way to get video on the lock screen: **start the saver first and
let it lock behind itself.** Two gestures do that, and W4llsky offers both — ⌃⌘Q via
`LockHotKey`, and macOS's own "Start Screen Saver" hot corner
(`kLWLockFromScreenSaverHotCornerActivation`), which `LockHotCorner` configures by writing
`wvous-<corner>-corner` = 5 in `com.apple.dock` and restarting the Dock. Locking any other
way — Apple menu, Control Center, a "Lock Screen" hot corner — is `kLWLockFromDirectLock`
and gets the static lock screen, with no code we can write that changes it.

Claiming ⌃⌘Q has exactly one route:
claim the shortcut before macOS does and start the saver instead, since starting the
saver locks the screen behind itself. `LockHotKey` registers ⌃⌘Q with Carbon's
`RegisterEventHotKey` (the only API that can consume a combination system-wide;
`NSEvent`'s global monitors observe but can't swallow, and need Accessibility).
`startNow()` calls `SACScreenSaverStartNow` in login.framework directly — 4 ms, versus
a few hundred to launch ScreenSaverEngine.app, which only forwards the same call — so
it wins the race; the app launch stays as the fallback.

Drawing over the lock screen ourselves is not an option: a window at
`CGShieldingWindowLevel()` still lands *below* loginwindow's shield (layers 2004/2001)
in the on-screen stack while locked, whatever level it claims.

The daemon also refuses while any display-sleep assertion is held:
"PMNoDisplaySleepEnabled so do not launch screen saver". **AVPlayer takes that assertion by
default for video**, so a playing wallpaper would keep the screen saver from ever starting
(and the display awake) — hence `preventsDisplaySleepDuringVideoPlayback = false` in
`WallpaperPlayer`. Check with `pmset -g assertions` when the saver mysteriously never runs.

Debugging note: killing `ScreenSaverEngine` with `killall` wedges loginwindow's
`ScreenSaverDaemon` — it keeps reporting `screenSaverIsRunning = 1` and every later start
no-ops with "Screen Saver Already Running; Exiting". Unlocking the session resets it.

The saver runs inside `legacyScreenSaver.appex`, which is **sandboxed**. It holds a
read-only exception for the whole filesystem, so it can read files anywhere, but TCC still
covers Desktop/Documents/Downloads and app-scoped bookmarks can't be passed between
processes. So `LockScreenLibrary` hard-links (falling back to a copy) the chosen video into
`~/Library/Application Support/W4llsky/LockScreen.mp4` with a small JSON sidecar, and both
processes agree on that path. `NSHomeDirectory()` is useless there — it resolves to the
saver's container — so the real home comes from `getpwuid(getuid())`.

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
