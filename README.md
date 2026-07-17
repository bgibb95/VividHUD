# VividHUD

A lightweight, native macOS menu-bar utility that shows a large, high-contrast
volume and brightness indicator in the center of your screen whenever you adjust
them — a more visible alternative to the small default macOS HUD.

- **Big & clear** — a centered dark-glass card with a large icon, progress bar,
  and percentage, styled for readability.
- **Always on top** — floats above full-screen apps and the menu bar, and is
  click-through so it never gets in your way.
- **Runs in the background** — no Dock icon; a small menu-bar item lets you
  control it. Starts automatically at login.
- **No special permissions** — no Accessibility access required.

## Requirements

- macOS 13 (Ventura) or newer.

## Install

1. Download / build `VividHUD.dmg` (see [Build from source](#build-from-source)).
2. Open the DMG and drag **VividHUD** onto the **Applications** shortcut.
3. First launch only: because the app is ad-hoc signed (free, not notarized),
   macOS shows a one-time warning. Right-click the app → **Open** → **Open**.

See [INSTALL.txt](INSTALL.txt) for the full step-by-step guide.

## Usage

Just press your volume or brightness keys — the HUD appears automatically.
Click the slider icon in the menu bar for:

- **Start at Login** — toggle automatic startup (on by default)
- **Test HUD** — show the overlay to confirm it works
- **Quit VividHUD**

## Build from source

```bash
./build.sh
```

This compiles [main.swift](main.swift), assembles `build/VividHUD.app`, ad-hoc
signs it, and produces `VividHUD.dmg`. Both are git-ignored build artifacts.

Quick compile-only check while iterating:

```bash
swiftc main.swift -o /tmp/vh_check -framework Cocoa -framework SwiftUI -framework CoreAudio
```

## Uninstall

Use the menu bar (uncheck *Start at Login* → *Quit*, then drag the app to Trash),
or run:

```bash
./uninstall.sh
```

## How it works

The entire app is a single file, [main.swift](main.swift):

- The HUD is an `NSPanel` (borderless, non-activating, `.screenSaver` level,
  click-through) hosting a SwiftUI view, shown via `HUDController`.
- **Volume** is detected with event-driven CoreAudio property listeners on the
  default output device (re-attaching when the default device changes).
- **Brightness** is read from the private DisplayServices framework (loaded via
  `dlopen`) and polled at 15 Hz.
- Auto-start uses `SMAppService`; a `--unregister` flag cleanly removes the
  login item.

See [CLAUDE.md](CLAUDE.md) for deeper architecture notes.

## Caveats

- **Not notarized** (ad-hoc signed) — hence the one-time Gatekeeper prompt on
  first launch. Ad-hoc signing is required for the app to run on Apple Silicon.
- **DisplayServices is a private API** — stable and fine for personal use, but
  App Store–ineligible, and it only reports the built-in / main display.
