#!/bin/bash
#
# uninstall.sh — cleanly remove VividHUD.
#
# Steps: quit the running app → remove its "start at login" entry →
#        delete the app from /Applications.
#
# Usage:  ./uninstall.sh
#
set -uo pipefail

APP_NAME="VividHUD"
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Candidate locations, most-preferred first.
CANDIDATES=(
    "/Applications/$APP_NAME.app"
    "$HOME/Applications/$APP_NAME.app"
    "$ROOT_DIR/build/$APP_NAME.app"
)

echo "▸ Quitting $APP_NAME (if running)…"
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
sleep 1
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1

# ── Remove the login item ────────────────────────────────────────────────
# SMAppService entries can only be removed by the app's own binary, so we run
# it with --unregister before deleting the bundle.
UNREGISTERED=false
for APP in "${CANDIDATES[@]}"; do
    BIN="$APP/Contents/MacOS/$APP_NAME"
    if [ -x "$BIN" ]; then
        echo "▸ Removing login item via: $APP"
        "$BIN" --unregister || true
        UNREGISTERED=true
        break
    fi
done

if [ "$UNREGISTERED" = false ]; then
    echo "▸ No app bundle found to unregister the login item."
    echo "  If a stale 'VividHUD' entry remains, remove it under:"
    echo "  System Settings > General > Login Items."
fi

# ── Delete the app bundle(s) ─────────────────────────────────────────────
REMOVED_ANY=false
for APP in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
    if [ -d "$APP" ]; then
        echo "▸ Deleting $APP"
        rm -rf "$APP" && REMOVED_ANY=true
    fi
done

if [ "$REMOVED_ANY" = false ]; then
    echo "▸ No installed copy found in /Applications or ~/Applications."
    echo "  (The dev build in ./build was left in place — delete it manually if desired.)"
fi

echo ""
echo "✅ $APP_NAME uninstalled."
