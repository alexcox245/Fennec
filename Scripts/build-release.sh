#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED_DATA="$ROOT/build/DerivedData"

command -v xcodebuild >/dev/null || {
  print -u2 "xcodebuild was not found. Install Xcode and select it with xcode-select."
  exit 1
}

"$ROOT/Scripts/audit-source.sh"

xcodebuild \
  -project "$ROOT/Fennec.xcodeproj" \
  -scheme Fennec \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  clean build

APP="$DERIVED_DATA/Build/Products/Release/Fennec.app"
HELPER="$APP/Contents/MacOS/FennecHelper"
LAUNCH_PLIST="$APP/Contents/Library/LaunchDaemons/com.ludicrousdesigns.Fennec.helper.plist"

[[ -d "$APP" ]] || {
  print -u2 "Build completed but $APP was not found."
  exit 1
}
[[ -x "$HELPER" ]] || {
  print -u2 "The built app does not contain an executable privileged helper at $HELPER."
  exit 1
}
[[ -f "$LAUNCH_PLIST" ]] || {
  print -u2 "The built app does not contain its LaunchDaemon plist at $LAUNCH_PLIST."
  exit 1
}

plutil -lint "$LAUNCH_PLIST"
codesign --verify --strict --verbose=2 "$HELPER"
codesign --verify --deep --strict --verbose=2 "$APP"

print "Built and verified: $APP"
print "For reliable helper registration, copy the signed app to /Applications:"
print "  sudo ditto '$APP' /Applications/Fennec.app"
print "Then launch it:"
print "  open /Applications/Fennec.app"
