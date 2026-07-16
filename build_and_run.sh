#!/bin/bash
set -e

APP_NAME="Vessel"
BUNDLE_ID="com.swondev.vessel"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_PATH="Resources/icon.icns"

# Versión: ÚNICA fuente de verdad en VERSION.txt ("X.Y.Z<TAB>N" → versión visible + build incremental).
# La usa el Info.plist de abajo y `release.sh` al publicar. Súbela con: ./release.sh <X.Y.Z>
VERSION=$(cut -f1 VERSION.txt 2>/dev/null | tr -d '[:space:]')
BUILD_NUMBER=$(cut -f2 VERSION.txt 2>/dev/null | tr -d '[:space:]')
VERSION="${VERSION:-0.0.1}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "==> Building $APP_NAME (release)..."
swift build -c release

BIN_PATH=$(swift build -c release --show-bin-path)/$APP_NAME
echo "==> Binary: $BIN_PATH"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Sparkle.framework (auto-update firmado EdDSA): SwiftPM lo deja junto al binario tras compilar.
# Se embebe en Contents/Frameworks; el ejecutable lo encuentra por el rpath @executable_path/../Frameworks.
SPARKLE_FW="$(swift build -c release --show-bin-path)/Sparkle.framework"
if [ -d "$SPARKLE_FW" ]; then
    cp -R "$SPARKLE_FW" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
fi
[ -f "$ICON_PATH" ] && cp "$ICON_PATH" "$APP_BUNDLE/Contents/Resources/icon.icns"
[ -f "Resources/steamwebhelper-wrapper.exe" ] && cp "Resources/steamwebhelper-wrapper.exe" "$APP_BUNDLE/Contents/Resources/steamwebhelper-wrapper.exe"
# Helper vessel-spawn: desacopla los procesos Wine de la identidad de la app (responsible process),
# imprescindible para que el CEF de Steam del motor completo cree su ventana desde la .app.
[ -f "Resources/vessel-spawn" ] && cp "Resources/vessel-spawn" "$APP_BUNDLE/Contents/Resources/vessel-spawn" && chmod +x "$APP_BUNDLE/Contents/Resources/vessel-spawn" && codesign --force --sign - "$APP_BUNDLE/Contents/Resources/vessel-spawn" 2>/dev/null
# Mini-app launcher: Vessel la lanza con `open` (LaunchServices → app independiente) para que el CEF
# de Steam del motor completo cree su ventana desde la app.
[ -d "Resources/SteamLauncher.app" ] && cp -R "Resources/SteamLauncher.app" "$APP_BUNDLE/Contents/Resources/SteamLauncher.app" && codesign --force --deep --sign - "$APP_BUNDLE/Contents/Resources/SteamLauncher.app" 2>/dev/null
[ -f "Resources/game-wrapper.exe" ] && cp "Resources/game-wrapper.exe" "$APP_BUNDLE/Contents/Resources/game-wrapper.exe"
[ -f "Resources/dpapi-seal.exe" ] && cp "Resources/dpapi-seal.exe" "$APP_BUNDLE/Contents/Resources/dpapi-seal.exe"
# Certificados raíz DigiCert (validación TLS del login/CM de Steam — cadena EV ECDSA)
[ -f "Resources/steam-certs.reg" ] && cp "Resources/steam-certs.reg" "$APP_BUNDLE/Contents/Resources/steam-certs.reg"
[ -f "Resources/crossover-compat-overrides.reg" ] && cp "Resources/crossover-compat-overrides.reg" "$APP_BUNDLE/Contents/Resources/crossover-compat-overrides.reg"
# Logos oficiales de las tiendas (sidebar)
[ -d "Resources/StoreLogos" ] && cp Resources/StoreLogos/*.png "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
# Logo de marca de Vessel (cabecera del sidebar)
[ -f "Resources/vessel-logo.png" ] && cp "Resources/vessel-logo.png" "$APP_BUNDLE/Contents/Resources/vessel-logo.png"
# Redistribuibles nativos (d3dx9/d3dcompiler de Microsoft) para juegos D3D9 con efectos .fx
[ -d "Resources/redist" ] && cp -R "Resources/redist" "$APP_BUNDLE/Contents/Resources/redist"
# Base de datos de compatibilidad por juego empaquetada (se actualiza desde el repo comunitario)
[ -d "Resources/CompatDB" ] && cp -R "Resources/CompatDB" "$APP_BUNDLE/Contents/Resources/CompatDB"
# win32u.so parcheado (fix del ratón de Unity 6): Vessel crea el motor wine-dxmt-mousefix con él
[ -d "Resources/mousefix" ] && cp -R "Resources/mousefix" "$APP_BUNDLE/Contents/Resources/mousefix"
# win32u.so parcheado para gptk (Wine 9.0): Vessel crea el motor gptk-mythic-mousefix con él (Unity 6)
[ -d "Resources/mousefix-gptk" ] && cp -R "Resources/mousefix-gptk" "$APP_BUNDLE/Contents/Resources/mousefix-gptk"
# winemac.so parcheado (forward-compat GL, CW Hack 24834): Vessel crea el motor wine-unified-opengl con él (HoH2 y juegos OpenGL)
[ -d "Resources/opengl-engine" ] && cp -R "Resources/opengl-engine" "$APP_BUNDLE/Contents/Resources/opengl-engine"
# winemac.so con el fix de la TIENDA de Steam (CW HACK 22435): Vessel crea el motor DEDICADO wine-steam con él (Abrir Steam: cliente + biblioteca + tienda)
[ -d "Resources/steam-engine" ] && cp -R "Resources/steam-engine" "$APP_BUNDLE/Contents/Resources/steam-engine"
# Fix de render+conexión del cliente de Steam (win32u wow64 + bcrypt/secur32 gnutls): DependencyManager
# lo aplica al motor unificado (auto-reparable) para que el CEF pinte por DXMT y el login conecte
[ -d "Resources/engine-steamfix" ] && cp -R "Resources/engine-steamfix" "$APP_BUNDLE/Contents/Resources/engine-steamfix"

# Motor v3: cadena crypto (gnutls 3.8.13 + nettle 4.0 + hogweed) y freetype 2.14.3 x86_64 — DependencyManager
# las copia en caliente al lib/ del motor unificado (applyCryptoFix, gated por marcador) sin re-descargar 2 GB
[ -d "Resources/engine-cryptofix" ] && cp -R "Resources/engine-cryptofix" "$APP_BUNDLE/Contents/Resources/engine-cryptofix"

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
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>Vessel accede a los archivos de tus juegos y motores de Wine, que pueden estar en volúmenes de red. Concede el permiso una vez y no volverá a preguntar.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>Vessel accede a los juegos que tengas instalados en discos externos.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>Vessel puede necesitar leer juegos o archivos ubicados en tu Escritorio.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Vessel puede necesitar leer partidas o archivos de juego ubicados en Documentos.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>Vessel puede necesitar leer instaladores o archivos de juego ubicados en Descargas.</string>
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
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/SwonDev/Vessel/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>Uj6yYUIotPnQQk5iHzUiWdVukl7pDq1kszju6Z1G99Q=</string>
    <key>SUEnableAutomaticChecks</key>
    <true/>
    <key>SUScheduledCheckInterval</key>
    <integer>86400</integer>
</dict>
</plist>
EOF

echo "==> Ad-hoc signing..."
# Sparkle exige firma inside-out (helpers antes que el framework antes que la app). --deep no basta
# para los XPC/Updater.app anidados. Firmamos de dentro afuera; si Sparkle no está, se salta.
SPARKLE_IN_APP="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
if [ -d "$SPARKLE_IN_APP" ]; then
    V="$SPARKLE_IN_APP/Versions/B"
    codesign --force --sign - "$V/XPCServices/Downloader.xpc" 2>/dev/null || true
    codesign --force --sign - "$V/XPCServices/Installer.xpc" 2>/dev/null || true
    codesign --force --sign - "$V/Updater.app" 2>/dev/null || true
    codesign --force --sign - "$V/Autoupdate" 2>/dev/null || true
    codesign --force --sign - "$SPARKLE_IN_APP" 2>/dev/null || true
fi
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
# `release.sh` compila con VESSEL_NO_LAUNCH=1: empaqueta para publicar sin abrir la app.
if [ "${VESSEL_NO_LAUNCH:-0}" = "1" ]; then
    echo "==> (VESSEL_NO_LAUNCH=1: no se abre la app)"
else
    echo "==> Launching..."
    open "/Applications/$APP_NAME.app"
fi
