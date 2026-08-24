# W4llsky

Live video wallpapers for macOS, from the menu bar. Point it at an `.mp4`, pick a
display, done — and the same video can be your lock screen.

Menu-bar only: no Dock icon, no windows unless you ask for one.

## Requirements

- macOS 26.5 or later (the lock-screen path relies on macOS 26's wallpaper agent)
- Apple Silicon or Intel
- A local video file — `.mp4` / `.mov`. It is never copied off your Mac.

## Install

Grab `W4llsky.zip` from [Releases](../../releases), unzip, drag `W4llsky.app` to
`/Applications`.

The build is ad-hoc signed, not notarized, so Gatekeeper will block the first
launch. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/W4llsky.app
```

Then open it. A `▶` icon appears in the menu bar — that is the whole UI.

## Using it

### Desktop wallpaper

**Displays → *your display* → Choose Video…** — pick an mp4. It starts playing
immediately, behind your desktop icons, and comes back on its own after a
restart. Every connected display gets its own entry and its own video.

- **Scaling** — `Fill (crop)` is the default: the video covers the whole display,
  cropping whatever doesn't fit. `Smart (crop a little)` covers the display too
  whenever that costs little, and otherwise splits the difference — a 16:9 clip on
  a 32:9 ultrawide keeps 71% of the frame *and* covers 71% of the screen, with the
  rest as blurred bars, instead of losing half of one or the other. `Fit (no crop)`
  never crops. `Auto (fill or fit)` picks one of those two extremes: fill, unless
  it would crop away more than 15%.
- **Remove Wallpaper** — back to your normal desktop picture.
- **Playback Speed** — 0.5× / 1× / 1.5× / 2×, applies to every display.
- **Pause Wallpapers** — freezes every video without unloading it.

### Lock screen

macOS 26 draws the lock screen from the *desktop wallpaper* slot, so the reliable
way to get video there is to let W4llsky be the system wallpaper:

1. **Lock Screen → Choose Video…** — pick the video (usually the same one).
2. **Lock Screen → Play on the Lock Screen** — turns it on.

That's it. Lock the Mac any way you like — Apple menu, Control Center, closing
the lid — and the video is there.

Use the **same** video here and on your displays. When they differ, W4llsky's own
window covers the system wallpaper, macOS stops the copy it can't see, and locking
has to cold-start the decoder in front of you — the video stutters for the first
second or two. The menu warns you when that's the case.

**Screen-saver fallback.** If you'd rather run it as a classic screen saver
instead, leave *Play on the Lock Screen* off and use **Enable W4llsky Screen
Saver** — that installs the saver and opens Wallpaper settings, where you select
**W4llsky** under *Other*. macOS has no API for that selection, so the one click
is yours; the menu reports whether it took.

The catch is worth knowing: locking the Mac by hand does **not** start a screen
saver — macOS records that you asked for a lock and shows the static lock screen.
Only starting the saver *first* works, so W4llsky offers the two gestures that do:

- **⌃⌘Q Plays the Video** — claims ⌃⌘Q and starts the video, which locks behind itself.
- **Hot Corner Plays the Video** — the same thing with a corner of the screen.

These items disappear while *Play on the Lock Screen* is on, because they do
nothing there.

### The rest

- **CPU / Memory** — W4llsky's own usage, sampled the moment you open the menu
  (there is no background timer).
- **Launch at Login** — registers with macOS via `SMAppService`.

## Resource use

Built to idle: no polling, no timers, no render loop. AVFoundation and Core
Animation do the work, players stop when their window is fully covered, and the
menu is the only thing that ever samples stats. A covered wallpaper decodes
nothing at all.

## Build from source

Needs a full Xcode 26 install (not just Command Line Tools):

```bash
xcodebuild -project W4llsky.xcodeproj -scheme W4llsky -configuration Release build
```

CI does the same on every push to `main`; pushing a `v*` tag builds, zips and
publishes a GitHub release — see [.github/workflows/release.yml](.github/workflows/release.yml).

```bash
git tag v1.0.0 && git push origin v1.0.0
```

Architecture notes, and the reasoning behind the load-bearing details, live in
[CLAUDE.md](CLAUDE.md).
