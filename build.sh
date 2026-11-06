#!/usr/bin/env bash
# Builds Murmur.app. Pass --install to copy it into /Applications, or
# --dmg to produce a drag-to-install disk image under dist/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Murmur"
BUNDLE_ID="com.murmur.dictation"
VERSION="1.2.1"
APP="$ROOT/dist/$APP_NAME.app"

echo "==> Building release binary"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/$APP_NAME"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
strip -rSTx "$APP/Contents/MacOS/$APP_NAME" 2>/dev/null || true

echo "==> Generating icon"
swift "$ROOT/Tools/make-icon.swift" "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 \
  || echo "    (icon generation skipped)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                  <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>           <string>${APP_NAME}</string>
    <key>CFBundleExecutable</key>            <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>            <string>${BUNDLE_ID}</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>${VERSION}</string>
    <key>CFBundleVersion</key>               <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>        <string>15.0</string>
    <key>LSUIElement</key>                   <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Murmur transcribes your speech on this Mac. Audio never leaves the device.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Murmur records meeting audio you choose to transcribe on this Mac. Audio never leaves the device.</string>
    <key>NSHumanReadableCopyright</key>      <string>Local speech to text.</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc, hardened runtime)"
# The hardened runtime stops other processes from attaching a debugger or
# injecting libraries, either of which could read transcripts from memory.
codesign --force --sign - --options runtime --entitlements "$ROOT/Murmur.entitlements" \
    --identifier "$BUNDLE_ID" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

echo "==> Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "    quitting running instance"
        pkill -x "$APP_NAME" || true
        sleep 1
    fi
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    # Every build is ad-hoc signed, so macOS sees it as a new app and stale
    # permission entries silently stop working. Start clean instead; the app
    # asks again on launch.
    echo "==> Resetting privacy permissions"
    for service in Accessibility Microphone AudioCapture ScreenCapture; do
        tccutil reset "$service" "$BUNDLE_ID" >/dev/null 2>&1 || true
    done
    echo "==> Installed. Launch with: open -a $APP_NAME"
fi

if [[ "${1:-}" == "--dmg" ]]; then
    echo "==> Building disk image"
    DMG="$ROOT/dist/$APP_NAME.dmg"
    STAGE="$ROOT/dist/.dmg-stage"
    rm -rf "$STAGE" "$DMG"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
    rm -rf "$STAGE"
    echo "==> Built $DMG ($(du -sh "$DMG" | cut -f1))"
fi
