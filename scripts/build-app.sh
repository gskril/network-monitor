#!/bin/zsh
# Builds NetworkMonitor.app into dist/ from the SwiftPM release build.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="dist/NetworkMonitor.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/NetworkMonitor "$APP/Contents/MacOS/NetworkMonitor"

# Bundle the helper scripts so the in-app Setup panel can run them.
cp scripts/install-bpf-helper.sh scripts/uninstall-bpf-helper.sh "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>NetworkMonitor</string>
	<key>CFBundleIdentifier</key>
	<string>com.greg.networkmonitor</string>
	<key>CFBundleName</key>
	<string>Network Monitor</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"

echo "Built $APP"
