#!/bin/bash
# Build SpeakySpeak.app and install it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP=SpeakySpeak.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>SpeakySpeak</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>com.adamraabe.SpeakySpeak</string>
	<key>CFBundleName</key>
	<string>SpeakySpeak</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

mkdir -p "$APP/Contents/Resources"
cp Icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Icon/SyGlyph.png "$APP/Contents/Resources/SyGlyph.png"
# the Updater compares this against the public repo's VERSION on main
cp VERSION "$APP/Contents/Resources/VERSION"

# Deployment target must be set explicitly. Without -target, swiftc stamps the
# BUILD machine's OS as the minimum, so a Mac on macOS 26 produced a binary that
# refused to launch below 26 while Info.plist advertised 14.0. Everything newer
# than 14 is already behind #available checks (Liquid Glass falls back to the
# frosted card), so the two now agree. uname -m keeps Intel Macs building x86_64.
swiftc -O -target "$(uname -m)-apple-macosx14.0" main.swift -o "$APP/Contents/MacOS/SpeakySpeak"
codesign --force -s - "$APP"

mkdir -p "$HOME/Applications"
rm -rf "$HOME/Applications/$APP"
cp -R "$APP" "$HOME/Applications/"
echo "Installed $HOME/Applications/$APP"
