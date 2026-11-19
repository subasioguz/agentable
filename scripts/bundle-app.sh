#!/bin/bash
# Wraps the SwiftPM build into Agentable.app: the app, the agentable CLI agents run, and the fonts.
#
#   scripts/bundle-app.sh [debug|release]
#
# The result is .build/Agentable.app, signed ad hoc for local use. Developer ID signing and
# notarization come with the release work (docs/PLAN.md, step 6).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CONFIG=${1:-debug}
cd "$ROOT"

swift build -c "$CONFIG" --product agentable
swift build -c "$CONFIG" --product AgentableApp
BIN="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/Agentable.app"
VERSION=${AGENTABLE_VERSION:-0.1.0}

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/AgentableApp" "$APP/Contents/MacOS/Agentable"
cp "$BIN/agentable" "$APP/Contents/Helpers/agentable"
cp -R "$ROOT/Sources/AgentableApp/Resources/Fonts" "$APP/Contents/Resources/Fonts"
cp "$ROOT/Sources/AgentableApp/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp -R "$ROOT/Sources/AgentableApp/Localization/"*.lproj "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.agentable.app</string>
  <key>CFBundleName</key><string>Agentable</string>
  <key>CFBundleDisplayName</key><string>Agentable</string>
  <key>CFBundleExecutable</key><string>Agentable</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>de</string><string>es</string><string>fr</string><string>it</string><string>pt-BR</string><string>ru</string><string>tr</string><string>ja</string><string>ko</string><string>zh-Hans</string><string>zh-Hant</string></array>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Copyright 2026 Oğuzhan Subaşı. Apache License 2.0.</string>
</dict>
</plist>
PLIST

# The linker already signs ad hoc; re-signing the whole bundle seals the Info.plist and resources.
sign() { codesign --force --sign - "$1" 2>/dev/null || { echo "codesign failed for $1" >&2; exit 1; }; }
sign "$APP/Contents/Helpers/agentable"
sign "$APP"
echo "$APP"
