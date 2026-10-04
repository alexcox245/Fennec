#!/bin/zsh
# Package an already notarized app. This never installs or launches Fennec.
# --notarize also submits, staples, and assesses the signed disk image.
set -euo pipefail

[[ $# -ge 2 && $# -le 3 && (${3:-} == "" || ${3:-} == "--notarize") ]] || {
  print -u2 "Usage: zsh Scripts/create-dmg.sh /path/Fennec.app /path/Fennec.dmg [--notarize]"
  exit 1
}
APP="${1:A}"
DMG="${2:A}"
PROFILE="${FENNEC_NOTARY_PROFILE:-fennec-notary}"
[[ -d "$APP" && ! -e "$DMG" ]] || {
  print -u2 "The app must exist and the output disk image must not already exist."
  exit 1
}
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "com.ludicrousdesigns.Fennec" ]] || {
  print -u2 "Expected the Fennec app bundle."
  exit 1
}
codesign --verify --deep --strict "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute "$APP"
SIGNING_INFO="$(codesign -dv --verbose=4 "$APP" 2>&1)"
IDENTITY="$(print -r -- "$SIGNING_INFO" | sed -n 's/^Authority=\(Developer ID Application:.*\)/\1/p' | head -n 1)"
[[ -n "$IDENTITY" && "$SIGNING_INFO" == *"TeamIdentifier=249X253HS3"* ]] || {
  print -u2 "Expected Fennec's notarized Developer ID export for team 249X253HS3."
  exit 1
}
if [[ ${3:-} == "--notarize" ]]; then
  xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/fennec-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/Fennec.app"
ln -s /Applications "$STAGING/Applications"
print -r -- 'Drag Fennec into Applications, then open it from Applications.

For future updates, open About Fennec and choose Check for Updates.
Fennec downloads only after you choose Download Update and installs only
after Install & Relaunch.' > "$STAGING/Install Fennec.txt"
mkdir -p "${DMG:h}"
hdiutil create -volname Fennec -fs APFS -format ULFO -srcfolder "$STAGING" "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"

if [[ ${3:-} == "--notarize" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature "$DMG"
  print "Ready to publish: $DMG"
else
  print "Prepared: $DMG"
  print "The app is notarized; the disk image still needs notarization before publication."
  print "Submit this disk image with notarytool, staple it, and assess it before publishing."
fi
