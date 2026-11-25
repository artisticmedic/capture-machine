#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
root=$PWD
dest="$root/.build/distribution"
mkdir -p "$dest"
work=$(mktemp -d "$root/.build/dmg-work.XXXXXX")
app="$work/image/Capture Machine.app"
mkdir -p "$work/image"
GIF_MACHINE_APP="$app" GIF_MACHINE_RELEASE=1 scripts/build-app.sh
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
for binary in "$app/Contents/MacOS/CaptureMachine" "$app/Contents/Helpers/gifski"; do
  [ "$(lipo -archs "$binary")" = arm64 ] || { echo "Expected arm64: $binary" >&2; exit 1; }
  xcrun vtool -show-build "$binary" | awk '/minos/ { ok = ($2 + 0 <= 15) } END { exit !ok }'
done
identity=$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p')
test -n "$identity"
name="Capture-Machine-$version-arm64.dmg"
if [ -e "$dest/$name" ]; then
  echo "Move the existing $dest/$name aside before building another candidate." >&2; exit 1
fi
ln -s /Applications "$work/image/Applications"
cp Resources/InstallerLayout "$work/image/.DS_Store"
hdiutil create -quiet -format UDZO -fs HFS+ -volname 'Drag Capture Machine to Applications' -srcfolder "$work/image" "$work/$name"
codesign --timestamp --sign "$identity" "$work/$name"
codesign --verify --strict "$work/$name"
hdiutil verify "$work/$name"
mv "$work/$name" "$dest/$name"
echo "$dest/$name"
