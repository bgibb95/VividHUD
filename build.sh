#!/bin/bash
#
# build.sh — compile VividHUD, package it as a .app, ad-hoc sign it,
#            and produce a drag-to-install DMG.
#
# Usage:   ./build.sh
# Output:  build/VividHUD.app   and   VividHUD.dmg
#
set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────────
APP_NAME="VividHUD"
BUNDLE_ID="com.vividhud.app"
VERSION="1.0"
MIN_MACOS="13.0"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RES_DIR="$CONTENTS/Resources"
DMG_PATH="$ROOT_DIR/$APP_NAME.dmg"

echo "▸ Cleaning previous build…"
rm -rf "$BUILD_DIR" "$DMG_PATH"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# ── 1. Compile ───────────────────────────────────────────────────────────
echo "▸ Compiling Swift…"
swiftc "$ROOT_DIR/main.swift" -O \
    -o "$MACOS_DIR/$APP_NAME" \
    -framework Cocoa -framework SwiftUI -framework CoreAudio
# (DisplayServices is loaded at runtime via dlopen — no -framework flag needed.)

# ── 2. Info.plist ────────────────────────────────────────────────────────
echo "▸ Writing Info.plist…"
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>          <string>AppIcon</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>$MIN_MACOS</string>
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>VividHUD</string>
</dict>
</plist>
PLIST

# ── 3. App icon (best-effort; skipped gracefully if tools unavailable) ────
echo "▸ Generating app icon…"
if command -v sips >/dev/null && command -v iconutil >/dev/null; then
    ICONSET="$BUILD_DIR/AppIcon.iconset"
    SRC_PNG="$BUILD_DIR/icon_src.png"
    mkdir -p "$ICONSET"

    # Draw a simple 1024px rounded gradient tile with a sun glyph using Swift.
    cat > "$BUILD_DIR/makeicon.swift" <<'SWIFT'
import Cocoa
let size = 1024.0
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let rect = NSRect(x: 0, y: 0, width: size, height: size)
let path = NSBezierPath(roundedRect: rect, xRadius: size*0.22, yRadius: size*0.22)
let grad = NSGradient(colors: [
    NSColor(calibratedRed: 0.16, green: 0.17, blue: 0.24, alpha: 1),
    NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.10, alpha: 1)])!
path.addClip()
grad.draw(in: rect, angle: -90)
if let sym = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: nil) {
    let cfg = NSImage.SymbolConfiguration(pointSize: size*0.5, weight: .semibold)
    let glyph = sym.withSymbolConfiguration(cfg)!
    let gw = size*0.62, gh = size*0.62
    let r = NSRect(x: (size-gw)/2, y: (size-gh)/2, width: gw, height: gh)
    NSColor(calibratedRed: 1, green: 0.78, blue: 0.30, alpha: 1).set()
    glyph.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
}
img.unlockFocus()
if let tiff = img.tiffRepresentation,
   let rep = NSBitmapImageRep(data: tiff),
   let png = rep.representation(using: .png, properties: [:]) {
    try? png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
SWIFT
    if swiftc "$BUILD_DIR/makeicon.swift" -o "$BUILD_DIR/makeicon" 2>/dev/null \
       && "$BUILD_DIR/makeicon" "$SRC_PNG" 2>/dev/null && [ -f "$SRC_PNG" ]; then
        for s in 16 32 64 128 256 512; do
            sips -z $s $s        "$SRC_PNG" --out "$ICONSET/icon_${s}x${s}.png"      >/dev/null
            sips -z $((s*2)) $((s*2)) "$SRC_PNG" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
        done
        iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
        echo "  icon created."
    else
        echo "  (icon generation skipped — app will use the default icon.)"
    fi
else
    echo "  (sips/iconutil not found — skipping icon.)"
fi

# ── 4. Ad-hoc code signing ───────────────────────────────────────────────
echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP"
codesign -dv "$APP" 2>&1 | grep -E "Signature|Identifier" || true

# ── 5. Build the DMG ─────────────────────────────────────────────────────
echo "▸ Building DMG…"
STAGE="$BUILD_DIR/dmg_stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[ -f "$ROOT_DIR/INSTALL.txt" ] && cp "$ROOT_DIR/INSTALL.txt" "$STAGE/"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO \
    "$DMG_PATH" >/dev/null

echo ""
echo "✅ Done."
echo "   App:  $APP"
echo "   DMG:  $DMG_PATH"
