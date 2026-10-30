#!/bin/zsh
# Builds /Applications/SynoShare.app without Xcode: SwiftPM build in a separate
# scratch path (never touches .build/, which the CLI may be running from),
# assembles the bundle in place, and ad-hoc signs it (no Developer ID; DECISIONS #4).
# Set APP_PATH to build somewhere else.
set -euo pipefail

ROOT="${0:A:h:h}"
SCRATCH="$ROOT/.build-app"
APP="${APP_PATH:-/Applications/SynoShare.app}"

if pgrep -xq SynoShare; then
    echo "error: SynoShare is running. Quit it (stop any download) before rebuilding." >&2
    exit 1
fi
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"

echo "==> Building SynoShareApp ($CONFIG, scratch path $SCRATCH)"
swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG" \
    --product SynoShareApp --arch arm64
BIN_DIR="$(swift build --package-path "$ROOT" --scratch-path "$SCRATCH" -c "$CONFIG" --arch arm64 --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/SynoShareApp" "$APP/Contents/MacOS/SynoShare"
swift "$ROOT/scripts/make-icon.swift" "$ROOT/assets/AppIcon.svg" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleDisplayName</key><string>SynoShare</string>
    <key>CFBundleExecutable</key><string>SynoShare</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>local.synoshare.app</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>SynoShare</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Ad-hoc signing"
codesign --force --deep -s - "$APP"
codesign --verify --strict "$APP"

echo "==> Built $APP"
