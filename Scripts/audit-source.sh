#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
PROJECT="$ROOT/Fennec.xcodeproj/project.pbxproj"
LAUNCH_PLIST="$ROOT/LaunchDaemons/com.ludicrousdesigns.Fennec.helper.plist"

print "Linting property lists and the Xcode project…"
plutil -lint \
  "$PROJECT" \
  "$ROOT/Fennec/Info.plist" \
  "$ROOT/Fennec/Fennec.entitlements" \
  "$ROOT/FennecHelper/Info.plist" \
  "$LAUNCH_PLIST"

print "Checking required project files…"
required=(
  "$PROJECT"
  "$ROOT/Fennec/FennecApp.swift"
  "$ROOT/Fennec/CoreAudioMonitor.swift"
  "$ROOT/Fennec/RTSignalCounters.c"
  "$ROOT/FennecHelper/main.swift"
  "$ROOT/Shared/HelperProtocol.swift"
  "$LAUNCH_PLIST"
)
# Note: do not use `path` as the loop variable; zsh ties it to $PATH.
for required_path in $required; do
  [[ -f "$required_path" ]] || { print -u2 "Missing: $required_path"; exit 1; }
done

print "Auditing privileged-helper packaging…"
grep -q 'dstSubfolderSpec = 6;' "$PROJECT" || {
  print -u2 "The helper copy phase is not targeting the app Executables directory."
  exit 1
}
grep -q 'dstPath = Contents/Library/LaunchDaemons;' "$PROJECT" || {
  print -u2 "The LaunchDaemon plist copy destination is missing."
  exit 1
}
[[ "$(grep -c 'ENABLE_DEBUG_DYLIB_SUPPORT = NO;' "$PROJECT")" -eq 2 ]] || {
  print -u2 "ENABLE_DEBUG_DYLIB_SUPPORT must be disabled in both helper configurations."
  exit 1
}
grep -q 'CodeSignOnCopy' "$PROJECT" || {
  print -u2 "The embedded helper is not configured for CodeSignOnCopy."
  exit 1
}
/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$LAUNCH_PLIST" 2>/dev/null \
  | grep -qx 'Contents/MacOS/FennecHelper' || {
    print -u2 "The LaunchDaemon BundleProgram path is incorrect."
    exit 1
  }

if command -v xcrun >/dev/null 2>&1; then
  print "Parsing Swift sources with the active Xcode toolchain…"
  for source in \
    "$ROOT"/Fennec/*.swift \
    "$ROOT"/FennecHelper/*.swift \
    "$ROOT"/Shared/*.swift \
    "$ROOT"/FennecTests/*.swift; do
    xcrun swiftc -parse "$source" >/dev/null
  done

  print "Checking the real-time C callback with the macOS SDK…"
  xcrun --sdk macosx clang \
    -std=c11 -Wall -Wextra -Werror \
    -I"$ROOT/Fennec" \
    -fsyntax-only "$ROOT/Fennec/RTSignalCounters.c"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  print "Checking Xcode project and shared scheme discovery…"
  xcodebuild -project "$ROOT/Fennec.xcodeproj" -list \
    | grep -q 'Fennec'
fi

print "Verifying Docs/SOURCE_MANIFEST.sha256…"
(cd "$ROOT" && shasum -a 256 -c Docs/SOURCE_MANIFEST.sha256 --quiet) || {
  print -u2 "The source manifest is stale. Run: zsh Scripts/update-manifest.sh"
  exit 1
}

print "Source audit passed. Run build-release.sh on macOS for SDK type-checking, linking, signing, and bundle verification."
