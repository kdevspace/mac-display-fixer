#!/bin/bash
# Builds the Mac Display Fixer menu bar application bundle.
# Usage: ./build-app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"
BIN=".build/$CONFIG/nbd"
APP="build/Mac Display Fixer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/nbd"

# App icon (regenerate with: swift tools/MakeIcon.swift &&
# iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns)
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Localizations
for lang in ru en de es zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "Localization/$lang.lproj/Localizable.strings" "$APP/Contents/Resources/$lang.lproj/Localizable.strings"
done

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>ru</string>
    <key>CFBundleDisplayName</key>
    <string>Mac Display Fixer</string>
    <key>CFBundleExecutable</key>
    <string>nbd</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.kdev.macdisplayfixer</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>ru</string>
        <string>en</string>
        <string>de</string>
        <string>es</string>
        <string>zh-Hans</string>
    </array>
    <key>CFBundleName</key>
    <string>Mac Display Fixer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/codesign --force --sign - "$APP"
echo "Готово: $APP"
echo "Запуск:  open \"$APP\""
echo "CLI:     \"$APP/Contents/MacOS/nbd\" --list | --probe"

