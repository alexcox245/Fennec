#!/bin/zsh
# Cuts a notarized direct-download release: archive signed with Developer ID,
# export, notarize, staple, and zip. The output is the file to put behind the
# download link.
#
# One-time setup this script checks for and will not do on its own:
#
#   1. A "Developer ID Application" certificate for team 249X253HS3 in the
#      login keychain. Create it in Xcode (Settings > Accounts > Manage
#      Certificates > + > Developer ID Application); this requires the paid
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
UPDATES_DIR="$ROOT/build/updates"
PROFILE="${FENNEC_NOTARY_PROFILE:-fennec-notary}"
RELEASE_NOTES="${FENNEC_RELEASE_NOTES:-$ROOT/build/ReleaseNotes.md}"

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

[[ -f "$RELEASE_NOTES" ]] || {
  print -u2 "Release notes were not found at $RELEASE_NOTES. Write the notes before cutting a release."
  exit 1
}

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

read_bundle_value() {
  /usr/libexec/PlistBuddy -c "Print :$2" "$1"
}

APP_INFO="$APP/Contents/Info.plist"
APP_VERSION="$(read_bundle_value "$APP_INFO" CFBundleShortVersionString)"
APP_BUILD="$(read_bundle_value "$APP_INFO" CFBundleVersion)"
HELPER_BUILD_SETTINGS="$(xcodebuild -project "$ROOT/Fennec.xcodeproj" -scheme FennecHelper -configuration Release -showBuildSettings 2>/dev/null)"
HELPER_VERSION="$(print -r -- "$HELPER_BUILD_SETTINGS" | awk -F ' = ' '$1 ~ /^[[:space:]]*MARKETING_VERSION$/ { print $2; exit }')"
HELPER_BUILD="$(print -r -- "$HELPER_BUILD_SETTINGS" | awk -F ' = ' '$1 ~ /^[[:space:]]*CURRENT_PROJECT_VERSION$/ { print $2; exit }')"

[[ "$APP_VERSION" == "$HELPER_VERSION" && "$APP_BUILD" == "$HELPER_BUILD" ]] || {
  print -u2 "The app and helper version/build do not match (app $APP_VERSION/$APP_BUILD, helper $HELPER_VERSION/$HELPER_BUILD)."
  exit 1
}

[[ "$(read_bundle_value "$APP_INFO" SUPublicEDKey)" == "$(read_bundle_value "$ROOT/Fennec/Info.plist" SUPublicEDKey)" ]] || {
  print -u2 "The built app's Sparkle public key does not match Fennec/Info.plist."
  exit 1
}

[[ "$(read_bundle_value "$APP_INFO" SUEnableAutomaticChecks)" == "false" \
  && "$(read_bundle_value "$APP_INFO" SUAutomaticallyUpdate)" == "false" \
  && "$(read_bundle_value "$APP_INFO" SUAllowsAutomaticUpdates)" == "false" ]] || {
  print -u2 "Automatic update checks or installation are enabled in the built app."
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

SPARKLE_BIN="$DERIVED_DATA/SourcePackages/artifacts/sparkle/Sparkle/bin"
GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
[[ -x "$GENERATE_APPCAST" ]] || {
  print -u2 "Sparkle's generate_appcast was not found at $GENERATE_APPCAST."
  exit 1
}

mkdir -p "$UPDATES_DIR"
VERSIONED_ZIP="$UPDATES_DIR/Fennec-$APP_VERSION.zip"
ditto -c -k --keepParent "$APP" "$VERSIONED_ZIP"
cp "$RELEASE_NOTES" "$UPDATES_DIR/Fennec-$APP_VERSION.md"
"$GENERATE_APPCAST" \
  --download-url-prefix "https://github.com/alexcox245/Fennec/releases/download/v$APP_VERSION/" \
  --embed-release-notes \
  --maximum-versions 0 \
  -o "$UPDATES_DIR/appcast.xml" \
  "$UPDATES_DIR"
grep -q "sparkle:edSignature" "$UPDATES_DIR/appcast.xml" || {
  print -u2 "Sparkle did not sign the generated appcast. Refusing to report a release candidate."
  exit 1
}

print ""
print "Notarized and stapled: $APP"
print "Distributable:         $ZIP"
print "SHA-256 for the release notes:"
shasum -a 256 "$ZIP"
print ""
print "Signed updater feed:   $UPDATES_DIR/appcast.xml"
print "Updater archive:       $VERSIONED_ZIP"
print "Release notes:          $UPDATES_DIR/Fennec-$APP_VERSION.md"
print "Review these files, then upload the archive, any new delta archives, and appcast.xml to the public v$APP_VERSION GitHub release."
