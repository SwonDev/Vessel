#!/bin/bash
set -e

APP_NAME="Vessel"
BUNDLE_ID="com.swondev.vessel"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_PATH="Resources/icon.icns"

echo "==> Building $APP_NAME (release)..."
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)/$APP_NAME
echo "==> Binary: $BIN_PATH"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
[ -f "$ICON_PATH" ] && cp "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/icon.icns"
[ -f "Resources/steamwebhelper-wrapper.exe" ] && cp "Resources/steamwebhelper-wrapper.exe" "$APP_BUNDLE/Contents/Resources/steamwebhelper-wrapper.exe"
[ -f "Resources/game-wrapper.exe" ] && cp "Resources/game-wrapper.exe" "$APP_BUNDLE/Contents/Resources/game-wrapper.exe"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Vessel</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>icon</string>
    <key>CFBundleIconName</key>
    <string>icon</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Windows Executable</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.microsoft.windows-executable</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

# Instalar SIEMPRE la última versión en /Applications, para que Spotlight,
# Launchpad y el Dock abran esta build (no una copia vieja).
echo "==> Instalando en /Applications/$APP_NAME.app..."
osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_BUNDLE" "/Applications/$APP_NAME.app"
codesign --force --deep --sign - "/Applications/$APP_NAME.app"

echo "==> App instalada: /Applications/$APP_NAME.app"
echo "==> Launching..."
open "/Applications/$APP_NAME.app"
