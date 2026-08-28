# Validation report

Date: 2026-08-25, re-verified 2026-08-28. Supersedes the 2026-08-20 report,
which described an environment without Xcode and is no longer accurate about
anything.

## What is verified, and how

Run from the repo root on macOS 26.5 with Xcode 26.6 (17F113).

| Check | Command | Result |
|---|---|---|
| Build matrix | `xcodebuild -scheme {Fennec,FennecHelper} -configuration {Debug,Release} build` | All four green |
| Unit tests | `xcodebuild -scheme Fennec -configuration Debug test` | 244 passing, 0 failures |
| Static audit | `zsh Scripts/audit-source.sh` | Passes, including the `shasum -c` manifest gate |
| Bundle + signature | `zsh Scripts/build-release.sh` | Layout verified, `codesign --verify` passes |
| Warnings | Release clean build | Exactly 4, all catalogued as T-007 / T-008 |

`FennecTests` is a standalone XCTest bundle with no `TEST_HOST`, so the suite
never launches the app, never touches Core Audio, and never writes to the real
Application Support directory. What it covers:

- `DetectionEngine`: every sensitivity's threshold and window, the elapsed
  span reported to the copy layer, abnormal-stop handling, and the resets
  around device changes and repairs.
- `RepairGovernor`: the verification window, and the stand-down breaker's
  refusal to count manual repairs or repairs that held.
- `RepairCopy`: exact strings, including a check that nothing shouts or uses
  emoji, and that the outcome (not `succeeded`) drives what is called "fixed".
- `NotificationBudget`, `PauseState`, `DrainSchedule`, `SetupChecklist`,
  `InstallLocation`, `PrivilegeDisclosure`, `UninstallPlan`, `HelperIdentity`,
  `DaysWithoutIncident`, `RepairSummary`, `EventLogger`, `SettingsStore`.
- `ReviewRegressionTests`: one test per confirmed finding from the adversarial
  review that has pure logic behind it.

## What has been exercised by hand

The built app was launched and driven on this machine. Confirmed:

- The menu-bar glyph renders as a template image in a real menu bar and
  inverts correctly.
- The first-run window opens by itself on first launch, every section renders,
  and closing it with the red button now persists `hasCompletedFirstRun`.
- The install-location guard correctly identifies a DerivedData build.
- Settings opens from the main menu, the Dock reopen, and the popover; all
  three tabs render; the tab picker works.
- The About window opens from **Fennec ▸ About Fennec** and shows the privilege
  disclosure, the verification commands, and the uninstall entry point.
- The Activity window opens from the Audio menu and shows its empty state.
- A persisted pause survives relaunch and renders as "Paused · resumes in …".
- The app's main menu exists while a window is open (Apple, Fennec, Edit, View,
  Audio, Window, Help), which is what makes ⌘W / ⌘Q / ⌘, work at all.

## Still required on a device ([T-005](../AGENTS.md#open))

**Nothing below has been done, and nobody should trust automatic repair until
it is.** All of it needs a signed build in `/Applications`, a real approval in
System Settings, and a reproduction of the audible fault.

1. Select an Apple Development or Developer ID team for both targets and build
   Release.
2. `sudo ditto` the app into `/Applications` and launch it from there.
3. Enable the helper and approve Fennec under **System Settings ▸ General ▸
   Login Items & Extensions ▸ Allow in the Background**.
4. Confirm **Repair Audio Now** restarts Core Audio and that playback
   reconnects. Note the reported duration.
5. Confirm the success notification actually arrives, and that its wording
   matches what the popover receipt says.
6. Reproduce the workload that normally triggers crackling, with audio playing.
7. Verify an overload or abnormal-stop counter increments when the audible
   fault begins. **If it does not, this Mac is not publishing the notification
   Fennec relies on, and a second detector is needed**; that is the single
   most important thing this step can tell you.
8. Confirm a repair that holds turns the receipt gold after the 60-second
   verification window, and that one that does not is reported honestly.
9. Only after all of the above, consider changing detection from **Balanced**
   to **Immediate**.

Also unverified because it needs root and a real registration:

- The uninstaller's daemon-unregister step, and its refusal to trash the app
  when that step fails.
- The helper's `ping` reply, so the About panel's "running as root" row and the
  version-mismatch warning are untested against a live daemon.
- Whether `applicationShouldTerminate`'s grace actually releases quit during a
  real privileged repair.
