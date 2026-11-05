#!/bin/bash
# Builds "Монитор батареи.app" into mac/build. Needs only the Xcode command line tools.
# ./build.sh install  — also copies it to /Applications
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Монитор батареи.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/icon.iconset

swiftc -O -target arm64-apple-macos13 main.swift -o build/battery-arm64
swiftc -O -target x86_64-apple-macos13 main.swift -o build/battery-x86_64
lipo -create build/battery-arm64 build/battery-x86_64 -output "$APP/Contents/MacOS/BatteryMonitor"

for n in 16 32 128 256 512; do
  swift icon.swift "build/icon.iconset/icon_${n}x${n}.png" $n
  swift icon.swift "build/icon.iconset/icon_${n}x${n}@2x.png" $((n * 2))
done
iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cp ../index.html ../app/bridge.js "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --entitlements entitlements.plist --options runtime "$APP"

if [ "${1:-}" = "install" ]; then
  rm -rf "/Applications/Монитор батареи.app"
  cp -R "$APP" /Applications/
  echo "Установлено: /Applications/Монитор батареи.app"
fi
