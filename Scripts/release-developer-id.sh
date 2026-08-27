#!/bin/zsh
# Cuts a notarized direct-download release: archive signed with Developer ID,
# export, notarize, staple, and zip. The output is the file to put behind the
# download link.
#
# One-time setup this script checks for and will not do on its own:
#
#   1. A "Developer ID Application" certificate for team 249X253HS3 in the
#      login keychain. Create it in Xcode (Settings > Accounts > Manage
#      Certificates > + > Developer ID Application) — requires the paid
#      Apple Developer Program.
#   2. Stored notarization credentials:
#        xcrun notarytool store-credentials fennec-notary \
#          --apple-id <apple-id> --team-id 249X253HS3
#      (an app-specific password from account.apple.com is the simplest;
#      an App Store Connect API key also works. Override the profile name
#      with FENNEC_NOTARY_PROFILE.)
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED_DATA="$ROOT/build/DerivedData"
ARCHIVE="$ROOT/build/Fennec.xcarchive"
EXPORT_DIR="$ROOT/build/DeveloperID"
PROFILE="${FENNEC_NOTARY_PROFILE:-fennec-notary}"

command -v xcodebuild >/dev/null || {
  print -u2 "xcodebuild was not found. Install Xcode and select it with xcode-select."
  exit 1
}

if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
  print -u2 "No 'Developer ID Application' certificate in the keychain."
  print -u2 "Create one in Xcode: Settings > Accounts > Manage Certificates > + > Developer ID Application."
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  print -u2 "No notarization credentials stored under profile '$PROFILE'."
  print -u2 "Store them once with:"
  print -u2 "  xcrun notarytool store-credentials $PROFILE --apple-id <apple-id> --team-id 249X253HS3"
  exit 1
fi

"$ROOT/Scripts/audit-source.sh"

rm -rf "$ARCHIVE" "$EXPORT_DIR"

xcodebuild \
  -project "$ROOT/Fennec.xcodeproj" \
  -scheme Fennec \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  -archivePath "$ARCHIVE" \
  archive

xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$ROOT/Scripts/ExportOptions-developer-id.plist"

APP="$EXPORT_DIR/Fennec.app"
[[ -d "$APP" ]] || {
  print -u2 "Export completed but $APP was not found."
  exit 1
}

# The same bundle checks build-release.sh makes, on the bits that will ship.
[[ -x "$APP/Contents/MacOS/FennecHelper" ]] || {
  print -u2 "The exported app does not contain an executable privileged helper."
  exit 1
}
plutil -lint "$APP/Contents/Library/LaunchDaemons/com.ludicrousdesigns.Fennec.helper.plist"
codesign --verify --strict --verbose=2 "$APP/Contents/MacOS/FennecHelper"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -q "Authority=Developer ID Application" || {
  print -u2 "The exported app is not signed with Developer ID. Refusing to notarize a development-signed build."
  exit 1
}

ZIP="$EXPORT_DIR/Fennec.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

# The ticket staples to the bundle, not the zip, so re-zip after stapling.
xcrun stapler staple "$APP"
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# The end-to-end proof: this is the exact assessment Gatekeeper runs on a
# downloaded copy.
spctl --assess --type execute --verbose=2 "$APP"

print ""
print "Notarized and stapled: $APP"
print "Distributable:         $ZIP"
print "SHA-256 for the release notes:"
shasum -a 256 "$ZIP"
