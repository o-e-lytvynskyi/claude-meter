#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  uninstall.sh  —  Remove ClaudeMeter from /Applications
#  Usage:  ./uninstall.sh [--clean]
#            --clean  also drops a .build/ left behind by ./install.sh --dev
# ─────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="ClaudeMeter"
BUNDLE_ID="dev.local.claude-meter"
INSTALL_DIR="/Applications"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "→ Stopping $APP_NAME …"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    sleep 1
    pkill -x "$APP_NAME" 2>/dev/null || true
fi

# Lid sleep back on if the app left it off, while the binary is still there.
if [ -x "$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" ]; then
    "$INSTALL_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" --login-item off >/dev/null 2>&1 || true
fi
if pmset -g | grep -qE '^ *SleepDisabled[[:space:]]+1'; then
    sudo -n /usr/bin/pmset -a disablesleep 0 2>/dev/null && echo "   ✓ lid sleep restored" || true
fi

# The sudoers rule the app installs on first lid-sleep switch.
if [ -e /etc/sudoers.d/claude-meter ]; then
    echo "→ Removing /etc/sudoers.d/claude-meter (asks for your password) …"
    sudo rm -f /etc/sudoers.d/claude-meter
fi

rm -rf "$HOME/Library/Application Support/$APP_NAME"

if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
    echo "→ Removing $INSTALL_DIR/$APP_NAME.app …"
    rm -rf "$INSTALL_DIR/$APP_NAME.app"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
else
    echo "   $INSTALL_DIR/$APP_NAME.app not found, skipping"
fi

defaults delete "$BUNDLE_ID" 2>/dev/null || true

if [[ "${1:-}" == "--clean" ]]; then
    rm -rf .build .swiftpm
    echo "   ✓ removed .build/ and .swiftpm/"
fi

echo ""
echo "✅  $APP_NAME uninstalled"
