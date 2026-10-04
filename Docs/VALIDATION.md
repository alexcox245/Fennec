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

The owner supplied a build 1 event-log excerpt on 2026-09-25. It confirms
overload detection on a Bluetooth output, repeated automatic skips under the
Bluetooth safety setting, a manual repair request and successful restart,
output-device reconnection events, and a `repairHeld` result after the quiet
verification window. Those records do not establish audible playback quality,
automatic repair on an eligible output, helper registration or removal,
notification delivery, or a signed update install. The exact build hash and
macOS version were not provided. The current build 3 candidate needs fresh
checks. Keep automatic repair at **Balanced** until these gaps are closed.

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
   fault begins. If it does not, check whether the log witness detects the
   overload before concluding that detection is unavailable on that Mac.
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

## Repair fox validation (T-045, 2026-09-23)

The animation was exercised in an isolated AppKit harness compiled from
`FoxRunMotion`, `FoxRunAsset`, and `RepairFoxController`. The harness contains
no `AppModel`, Core Audio monitor, helper manager, or privileged repair code.
It did not install or run the helper or restart audio.

Verified:

- All 278 unit tests pass, including 12 fox cases covering original GIF delays
  and alpha, Retina decoding, stride scaling, complete entry/exit, Dock clearance,
  negative and vertically arranged display coordinates, invalid inputs,
  duplicate requests, late cancellation, and preference persistence.
- App and helper build in both Debug and Release with the four known compiler
  warnings only. Xcode also emits its existing App Intents metadata warning.
- Source audit and manifest verification pass. Release signature verification
  passes against the normal trust store, with Team ID `249X253HS3`.
- A native crossing on the pointer's external display, with a negative X origin,
  visibly faces right and advances left to right. Presentation-layer snapshots
  confirm that the drawing changes pose and stays transparent.
- During the crossing, the preview remains an inactive accessory application
  with no key or main window; the foreground app stays unchanged. WindowServer
  mouse hit testing passes through the sprite's position to the window below.
- The panel disappears on completion and on disabling the preference. It leaves
  no animation timer or visible window behind.

Environment notes: sandboxed signing/trust checks could not see the normal
keychain, and `xctest` could not open a test bundle built inside Documents.
The standard §5 commands, using Xcode's normal DerivedData location with access
to its build/test services, pass. No project signing settings were weakened.
Local logs and the disposable preview harness are in gitignored
`build/FoxRunValidation/`.

Still unverified: the overlay during a real privileged repair or administrator
prompt, full-screen/Stage Manager/Spaces transitions, physical display removal,
sleep/lock/wake, live changes to the system Reduce Motion setting, and the
Settings preview button in the running production app. These were not simulated
by changing the user's system settings or launching the audio-monitoring app.

## Onboarding repair test (T-049, 2026-09-24)

Fresh preferences select Automatic. The welcome window keeps **Try it now** and
**Run a Test Repair** visible above Done, following the setup steps in the
referenced Figma welcome screen. A test uses the same guarded repair and fox
path as a manual repair, but its receipt is labelled Test and does not count
as an incident. With no approved helper, Fennec asks before opening an
administrator prompt. Reduce Motion or the animation preference suppresses
the fox without suppressing the repair.

The 288 standalone tests, all four app/helper Debug and Release builds, and
source audit pass. Xcode Organizer notarized the updated archive as submission
`52B844F4-9549-4400-94D3-FBBF5D770032`; the exported and installed apps
pass `codesign --verify`, `stapler validate`, and Gatekeeper assessment. The
bundled running-fox GIF matches the checked-in asset. No test repair was
triggered by the agent. A person still needs to relaunch Fennec from
`/Applications` (use **What Fennec Does** if first run was completed earlier),
press **Run a Test Repair**, confirm any safety or
administrator prompt, and verify that sound returns and the fox crosses the
screen when motion is enabled.

## Fox bottom-edge placement (T-050, 2026-09-24)

The fox's feet are now anchored 10 points above the physical bottom of the
pointer's display, including when a bottom Dock reduces `visibleFrame`.
The transparent, mouse-pass-through panel uses status-bar level so the crossing
remains visible over the Dock. The macOS SDK reports floating level 3, Dock
level 20, and status-bar level 25. Unit tests cover the exact physical-bottom
coordinate on normal and negative-origin displays. All 288 tests pass, all four
app/helper Debug and Release builds succeed, and the source audit passes.
Xcode Organizer notarization `6CBADEBA-B864-44C8-9AC3-30070AE7DDD2` is
ready to distribute. The exported and `/Applications` copies pass signature,
stapled-ticket, and Gatekeeper checks; the installed binary and GIF hashes
match the export. No live repair was run. Fennec was running from the previous
bundle when it was replaced, so a person must quit and relaunch the app to
see the new crossing.

## Popover info-menu removal (T-051, 2026-09-24)

The footer's blue info/More button and its duplicate navigation are removed.
No destination was orphaned: Repair History and Reveal Event Log are in
Settings > Diagnostics; About & Uninstall is linked from Settings' helper
controls; What Fennec Does remains the first-run window and is also available
from the app's Help menu while a full window is open.

All 288 standalone tests, four Debug/Release app/helper builds, and the source
audit pass. Xcode Organizer notarized the archive as submission
`704A0F31-4555-4D4B-99A7-D01152859210`. The exported and installed builds
pass signature, stapled-ticket, and Gatekeeper checks. `/Applications/Fennec.app`
and both local Release copies match the exported binary. No live repair was
run. The Fennec process that was already running still has the previous binary
loaded and needs a manual quit/relaunch before inspecting the new popover.

## Onboarding repair and bounded fox replays (T-052, 2026-09-24)

The first **Run a Test Repair** click follows the existing safety and privilege
gates and attempts one real audio repair. The **Run Again** button only requests
animation from that first click onward, even while the safety check is still
preparing; it cannot call the helper, show an administrator prompt, or add a
repair receipt. The test does not set the app's automatic
repair cooldown. The explanatory "Watch the fox cross your screen" copy is
removed. Reduce Motion and the animation preference still suppress the fox.

The pure burst tests cap 300 clicks at ten accepted foxes (including the first),
five active foxes, and a half-second minimum between starts. An isolated AppKit
preview compiled from the actual animation sources, with no audio or helper
code, accepted exactly nine of 300 replay clicks after the first. It rendered
ten sprites in one click-through, nonactivating panel, never more than five
simultaneously; the smallest observed start interval was 0.500 seconds. The
preview report is in gitignored `build/OnboardingFoxValidation/report.json`.

All 290 standalone tests, all four app/helper Debug and Release builds, and
the source audit pass. Only the four catalogued compiler warnings remain.
No live audio repair, helper registration, or permission change was run by the
agent; the first-click audio path still needs a person's manual check.

Xcode Organizer notarized the final archive as submission
`C440D501-0BC4-4B0B-B86D-1B53A3B00124`. The exported app and the replacement
in `/Applications/Fennec.app` pass `codesign --verify`, stapler validation,
and Gatekeeper assessment; the executable hash is
`22684e2b4de70a6543bf5d8f0114277df70888065aebefe0a6681f719181743e`.
Both repository-local Release copies match. The previous installed bundle is
saved under gitignored `build/InstalledBackup/`. The Fennec process already
running during replacement still needs a manual quit and relaunch before this
new behavior appears.

## High `coreaudiod` CPU investigation (T-053, 2026-09-24)

The screenshot's `coreaudiod` PID 72014 was still using roughly one CPU core
when inspected. macOS's own CPU resource diagnostic for that PID covers
02:03:47–02:05:41 local time: 90 CPU seconds in 114 seconds (79% average).
Its heaviest sampled stack handles Core Audio property requests and enumerates
the system plug-in/device-manager list (`HALS_System::GetNumberPlugIns`). The
report attributes samples to loginwindow, Chrome, Spotify, system services,
and other clients, but none to Fennec. An earlier 01:21 diagnostic for a
previous `coreaudiod` PID was already at 90% average; it attributes one of
17 samples to Fennec. These reports show Fennec can make ordinary Core Audio
queries, but do not show it driving the sustained CPU. Fennec's monitoring
code does not request the plug-in list.

Fennec's event log records one successful user-requested restart at 01:59:30;
the next request at 01:59:45 was throttled and did not restart audio. PID 72014
started at 02:00:52, after that repair, and the log has no subsequent Fennec
restart. Core Audio's overload reports name Spotify and `systemsoundserverd`
as clients on the built-in headphone output. The Mac was under unusually heavy
overall CPU and memory load during inspection. Together, this points to a
system/client or plug-in bottleneck, rather than a Fennec repair loop; it does
not identify which plug-in or client is responsible. A direct `sample` of the
root-owned daemon was denied without administrator authorization, so no live
thread capture was taken. No repair, helper change, or process termination was
performed during this investigation. At 02:33, the same daemon PID still showed
96.9% CPU while the long-running Fennec process showed 0.0% in `ps`.

## Shared Repair Audio fox bursts (T-054, 2026-09-24)

The menu-bar popover, Settings, Audio menu command, prompted repair window,
and notification action now route through the same button entry point. The
first click takes the existing guarded repair path; later clicks during that
fox burst only request animation. Clicks are accepted during the safety scan,
so a slow check cannot cause extra repair attempts. The UI says **Run Again**
while replaying, and its help text explains that only the first click repairs
audio. Each ordinary burst clears after its last crossing, so a later press
can request a fresh repair. Onboarding keeps its one-test-per-window behavior.
All bursts share the limit of ten accepted foxes, five visible, and a
half-second minimum between starts. Cancelled and failed attempts discard
pending foxes; disabling animation or enabling Reduce Motion tears them down.
The standalone suite passes all 290 tests. All four app/helper Debug and
Release builds succeed; the Release app has only the four catalogued Swift
warnings. An isolated AppKit preview of the ordinary burst (no audio or
helper sources linked) accepted nine of 300 extra clicks, rendered ten foxes
in one nonactivating, click-through panel, observed at most five visible, and
confirmed the ordinary burst reset after the final crossing. Its report is
in gitignored `build/ManualFoxValidation/report.json`.

No live audio repair or helper registration was triggered for validation.
Xcode archived and uploaded the final build for Developer ID notarization
(distribution `9AA45BFE-C6EB-40F7-8E43-6142184B48CD`).
`xcodebuild -exportNotarizedApp` produced the stapled app, which passes strict
deep signature verification, stapler validation, and Gatekeeper assessment as
**Notarized Developer ID**. `/Applications/Fennec.app` and both repository-local
Release copies match that export's executable SHA-256,
`8635e622f94e17cfd9d9bf907d9b622e1e990a8d595af8f008d7c9dd1026650b`.
The previous installed bundle is preserved in gitignored
`build/InstalledBackup/`. The already-running Fennec process still has the
old code loaded and needs a manual quit/reopen to use this build.

## Fifteen simultaneous repair foxes (T-055, 2026-09-24)

The shared manual-repair and onboarding burst now accepts at most fifteen
foxes total and permits all fifteen to overlap, still starting each crossing
at least half a second after the previous one. Further clicks are discarded.
This changes animation only; a burst still makes one guarded repair request.
The burst unit test rejects the remaining 285 of 300 rapid requests and checks
that fifteen can be active together.

An isolated AppKit preview compiled from the production fox asset, motion, and
controller sources, without any audio or helper sources, accepted fourteen of
300 replays after its first crossing. Its report observed fifteen unique
sprites, fifteen visible at once in one nonactivating click-through panel,
approximately half-second spacing, and an automatic reset after the final
crossing. A second run sampled the preview and WindowServer every half second
for 42 samples: preview CPU averaged 0.6% and briefly peaked at 12.0% while
loading; preview resident memory peaked at 59.8 MB; WindowServer CPU averaged
2.3% and peaked at 5.2%. These local measurements support keeping fifteen,
though they do not measure every Mac or display configuration. Reports are in
gitignored `build/FifteenFoxValidation/`. No live audio repair or helper
registration was triggered.

All 290 unit tests, the four Debug/Release app/helper builds, and the source
audit pass. The Release build adds no compiler warnings beyond the four
catalogued in the task ledger. Xcode uploaded Developer ID distribution
`630ED763-1523-4C44-B3B0-5C0338B984DD` to Apple. Xcode's account-based
notarized export could not read its saved account credentials, so the same
archive was exported with the local Developer ID certificate and Apple's
available ticket was stapled to it. Strict deep signature verification,
stapler validation, and Gatekeeper assessment all pass as **Notarized Developer
ID**. `/Applications/Fennec.app` and both repository-local Release copies
match the verified export's executable SHA-256,
`8b91d5029d22f6bab64d36635668b95cb3f097dd0e01a1dd71458337a48cd8fb`.
The prior installed copy is preserved in gitignored `build/InstalledBackup/`.
The already-running process must be quit and reopened manually to load this
build.

## One hundred simultaneous repair foxes (T-056, 2026-09-24)

The shared onboarding and manual-repair burst now accepts no more than one
hundred foxes, with the visible cap also at one hundred. The minimum start
spacing is 40 milliseconds so one hundred can overlap on a normal display;
keeping the previous half-second spacing would make that impossible on the
tested screen. Later clicks are discarded, and only the first click in a burst
takes the guarded audio-repair path.

An isolated AppKit preview using the production asset, controller, and motion
code, with no audio or helper code linked, accepted 99 of 300 extra requests.
It rendered 100 unique sprites and 100 visible at once in one nonactivating,
click-through panel, then reset automatically after the last crossing. Its
50-millisecond sampling timer's largest observed gap was 55 milliseconds.
Across 60 half-second resource samples, preview CPU averaged 1.1% and peaked
at 29.5% during startup; resident memory peaked at 54.2 MB. A fresh fifteen-fox
run on the same busy Mac averaged 0.6% preview CPU. WindowServer averaged
50.2% during the hundred-fox run and 47.4% during the fifteen-fox run; a
separate idle sample averaged 41.1%. The Mac's changing background load makes
those compositor numbers approximate, but they show some additional cost at
one hundred rather than zero impact. Reports are in gitignored
`build/HundredFoxValidation/`. No live audio repair or helper registration was
triggered.

All 290 unit tests, the four Debug/Release app/helper builds, and the source
audit pass. Only the four catalogued Swift warnings remain. Xcode uploaded
Developer ID distribution `3B6BD1AF-A381-46B7-AD3E-7C259A535DD8` to Apple;
the exported app was stapled with Apple's available ticket. Strict deep
signature verification, stapler validation, and Gatekeeper assessment pass as
**Notarized Developer ID**. `/Applications/Fennec.app` and both repository-local
Release copies match the verified executable SHA-256,
`fba7d28934a82d3b07b90106808807f599f9bfebcbc2a0bfea5e67be2ebe416d`.
The previous installed copy is preserved in gitignored
`build/InstalledBackup/`. The already-running process still has the older code
loaded and must be quit and reopened manually to use this build.

## Launch readiness review (T-058, 2026-09-24)

**Verdict: not ready to merge or launch.** This review covers local branch
`codex/repair-fox-overlay` at `15b2a601890d122c7bb3a0979795cd01ead49853`
plus its existing working-tree changes. Remote main is
`566fd889feb78836a455583f230a7ef89b09bc7e`. No product code was changed by
the review. The ledger and this report record the findings; the source
manifest was regenerated.

On macOS 26.5.1 (25F80), Xcode 26.6 (17F113):

| Check | Result |
|---|---|
| App and helper, Debug and Release, signing enabled | All four pass; the four known Swift warnings remain, with no new compiler warnings |
| Standalone unit tests, exact command from AGENTS §5 | 290 tests, zero failures; `TEST SUCCEEDED` |
| Source audit and manifest | Pass |
| Fresh Release deep/strict signature | Pass; app and helper both carry Team ID `249X253HS3` and Apple Development signatures |
| Fresh Release bundled GIF | SHA-256 matches current source, `7145500fd569b9d96744c34ca37208bf3afbe0455eb584d4ac82d090f08588ae` |
| Gitleaks 8.30.1, all local Git refs | 60 commits scanned, no matches; all five remote branch tips are present locally |
| Gitleaks, copied tracked working-tree files | No matches |
| Existing T-056 Developer ID export | Deep/strict signature, stapler validation, and Gatekeeper assessment pass as Notarized Developer ID |

The first source-audit attempt was prevented by sandbox restrictions on
Xcode/SwiftPM caches; it passed with normal toolchain access. Tests using a
new DerivedData directory beneath the repository failed before executing any
test: XCTest could not create a bundle instance for the generated `.xctest`.
The bundle and executable existed. Re-running the exact documented command
with Xcode's normal DerivedData location passed all 290 tests. The cause of
the alternate-directory runner failure was not established; it was not an
assertion failure and was not hidden by changing the tests.

### Merge blocker: automatic repair after a changed decision (T-059)

In `AppModel.respondToDetection`, the mode, pause, and output checks precede
asynchronous helper recovery. After `await healSilentHelper`, the code only
checks reachability before requesting an automatic repair. `performRepair`'s
entry guard checks update installation and an existing repair, but does not
recheck mode, pause, or the detected output. A person can choose **Ask me
first**, pause Fennec, or change output while recovery is suspended and still
get an automatic system-wide restart when it resumes.

An isolated Swift probe copied the current `respondToDetection` method
verbatim and used inert dependencies plus the actual `performRepair` entry
guard with a counter replacing its body. It suspended helper recovery,
changed each state, and resumed with the helper reachable:

```text
ask-first: simulated repair calls=1, prompts=0
pause: simulated repair calls=1, prompts=0
output-change: simulated repair calls=1, prompts=0
```

The probe linked no app, audio, XPC, or helper implementation and performed
no privileged operation. This demonstrates the control-flow defect; it is
not a live repair test. Recheck current consent and safety gates after
asynchronous work and add regression coverage before merging.

### Candidate and distribution gaps (T-060–T-062)

- The branch is four commits ahead of remote main, with 19 modified tracked
  files already present at review start. No candidate branch, open pull
  request, release tag, or release is published. The most recent successful
  GitHub CI run is for the older main commit, not this candidate. Local
  `.claude/` worktrees and `Brand/fennec-walk.svg` are untracked.
- The verified T-056 export in `build/t056-local-export/Fennec.app` and
  `/Applications/Fennec.app` still contain GIF SHA-256
  `63d6d9211c57485482c481d7371a0114ef6dfc3debdf96b934614505f229a566`.
  They omit the current approved T-057 frame corrections. The freshly built
  current-source app is development-signed; this review did not create a
  new Developer ID export or submit anything to Apple.
- GitHub reports the repository as private. Anonymous access to
  `https://github.com/alexcox245/Fennec/releases/latest/download/appcast.xml`
  returns HTTP 404. No prepared release notes or production appcast were
  found in the reviewed build outputs. A final signed archive and signed
  feed must be generated and checked against the final source before launch.
- README still says there is no notarized release and instructs visitors to
  build with Xcode. Its validation section carries obsolete test and signing
  claims. UNINSTALL references the removed More menu, omits update-cache
  cleanup, and incorrectly states there is no networking code.
- SECURITY refers to an email on the maintainer's public GitHub profile;
  its public email, bio, and website fields are empty. The private-reporting
  endpoint returned 404 for this private repository, so reporting is not
  verified. Provide a contact or enable and verify
  [GitHub private vulnerability reporting](https://docs.github.com/en/code-security/how-tos/report-and-fix-vulnerabilities/configure-vulnerability-reporting/configure-for-a-repository)
  when the repository becomes public.

### Product Hunt and hands-on evidence (T-063, T-064, T-005)

No Product Hunt listing copy or gallery screenshots were found in the project
files reviewed. Prepare the public product/download URL, tagline and
description, square thumbnail, at least two gallery images, maker details,
and first comment. A GitHub product page is acceptable; a separate landing
site is optional. These requirements were checked against Product Hunt's
[launch preparation guide](https://www.producthunt.com/launch/preparing-for-launch)
and [posting instructions](https://help.producthunt.com/en/articles/479557-how-to-post-a-product).
An external draft or separately stored artwork may exist but was not supplied
or inspected. Nothing was posted or scheduled.

The owner reports having completed additional hands-on checks. The exact
tested archive/build, macOS version, and repair, playback, held/returned, and
removal results were requested but have not yet been supplied in this review.
Do not interpret the older “nothing below has been done” paragraph as a
finding that these owner-run checks never happened. Reconcile the evidence
and close T-005 only for the checks it establishes. The signed updater's
check/download/install/cancel/relaunch and helper restoration need separate
results (T-064); the existing standalone tests do not exercise that lifecycle.

No app was launched, helper installed/registered, audio restarted, or existing
installation replaced during the review. No commit, push, merge, visibility
change, GitHub release, or Product Hunt publication was performed. Logs,
secret-scan reports, the isolated probe, and fresh build products are in
gitignored `build/readiness-20260924/`.

## Release preparation follow-up (2026-09-25)

The automatic-repair race from T-059 is fixed in `AppModel`. After helper
recovery, Fennec rechecks current consent, pause, output, episode, console
session, update preparation, Bluetooth preference, and audio-use protection
settings. The final repair entry checks again before moving to `isRepairing`.
An isolated Swift probe with the production response method and inert repair
counter now records zero automatic calls after switching to Ask first, pausing,
or changing output while helper recovery is suspended; Ask first prompts once.
It links no live audio, XPC, or helper code. The 290 standalone unit tests and
all four app/helper Debug/Release builds pass after the final Bluetooth
recheck; the four existing Swift warnings remain. The source audit passes
after manifest refresh.

The owner supplied build 1 events from 2026-09-24. The logs show repeated
processor-overload detections on an AirPods Bluetooth output and matching
automatic-repair skips. A manual repair was requested at 16:05:36 UTC,
reported success at 16:05:38, logged output reconnection events, and was
marked held at 16:06:38. An advisory later reported playback stalls under
heavy system load. These are evidence of signal detection and one provisional
repair that held, not evidence of audible recovery, automatic repair on an
eligible output, helper removal, or signed update installation. No build hash
or macOS version accompanied the excerpt. T-005 and T-064 remain open.

The final build 2 source was archived and exported with Developer ID. The export's app and
helper verify with Team ID `249X253HS3` when normal Keychain trust access is
available; sandboxed verification returned a false invalid-signature result.
The exported bundle contains version `1.0` build `2`, the Utilities category,
and the same approved GIF hash as source (`7145500f…`). A local draft ZIP and
Sparkle-signed appcast were generated, and the appcast signature verifies.
They are **not distributable**: the ZIP has not been notarized or stapled, and
the feed must be regenerated after stapling changes the archive. The
`fennec-notary` Keychain profile is absent. The final export in
`build/ReleaseCandidate/DeveloperID-verified/` has executable SHA-256
`436ae22020d9802ec893b975c72f73257ad06dc5a824aea2876c7fc91af3a879`.
Automatic approval review rejected uploading the private signed app to Apple
for notarization because external artifact transmission was not specifically
authorized; no upload was attempted through another path.

The public README and removal instructions were updated. A Product Hunt kit
with an icon thumbnail, two branded illustrations, listing copy, and a first
comment is in `Brand/ProductHunt/`. Public repository/release links, the
Product Hunt listing, the signed feed, and the updater lifecycle remain
unverified or unpublished. No real repair, helper registration, app install,
merge, repository visibility change, or public posting was performed here.

## Public notarized release — 2026-10-04

Fennec 1.0 build 3 is published at
[GitHub Releases](https://github.com/alexcox245/Fennec/releases/tag/v1.0),
which the live website's two Download buttons reach through `releases/latest`.
The release tag points to `59f97b2`; app/helper/project/test sources are unchanged
from the verified archive's source `74b6fe6`. Removing signatures from temporary
executable copies proves the notarized app and helper match that archive.

Xcode Organizer's Direct Distribution submitted the current build 3 archive,
and Apple accepted submission `3551DE23-B788-420A-BED3-5F7C937A9177`.
Export Notarized App produced `build/WebsiteRelease/Fennec.app`. The command-line
`fennec-notary` profile remains absent; the successful path used Xcode's existing
signed-in account. The old build 2 exports and appcasts were not reused.

- All four signed app/helper Debug and Release builds pass.
- All 298 standalone tests pass with zero failures.
- The source audit and regenerated source manifest pass.
- Only the four catalogued Swift warnings remain; Xcode also emits its existing
  App Intents metadata notice for the app target.
- Strict signatures verify for the app, embedded helper, and Sparkle contents.
  App and helper have Team ID `249X253HS3` and Developer ID signatures, with
  hardened runtime and no debugger entitlement.
- `stapler validate` succeeds and `spctl --assess --type execute` reports
  `accepted`, `source=Notarized Developer ID`.
- A fresh Sparkle feed selects build 3. CryptoKit verifies both its embedded
  Ed25519 feed signature and its archive enclosure signature against the
  notarized app's `SUPublicEDKey`. Automatic update checks, downloads,
  installation, and system profiling remain disabled; signed feeds are required.
- GitHub's uploaded digests match all four local release assets.
- Anonymous public ZIP and feed downloads match the local files byte for byte.
  The downloaded app passes strict signatures, ticket validation, and Gatekeeper;
  its feed and archive signatures verify against its own public key.
  The versioned archive URL and website's latest-release destination both return
  HTTP 200. Slow transfer/connection timeouts were recovered with range requests;
  no credentials were used for the public downloads.

Both ZIP assets have SHA-256
`523e863d162caa7ce07f9397d00fed158b303d69286a706015088bf2653137f4`.
The app executable has SHA-256
`ff34b2d5eabc18bcf8ed285f8986c455e0bd02b17e3e49ce38bd9cc2089716da`.

No app installation, app launch, helper registration, audio repair, or updater
installation was performed. T-005 and T-064 remain open. The existing security
findings T-091–T-096 remain open and are linked from the public release notes.


## Updater verification started 2026-10-04 (T-064)

The installed `/Applications/Fennec.app` is version 1.0, build 2, running as
PID 926. A read-only launchd inspection shows its existing helper running
as PID 934, with parent bundle version 2. The public feed offers build 3.
The installed app and published app use the same HTTPS feed URL and
Ed25519 public key. Automatic checks, downloads, installation, and system
profiling are disabled; signed feeds and verification before extraction
are enabled in both bundles.

A fresh anonymous appcast download verifies against the shipped public key
and the already-verified build 3 archive. The existing 17 update signature
and security-setting regression checks all pass. These checks do not
exercise the running updater's user driver or installation.

Computer Use timed out twice when selecting the installed menu-bar-only
app, and the system status-menu target timed out as well. The owner was
asked to open the About window so live checking and downloading can
continue. No update was installed, and no helper registration or audio
repair was performed. Check/download cancellation, Install & Relaunch,
repair-in-progress gating, helper unregister/restore, relaunch, and
approval-required fallback remain unverified; T-064 stays in progress.
