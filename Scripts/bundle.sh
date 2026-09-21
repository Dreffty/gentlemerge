#!/bin/sh
# Assembles GentleMerge.app around the SwiftPM binary.
#
# A bundle is not cosmetic here: UserNotifications refuses to work without a
# bundle identifier, and macOS attributes Automation permission (for focusing a
# terminal tab) to the bundle rather than the executable.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${CONFIG:-release}
VERSION=${VERSION:-0.1.0}
APP="$ROOT/build/GentleMerge.app"

cd "$ROOT"
swift build -c "$CONFIG" --product gentlemerge
BINARY=$(swift build -c "$CONFIG" --show-bin-path)/gentlemerge

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/gentlemerge"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GentleMerge</string>
    <key>CFBundleDisplayName</key><string>GentleMerge</string>
    <key>CFBundleIdentifier</key><string>dev.gentlemerge.app</string>
    <key>CFBundleExecutable</key><string>gentlemerge</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no window on launch. -->
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>GentleMerge focuses the terminal tab an agent is waiting in, and can type your reply into that session.</string>
    <key>NSHumanReadableCopyright</key><string>Local-only. Nothing leaves this machine.</string>
</dict>
</plist>
PLIST

# Signed with CODESIGN_IDENTITY when set, ad-hoc (`-`) otherwise: enough for
# notifications and Automation prompts to attach to a stable identity on this
# machine. Empty on purpose for public builds with no identity at hand.
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
codesign --force --sign "$CODESIGN_IDENTITY" --identifier dev.gentlemerge.app "$APP" >/dev/null 2>&1 ||
    echo "warning: could not codesign (notifications may not appear)" >&2

echo "$APP"
