#!/bin/bash
# Build "Matter Glow.app" into build/, with the lamp engine bundled inside.
#   ./scripts/build-app.sh            build only
#   ./scripts/build-app.sh --install  build, copy to /Applications and (re)launch
# Node.js must be installed; the app uses the node found here at build time,
# else /opt/homebrew/bin/node or /usr/local/bin/node.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
app="$root/build/Matter Glow.app"
node="$(command -v node)"

[ -d "$root/node_modules" ] || npm ci --prefix "$root"
swift build -c release --package-path "$root/app"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/engine"
cp "$root/app/.build/release/MatterGlow" "$app/Contents/MacOS/MatterGlow"

# The engine and only what it runs: ES module builds, no CommonJS copies,
# TypeScript sources, type declarations or source maps.
rsync -a "$root/engine.js" "$root/package.json" "$root/lib" "$app/Contents/Resources/engine/"
rsync -a --exclude 'dist/cjs' --exclude '/*/src' --exclude '/@*/*/src' \
    --exclude '*.map' --exclude '*.d.ts' --exclude '*.d.cts' --exclude '*.d.mts' \
    "$root/node_modules" "$app/Contents/Resources/engine/"

# App icon: app/AppIcon.icon, made with Icon Composer. actool compiles it into
# Assets.car (the Liquid Glass renderings) plus an .icns fallback.
icon_keys=""
if [ -d "$root/app/AppIcon.icon" ]; then
    xcrun actool "$root/app/AppIcon.icon" --compile "$app/Contents/Resources" --platform macosx \
        --minimum-deployment-target 27.0 --app-icon AppIcon \
        --output-partial-info-plist "$root/build/icon-info.plist" > /dev/null
    icon_keys="<key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleIconName</key><string>AppIcon</string>"
fi

cat > "$app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.matterglow.MatterGlow</string>
    <key>CFBundleName</key><string>Matter Glow</string>
    <key>CFBundleExecutable</key><string>MatterGlow</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>LSUIElement</key><true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Matter Glow reads the current song and its artwork from Music to colour your lamps.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Matter Glow listens to Music's audio to pulse your lamps on the beat. Nothing is recorded or sent anywhere.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Matter Glow briefly listens with the microphone when you press Calibrate, to measure your speakers' delay.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Matter Glow controls your Matter lamps over the local network.</string>
    <key>NSBonjourServices</key>
    <array><string>_matter._tcp</string><string>_matterc._udp</string></array>
    <key>NodePath</key><string>$node</string>
    $icon_keys
</dict>
</plist>
EOF

# A stable signature keeps the app's permissions (Music, audio capture,
# microphone) across rebuilds; without a developer certificate it is ad-hoc.
identity="$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')"
codesign --force --sign "${identity:--}" "$app"
echo "Built $app ($(du -sh "$app" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
    # Quitting hands the lamps back (the app treats SIGTERM like its Quit button).
    if pkill -TERM -f "Matter Glow.app/Contents/MacOS/MatterGlow"; then
        while pgrep -f "Matter Glow.app/Contents/MacOS/MatterGlow" > /dev/null; do sleep 0.2; done
    fi
    rm -rf "/Applications/Matter Glow.app"
    ditto "$app" "/Applications/Matter Glow.app"
    touch "/Applications/Matter Glow.app" # so Finder picks up a new icon
    open "/Applications/Matter Glow.app"
    echo "Installed /Applications/Matter Glow.app"
fi
