#!/bin/sh
# Builds the development copy by default: .build/Capture Machine Dev.app, bundle id com.timgailey.CaptureMachine.dev.
# GIF_MACHINE_RELEASE=1 builds the release copy instead: .build/Capture Machine.app, bundle id com.timgailey.CaptureMachine.
# --install also copies the app to ~/Applications, where Raycast and Spotlight find it. GIF_MACHINE_APP overrides the
# bundle path. GIF_MACHINE_SIGN_IDENTITY overrides the signing
# identity, which is otherwise the first Apple Development or Developer ID identity, so the Screen Recording grant
# survives rebuilds; ad-hoc signing needs a new grant after each build. The icon, Resources/AppIcon.icon, is an Icon
# Composer document; actool, from Xcode, compiles it. gifski, which makes GIFs, is built by scripts/build-gifski.sh and
# goes in Contents/Helpers with its license.
set -eu
cd "$(dirname "$0")/.."
case "${GIF_MACHINE_RELEASE:-0}" in
  0) NAME="Capture Machine Dev"; BUNDLE_ID="com.timgailey.CaptureMachine.dev" ;;
  1) NAME="Capture Machine"; BUNDLE_ID="com.timgailey.CaptureMachine" ;;
  *) echo "GIF_MACHINE_RELEASE must be 0 or 1: $GIF_MACHINE_RELEASE" >&2; exit 1 ;;
esac
APP="${GIF_MACHINE_APP:-$PWD/.build/$NAME.app}"
case "$APP" in
  /*.app) ;;
  *) echo "GIF_MACHINE_APP must be an absolute path ending in .app: $APP" >&2; exit 1 ;;
esac
if [ -e "$APP" ] || [ -L "$APP" ]; then
  existing=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)
  if [ -L "$APP" ] || [ "$existing" != "$BUNDLE_ID" ]; then
    echo "Refusing to replace an unrecognized app at $APP" >&2; exit 1
  fi
fi
swift build -c release --product GIFMachine
scripts/build-gifski.sh
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/gifski" "$APP/Contents/Helpers"
cp .build/release/GIFMachine "$APP/Contents/MacOS/CaptureMachine"
if [ "${GIF_MACHINE_RELEASE:-0}" = 1 ]; then
  strip -S -x "$APP/Contents/MacOS/CaptureMachine"
fi
cp .build/gifski/out/bin/gifski "$APP/Contents/Helpers/gifski"
cp Resources/gifski/LICENSE Resources/gifski/NOTICE Resources/gifski/THIRD-PARTY.txt "$APP/Contents/Resources/gifski/"
cp LICENSE NOTICE "$APP/Contents/Resources/"
# The welcome window's key, rest to fully pressed, rendered from the same 3D model as the icon.
cp -R Resources/WelcomeKey "$APP/Contents/Resources/"
xcrun actool Resources/AppIcon.icon --compile "$APP/Contents/Resources" --platform macosx --minimum-deployment-target 15.0 \
  --app-icon AppIcon --output-partial-info-plist .build/AppIcon-partial.plist --errors > /dev/null
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>CaptureMachine</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.1</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
if [ "${GIF_MACHINE_RELEASE:-0}" = 1 ]; then
  IDENTITY="${GIF_MACHINE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application:/ {print $2; exit}')}"
  [ -n "$IDENTITY" ] || { echo "Release builds need a Developer ID Application identity." >&2; exit 1; }
  set_timestamp=--timestamp
else
  IDENTITY="${GIF_MACHINE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
  set_timestamp=
fi
for component in "$APP/Contents/Helpers/gifski" "$APP"; do
  codesign --force --options runtime $set_timestamp --sign "${IDENTITY:--}" "$component"
  if [ -n "$set_timestamp" ]; then
    codesign -dvv "$component" 2>&1 | grep -q '^Authority=Developer ID Application:' || {
      echo "Release builds need a Developer ID Application signature." >&2; exit 1
    }
  fi
done
codesign --verify --deep --strict "$APP"
echo "Built $APP ($BUNDLE_ID, signed: ${IDENTITY:-ad-hoc})"
if [ "${1:-}" = "--install" ]; then
  INSTALLED="$HOME/Applications/$NAME.app"
  mkdir -p "$HOME/Applications"
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  echo "Installed $INSTALLED"
fi
