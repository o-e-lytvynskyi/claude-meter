#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
#  install.sh  —  Build ClaudeMeter.app and install it to /Applications
#
#  Everything intermediate (SwiftPM scratch dir, icon source, .iconset,
#  the assembled bundle) lives in a temp dir and is removed on exit.
#  The repo is left exactly as it was found.
#
#  Usage:  ./install.sh [--debug] [--dev]
#            --debug  build the debug configuration
#            --dev    keep the SwiftPM scratch dir in .build/ for fast rebuilds
# ─────────────────────────────────────────────────────────────
set -euo pipefail

APP_NAME="ClaudeMeter"
BUNDLE_ID="dev.local.claude-meter"
VERSION="1.0"
MIN_MACOS="14.0"
INSTALL_DIR="/Applications"

# Command Line Tools 27 default to the macOS 27 SDK, where SwiftUI's @State is
# a macro whose plugin ships only with Xcode. The 26 SDK sits next to it.
SDK_26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
[ -d "$SDK_26" ] && export SDKROOT="$SDK_26"

CONFIG="release"
SCRATCH=""

for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG="debug" ;;
        --dev)   SCRATCH="keep" ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

WORK="$(mktemp -d "/tmp/${APP_NAME}-build.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ "$SCRATCH" = "keep" ]; then
    SCRATCH_PATH="$SCRIPT_DIR/.build"
else
    SCRATCH_PATH="$WORK/spm"
fi

APP_BUNDLE="$WORK/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"

# ── Build ─────────────────────────────────────────────────────────────────
echo "→ Building ($CONFIG) …"
swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH"
BINARY="$(swift build -c "$CONFIG" --scratch-path "$SCRATCH_PATH" --show-bin-path)/$APP_NAME"

# ── Icon ──────────────────────────────────────────────────────────────────
echo "→ Rendering icon …"
swift tools/make_icon.swift "$WORK/icon.png" >/dev/null
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for SIZE in 16 32 64 128 256 512; do
    sips -z $SIZE $SIZE "$WORK/icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null 2>&1
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$WORK/icon.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null 2>&1
done
iconutil -c icns -o "$WORK/AppIcon.icns" "$ICONSET"

# ── Assemble bundle ───────────────────────────────────────────────────────
echo "→ Assembling $APP_NAME.app …"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BINARY" "$CONTENTS/MacOS/$APP_NAME"
cp "$WORK/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>               <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>        <string>$APP_NAME</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>     <string>$MIN_MACOS</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSPrincipalClass</key>           <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null 2>&1

# ── Replace the installed copy ────────────────────────────────────────────
if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
    echo "→ Stopping running $APP_NAME …"
    osascript -e "tell application \"$APP_NAME\" to quit" 2>/dev/null || true
    sleep 1
    pkill -x "$APP_NAME" 2>/dev/null || true
fi

echo "→ Installing to $INSTALL_DIR …"
rm -rf "$INSTALL_DIR/$APP_NAME.app"
cp -R "$APP_BUNDLE" "$INSTALL_DIR/"
codesign --force --deep --sign - "$INSTALL_DIR/$APP_NAME.app" >/dev/null 2>&1

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$INSTALL_DIR/$APP_NAME.app" 2>/dev/null || true
touch "$INSTALL_DIR/$APP_NAME.app"

# ── Launch ────────────────────────────────────────────────────────────────
open "$INSTALL_DIR/$APP_NAME.app"

echo ""
echo "✅  $APP_NAME installed and running — look for the icon in the menu bar."
[ "$SCRATCH" = "keep" ] && echo "    (.build/ kept for --dev rebuilds; ./uninstall.sh --clean removes it)"
exit 0
