#!/usr/bin/env bash
# Собирает SinCombo.app (arm64) из Swift-пакета и упаковывает в build/SinCombo.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

# Версия — из последнего тега vX.Y.Z, номер сборки — число коммитов.
VERSION="${VERSION:-$( (git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true) | sed 's/^v//')}"
VERSION="${VERSION:-0.0.0}"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP="build/SinCombo.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/SinCombo"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SinCombo"

# Иконка: Resources/AppIcon.png (1024×1024, рисует scripts/make-icon.py) → AppIcon.icns
ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SinCombo</string>
  <key>CFBundleDisplayName</key><string>SinCombo</string>
  <key>CFBundleIdentifier</key><string>com.claudesiniakov.sincombo</string>
  <key>CFBundleExecutable</key><string>SinCombo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
  <key>CFBundleDevelopmentRegion</key><string>ru</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>SinCombo показывает события ваших календарей и создаёт новые по вашей команде.</string>
  <key>NSCalendarsUsageDescription</key><string>SinCombo показывает события ваших календарей и создаёт новые по вашей команде.</string>
  <key>NSLocationUsageDescription</key><string>macOS сообщает имена сетей Wi-Fi только приложениям с доступом к геолокации. Само местоположение SinCombo не использует.</string>
  <key>NSLocationWhenInUseUsageDescription</key><string>macOS сообщает имена сетей Wi-Fi только приложениям с доступом к геолокации. Само местоположение SinCombo не использует.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>SinCombo показывает сопряжённые устройства Bluetooth и подключает их.</string>
  <key>NSHumanReadableCopyright</key><string>© claudesiniakov</string>
</dict>
</plist>
PLIST

# Ad-hoc подпись (без Developer ID). Для распространения нужна подпись и нотаризация.
# Защищённая среда выполнения без этих прав молча запрещает календари, геолокацию и Bluetooth.
cat > build/SinCombo.entitlements <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.security.personal-information.calendars</key><true/>
  <key>com.apple.security.personal-information.location</key><true/>
  <key>com.apple.security.device.bluetooth</key><true/>
</dict>
</plist>
ENT
codesign --force --deep --options runtime --entitlements build/SinCombo.entitlements --sign - "$APP"
rm build/SinCombo.entitlements
codesign --verify --verbose "$APP"

ditto -c -k --keepParent "$APP" build/SinCombo.zip
# Контрольная сумма для проверки обновления внутри приложения.
(cd build && shasum -a 256 SinCombo.zip > SinCombo.zip.sha256)
echo "Готово: $APP и build/SinCombo.zip (версия $VERSION, сборка $BUILD_NUMBER)"
