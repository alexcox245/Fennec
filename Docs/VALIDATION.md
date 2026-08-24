# Validation report

Date: 2026-08-20

## Completed in the source-generation environment

- `plutil -lint` passed for the Xcode project, app Info.plist, helper Info.plist, entitlements, and embedded LaunchDaemon property list.
- All 20 Swift source files passed the Swift parser.
- `DetectionEngine` passed executable behavior checks for balanced overload detection, immediate overload detection, and abnormal-I/O detection.
- `EventLogger` passed an executable write/read behavior check.
- The real-time C callback passed `clang -std=c11 -Wall -Wextra -Werror` syntax and warning checks against a Core Audio API stub.
- Source review confirmed that a Core Audio service restart drains a dedicated real-time counter, rebuilds the full listener graph, and removes any partially rebuilt listener set on failure.
- The privileged helper now confirms that launchd produced a new `coreaudiod` PID before it reports a successful repair.
- A static packaging audit confirmed:
  - the helper target is embedded in the app's Executables destination (`Contents/MacOS`),
  - the LaunchDaemon plist is copied to `Contents/Library/LaunchDaemons`,
  - the helper is copied with `CodeSignOnCopy`,
  - `ENABLE_DEBUG_DYLIB_SUPPORT=NO` is set for both helper configurations,
  - the helper's `BundleProgram` path matches its embedded location.

## Still required on macOS

This source was prepared in an environment without Xcode or the macOS SDK, so it has not been SDK type-checked, linked, code-signed, registered with Background Task Management, or exercised against a live Core Audio device here.

Before relying on automatic repair, build it in Xcode on macOS and complete this runtime test:

1. Select the same Apple signing team for both targets.
2. Build the Release configuration.
3. Confirm the built bundle contains the helper and LaunchDaemon plist.
4. Install the app in `/Applications`.
5. Enable and approve the helper.
6. Confirm **Repair Audio Now** restarts Core Audio and playback reconnects.
7. Reproduce the Claude Code workload while audio plays.
8. Verify an overload/abnormal-stop counter increments when the audible fault begins.
9. Only then change detection from **Balanced** to **Immediate**.

The included `Scripts/audit-source.sh` and `Scripts/build-release.sh` automate the source checks and built-bundle verification on macOS.
