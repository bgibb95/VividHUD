# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

VividHUD — a background macOS menu-bar agent that shows a large, custom volume/brightness
HUD in the center of the screen when those keys are pressed. Everything is in a single Swift
file, [main.swift](main.swift). There is **no Xcode project and no Swift Package** — the app
is compiled with `swiftc` and hand-assembled into a `.app` bundle by [build.sh](build.sh).

## Commands

```bash
./build.sh            # compile main.swift -> build/VividHUD.app, ad-hoc sign, build VividHUD.dmg
./uninstall.sh        # quit app, remove its login item, delete from /Applications & ~/Applications

# Fast compile-only check (no bundling) while iterating:
swiftc main.swift -o /tmp/vh_check -framework Cocoa -framework SwiftUI -framework CoreAudio

# Remove the "start at login" entry without the UI (used by uninstall.sh):
build/VividHUD.app/Contents/MacOS/VividHUD --unregister
```

There are no tests. `build/` and `VividHUD.dmg` are generated artifacts.

### The edit → see-it-work loop
`build.sh` recompiles `main.swift`; source edits do nothing until it runs. A rebuild does **not**
restart a running instance and does **not** update a copy already in `/Applications` — quit the
running app and relaunch `build/VividHUD.app` (or re-install from the fresh DMG).

## Architecture

The whole app is `main.swift`, organized as a handful of classes wired together in
`AppDelegate`:

- **Entry point** is top-level code at the bottom of the file (not `@main`). It intercepts the
  `--unregister` flag *before* creating `NSApplication`, then runs the normal app.
- **`HUDController`** owns the overlay: an `NSPanel` (borderless, `.nonactivatingPanel`,
  `.screenSaver` level, click-through, all-Spaces/full-screen collection behavior) hosting the
  SwiftUI **`HUDView`** via `NSHostingView`. It drives fade-in / 1.5s-then-fade-out and centers
  the panel on show.
- **`HUDState`** is the `ObservableObject` bridge — monitors mutate it, `HUDView` renders it.
- **`VolumeMonitor`** — event-driven CoreAudio. Adds `AudioObjectPropertyListenerBlock`s for
  volume + mute on the default output device, and *also* listens for default-device changes to
  re-attach (headphones plugged in, etc.).
- **`BrightnessMonitor`** — reads brightness from the **private DisplayServices framework**
  (`DisplayServicesGetBrightness`, loaded via `dlopen`, so no `-framework` link flag) and
  **polls at 15Hz** to catch the ramp. Only reads the built-in/main display.
- **`AppDelegate`** — sets `.accessory` activation (no Dock icon), registers the login item,
  builds the `NSStatusItem` menu (Start at Login / Test HUD / Quit), and starts both monitors.

## Non-obvious constraints (read before editing)

- **Login items use `SMAppService.mainApp`** (macOS 13+ baseline). An entry can only be removed
  by the app's *own* signed binary — hence the `--unregister` flag exists and `uninstall.sh`
  relies on it. Don't expect to clear it from an arbitrary script.
- **Ad-hoc signing is mandatory**, not cosmetic: `codesign --sign -` in `build.sh` is required
  for the app to run at all on Apple Silicon. It is *not* notarized, so first launch triggers a
  Gatekeeper warning (documented for users in [INSTALL.txt](INSTALL.txt)).
- **The HUD window (356pt) is deliberately larger than the card (260pt).** The extra 48pt
  transparent margin exists so the drop shadow isn't clipped square by the window bounds. If you
  change the card size, shadow radius, or padding, keep the window/hosting frame and the
  `.padding(48)` in sync or the square-shadow bug returns.
- **DisplayServices is a private API.** It's stable and fine for personal use but would be
  rejected from the App Store, and only reports the built-in display.

## Testing / verification gotchas

- Launching the dev build registers a login item pointing at the **dev `build/` path**. Always
  clean up afterward with `... /VividHUD --unregister` so a stray dev copy doesn't auto-start.
- Trigger the HUD programmatically for testing via `osascript -e "set volume output volume 45"`
  (fires the CoreAudio listener). Brightness has no easy scripted trigger.
- `screencapture` returns black unless the invoking process has Screen Recording permission —
  don't rely on it to visually verify the HUD from a plain shell.
