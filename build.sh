#!/bin/zsh
# Compila la app de barra de menú y la empaqueta como build/DisplayToggle.app
set -euo pipefail
cd "$(dirname "$0")"

APP="build/DisplayToggle.app"
ARCH="$(uname -m)"   # arm64 (Apple Silicon) o x86_64 (Intel): compila para la Mac actual.
# Identificador del bundle. Cámbialo si publicas tu propio build:
#   BUNDLE_ID=com.tunombre.displaytoggle ./build.sh
BUNDLE_ID="${BUNDLE_ID:-local.displaytoggle}"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O \
  -target "${ARCH}-apple-macos13.0" \
  App/DisplayToggleApp.swift \
  -o "$APP/Contents/MacOS/DisplayToggle"

# Ícono: genera AppIcon.icns desde toggledisplay.png (1024×1024) dentro del bundle,
# para que quede sellado por la firma (no pegarlo desde el Finder).
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size toggledisplay.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) toggledisplay.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>             <string>DisplayToggle</string>
    <key>CFBundleDisplayName</key>      <string>DisplayToggle</string>
    <key>CFBundleIdentifier</key>       <string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key>       <string>DisplayToggle</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key>          <string>1</string>
    <key>LSMinimumSystemVersion</key>   <string>13.0</string>
    <key>LSUIElement</key>              <true/>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>DisplayToggle uses Control Center to connect your iPad via Sidecar when SidecarCore doesn't respond. / DisplayToggle usa Centro de control para conectar el iPad por Sidecar cuando SidecarCore no responde.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Listo: $APP"
