# AGENTS.md · Fennec

Operating guide for AI agents working on this repository. Read this file **before** touching code. If you change how the project is built, validated, or branded, update this file in the same commit.

---

## 1. Where this lives

| | |
|---|---|
| **Remote** | `https://github.com/alexcox245/Fennec` |
| **Default branch** | `main` |
| **Xcode project** | `Fennec.xcodeproj` (no standalone `.xcworkspace` or CocoaPods; Sparkle 2.10.0 is pinned through Swift Package Manager) |
| **Targets** | `Fennec` (app), `FennecHelper` (privileged helper), `FennecTests` (unit tests) |
| **Schemes** | `Fennec` (builds the app, runs `FennecTests`) and `FennecHelper`, both shared |
| **Bundle IDs** | `com.ludicrousdesigns.Fennec`, `com.ludicrousdesigns.Fennec.helper` |
| **Team ID** | `249X253HS3` |
| **Deployment target** | macOS 14.2 · Swift 5 language mode · arm64 |
| **Verified toolchain** | Xcode 26.6 (17F113) |

Sparkle 2.10.0 is the only external dependency. Xcode resolves it from the exact version pin and records the revision in `Fennec.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

---

## 2. What Fennec is

A local-first macOS menu-bar utility for one specific failure mode: Core Audio starts crackling under heavy local workloads and stays corrupted until `coreaudiod` is restarted. Detection, repair, logs, and repair history stay local. Sparkle contacts the signed release feed only after the user starts an update check.

Fennec watches the default output device for `kAudioDeviceProcessorOverload` and `kAudioDevicePropertyIOStoppedAbnormally`. When a threshold is met and safety checks pass, it restarts `coreaudiod` through a tightly scoped root helper, leaving every application open.

It is **not** sandboxed, by design: `SMAppService` daemon registration requires it.

---

## 3. Ground rules

These are load-bearing. Violating one produces a build that looks fine and fails in the field.

1. **Never do work in the real-time audio callback.** `Fennec/RTSignalCounters.c` and the Core Audio property listener may be invoked from a real-time I/O thread. Allowed: relaxed atomic increments on fixed preallocated storage. **Not** allowed: allocation, logging, `os_log`, locks, Swift closures, XPC, `dispatch_async`, string formatting, `print`. All higher-level work happens after a 250 ms timer drains the counters onto a normal serial queue.

2. **Do not weaken the privilege boundary.** `Shared/CodeSigningRequirement.swift` intentionally restricts identifier-only peer matching to `#if DEBUG`. Release builds require Team ID **and** bundle identifier on both sides of the XPC connection. Do not "simplify" that `#if` away.

3. **Do not add a general execution API to the helper.** `Shared/HelperProtocol.swift` exposes exactly two methods (`ping`, `restartCoreAudio`). The helper invokes fixed absolute executables with fixed arguments and verifies a new `coreaudiod` PID appeared. Never add a method that takes a command, path, or argument list from the app.

4. **Do not run the repair path or install the helper without explicit user approval.** `restartCoreAudio` kills audio system-wide for a moment; installing the LaunchDaemon needs root and a user approval in System Settings. Never `sudo ditto` into `/Applications`, never invoke `SMAppService` registration, and never trigger a repair as part of "just testing." Ask first, every time.

5. **Regenerate the source manifest after editing any tracked file** with `zsh Scripts/update-manifest.sh`. `audit-source.sh` verifies it and fails when it is stale, so skipping this breaks the audit rather than shipping quietly.

6. **Keep it a system utility.** Native macOS materials, typography, and controls stay intact. The brand lives in the icon, accents, and voice, not in a re-skinned UI. See §7.

7. **Never present an `.alert` or `.confirmationDialog` from the `MenuBarExtra` scene.** The popover is a panel that dismisses the moment it resigns key, and presenting an alert *is* what makes it resign key. The dialog flashes and vanishes, on the code path that restarts the audio system. Ask inline with `PendingConfirmation` instead. Settings may use a sheet, but it renders the same `PendingConfirmation` so the two cannot disagree.

8. **Fennec must stay removable, and the daemon is the part that is not.** Dragging the app to the Trash leaves the root LaunchDaemon registered in Background Task Management, the login item in place, and the support folder on disk; anyone can demonstrate this in thirty seconds. `Uninstaller` unwinds all of it and reports failures **per step**, because "uninstall failed" tells a user nothing they can act on. A helper or login item awaiting macOS approval is still registered and belongs in the removal plan. New Applications installs register the login item by default, while an existing Off choice is kept; do not delete that preference until the bundle has moved to the Trash, or a failed uninstall can re-register the item on relaunch. `UNINSTALL.md` carries the command-line fallback for the case where the app is already gone. If you add anything that persists outside the bundle, including Sparkle's update cache, add it to `UninstallPlan.steps` in the same commit.

9. **A repair is provisional until it holds.** The instant `restartCoreAudio` returns, the only established fact is that a new `coreaudiod` PID exists; whether the *fault* is gone takes a minute of quiet to find out. `RepairRecord.outcome` tracks that (`pending` → `held` or `returned`), the headline tally counts only repairs that held, and aviator gold is not spent until one does. Three automatic repairs inside twenty minutes that did not hold trips `RepairGovernor`, and Fennec stands down for an hour rather than looping every 45 seconds on a machine where the restart is not the cure. Do not make the UI call a repair "fixed" from `succeeded` alone.

10. **Every privileged path is disclosed in `PrivilegeDisclosure.swift`.** The helper's two XPC methods and the administrator-prompt repair path are only part of the picture: installing a signed update may also require authorization to replace Fennec in `/Applications`. A user who is asked for a password must have been told why. If you add a way for Fennec to act with privilege, it goes in that file, and `FirstRunTests` checks the exact repair command and the disclosed update behavior.

11. **Every window goes through `WindowPresenter`, including Settings.** Fennec is `LSUIElement`, so it has no main menu, which silently breaks ⌘W, ⌘Q and ⌘, in any window it opens. `WindowPresenter` is `.accessory` while only the popover shows and `.regular` for exactly as long as a real window is open, so the standard shortcuts work whenever there is something to type them at. Do **not** reintroduce SwiftUI's `Settings` scene: its only programmatic entry point is the undocumented `showSettingsWindow:` responder action, which reports success and then does nothing in an accessory app (verified on macOS 26). Never decide activation policy by counting `NSApp.windows` without filtering; the `MenuBarExtra` popover is an `NSStatusBarWindow`, and counting it strands the app in `.regular` forever.

12. **User-facing repair copy lives in `RepairCopy.swift`, and it is under test.** The notification, the menu receipt, and the activity list must say the same thing in the same voice. `FennecTests/RepairCopyTests.swift` pins the exact strings, including checks that repair outcomes do not shout, use emoji, say "Core Audio", or state a timing. The owner-approved Settings animation opt-out line is the one emoji exception (T-076). If you need new copy, add it there rather than inlining a string in a view. See §7 for the register and for the three places precision still wins.

13. **Updates are explicit at every step.** Sparkle checks only after the user asks, downloads only after the user chooses, and installs only after **Install & Relaunch**. Keep automatic checks, downloads, installation, and system profiling disabled. The Ed25519 private key stays in the login Keychain; only its public key belongs in `Fennec/Info.plist`. Before installation, wait for a repair to finish and unregister a previously registered helper. Restore only that prior registration after relaunch; if approval is needed, fall back to **Ask me first**. **Ask me first must not trigger background helper-registration repair.** See `Docs/UPDATES.md` for the release flow.

---

## 4. Source map

```
Fennec/                        app target (Swift + 1 C file)
  FennecApp.swift              @main, MenuBarExtra scene, FennecBrand color tokens
  AppModel.swift               orchestrator: state, cooldown, safety gating, repair decisions
  MenuView.swift               menu-bar popover UI
  SettingsView.swift           Settings scene
  SettingsStore.swift          UserDefaults-backed preferences
  CoreAudioMonitor.swift       attaches/rebuilds the listener graph
  SystemLogMonitor.swift       the second witness: coreaudiod's overload log
  OverloadLogSchedule.swift    when to pay for a log query, and line→event grouping
  StallAdvisor.swift           the stall verdict: starved Mac, restart won't help
  SignalGraphView.swift        the popover's rolling 30 s signal strip
  DraggableAppIcon.swift       the app icon as a drag source, for onboarding
  CoreAudioProperty.swift      typed AudioObject property reads
  CoreAudioTypes.swift         AudioTransport, snapshots, AudioSignalKind
  RTSignalCounters.{c,h}       real-time-safe atomic counters  ← see rule 1
  Fennec-Bridging-Header.h     exposes RTSignalCounters to Swift
  DetectionEngine.swift        time-window threshold → DetectionDecision
  RecoverySafetyChecker.swift  blocks repair during mic input / protected apps
  HelperManager.swift          NSXPCConnection lifecycle to the root helper
  PrivilegedPromptRepair.swift fallback manual repair via admin prompt
  LoginItemManager.swift       launch-at-login via SMAppService
  EventLogger.swift            rotating JSONL audit log
  NotificationController.swift user notifications
  RepairHistoryStore.swift     persisted repair receipts + RepairSummary
  RepairCopy.swift             every user-facing sentence about a repair  ← see rule 12
  SetupChecklist.swift         pure readiness model behind every setup CTA
  NotificationBudget.swift     rate limiter for the one banner class that bursts
  SystemEvents.swift           wake/unlock/session quiet windows + console-session gate
  PendingConfirmation.swift    the inline confirmation card's model  ← see rule 7
  MenuBarIcon.swift            the fennec silhouette, drawn as a template NSImage
  WindowPresenter.swift        every window + activation-policy switching  ← see rule 11
  RepairFoxController.swift    click-through repair crossing and bounded onboarding replays
  FoxRunMotion.swift           stride timing, screen geometry, and onboarding burst limits
  FoxRunAsset.swift            off-main GIF decoding with the original frame delays
  Resources/fennec-run.gif     approved run cycle, mirrored at display time
  AppDelegate.swift            reopen and quit-during-repair handling
  SetupStepRow.swift           one setup step, shared by the popover and Settings
  WelcomeView.swift            first run: repair mode, setup, visible test repair
  PrivilegeDisclosure.swift    every privileged path, stated once  ← see rule 10
  InstallLocation.swift        guards the /Applications requirement
  ConfirmationPresentation.swift  the confirmation sheet for real windows
  PauseSchedule.swift          pause durations and the persisted pause state
  RepairGovernor.swift         verification window + the stand-down breaker  ← see rule 9
  AboutView.swift              the privilege panel: what runs as root, and removal
  Updater.swift                manual Sparkle updates, signed feed, and install gate
  Uninstaller.swift            the removal plan, and performing it  ← see rule 8
  HelperIdentity.swift         parses the helper's ping reply (build + path)
  ActivityView.swift           every repair, grouped by day
  DaysWithoutIncident.swift    the sign on the wall  ← see §7
  DrainSchedule.swift          how often to drain the RT counters
  FennecBrand.swift            colour tokens + the outcome accent
Shared/HelperThrottle.swift    the helper's rate-limit marker, both targets

FennecHelper/                  root LaunchDaemon target
  main.swift                   NSXPCListener bootstrap
  HelperService.swift          the only privileged action

Shared/                        compiled into BOTH targets
  AppConstants.swift           bundle IDs, Mach service name, file names
  HelperProtocol.swift         the XPC contract
  CodeSigningRequirement.swift peer requirement construction  ← see rule 2

LaunchDaemons/                 plist copied to Contents/Library/LaunchDaemons
LICENSE · SECURITY.md · UNINSTALL.md · CHANGELOG.md
.github/workflows/ci.yml       audit + tests + build matrix + a warning ceiling
FennecTests/                   standalone XCTest bundle (no TEST_HOST)

Scripts/                       audit-source.sh, build-release.sh, update-manifest.sh
Docs/                          ARCHITECTURE.md, VALIDATION.md, UPDATES.md,
                               RELEASE_NOTES_v1.0.md, SOURCE_MANIFEST.sha256
Brand/                         Fennec-AppIcon-Master.png (1254×1254), README.md,
                               ProductHunt/ (launch copy and image assets)
```

Read `Docs/ARCHITECTURE.md` for the detection path, suppression windows, and failure behavior. It is accurate and current.

---

## 5. Build, verify, commit

All commands run from the repo root.

**Build (this is the exact invocation that is known green; no signing overrides needed):**

```bash
xcodebuild -project Fennec.xcodeproj -scheme Fennec \
  -configuration Release -destination 'platform=macOS' build
```

Swap `-scheme FennecHelper` and `-configuration Debug` to cover the matrix. All four combinations build clean as of the current `main`.

**Read the result without drowning in log noise:**

```bash
xcodebuild ... build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | sort -u
```

**Static audit (plists, required files, helper packaging, per-file Swift parse, C warnings):**

```bash
zsh Scripts/audit-source.sh
```

**Full release verification (audit + clean build + bundle layout + `codesign --verify`):**

```bash
zsh Scripts/build-release.sh
```

Writes to `build/DerivedData/`, which is gitignored. It ends by *printing* the `/Applications` install commands; it does not run them. Do not run them yourself (rule 4).

**Cut a notarized direct-download release:**

```bash
zsh Scripts/release-developer-id.sh
```

Archives with Developer ID, exports, notarizes, staples, zips, and finishes with the exact `spctl` assessment Gatekeeper runs on a downloaded copy. Its preflights fail loudly with the one-time setup steps (a Developer ID Application certificate for the team, and `xcrun notarytool store-credentials fennec-notary`; override the profile name with `FENNEC_NOTARY_PROFILE`). Distribution is **direct download only**: the Mac App Store requires App Sandbox, which `SMAppService` daemon registration rules out (§2), and would not admit a root helper that kills `coreaudiod` in any case.

**Regenerate `Docs/SOURCE_MANIFEST.sha256` after editing tracked files:**

```bash
zsh Scripts/update-manifest.sh
```

It rebuilds the manifest from `git ls-files` plus anything staged for addition, so new files are picked up automatically. `audit-source.sh` verifies the manifest with `shasum -c` and fails if it is stale, so a forgotten regeneration is caught instead of silently shipped.

**Run the unit tests:**

```bash
xcodebuild -project Fennec.xcodeproj -scheme Fennec \
  -configuration Debug -destination 'platform=macOS' test
```

`FennecTests` is a **standalone** XCTest bundle with no `TEST_HOST`: it compiles Fennec's pure-logic sources directly instead of loading the app. That is deliberate. Hosting the tests in `Fennec.app` would start Core Audio monitoring, request notification authorization, and touch the user's real Application Support directory on every run. Anything that talks to Core Audio, `SMAppService`, or XPC is **not** unit-testable here and belongs in [T-005](#open).

To put another source file under test, add a `PBXBuildFile` for its existing `PBXFileReference` to the `FennecTests` Sources phase (or drag it into the target in Xcode).

### Definition of done

A change is not done until:

- [ ] `Fennec` and `FennecHelper` build in **both** Debug and Release
- [ ] `xcodebuild … test` passes with no failures
- [ ] `zsh Scripts/audit-source.sh` passes
- [ ] No **new** compiler warnings (4 pre-existing ones are catalogued in [T-007](#open) / [T-008](#open))
- [ ] `Docs/SOURCE_MANIFEST.sha256` regenerated
- [ ] The task ledger in §8 updated: entry moved to Done, or a new entry appended
- [ ] Anything requiring a physical device or root is explicitly listed in your report as *not verified*

### Git conventions

Work on a branch; `main` is the release line. Commit messages: a short subject, then *why* in the body. If an AI agent produced the change, end the message with a `Co-Authored-By:` trailer naming the agent.

Do not commit `build/`, `DerivedData/`, `xcuserdata/`, or `.DS_Store`; `.gitignore` already covers all four. Do not push or open a PR unless asked.

---

## 6. Known traps

Each of these has already cost real time. Do not rediscover them.

**`SecCode` vs `SecStaticCode`.** `SecCodeCopySigningInformation` is typed to take a `SecStaticCode`. `SecCodeRef` and `SecStaticCodeRef` wrap the same opaque C struct and the C API accepts either, but Swift imports them as unrelated types. `Shared/CodeSigningRequirement.swift` bridges with `unsafeBitCast`. That is correct; do not "fix" it into a `SecCodeCopyStaticCode` round-trip, which reads the on-disk image and can fail if the bundle moved.

**`path` is a reserved variable in zsh.** zsh ties `$path` (array) to `$PATH` (string). Using `path` as a loop variable in any script under `Scripts/` silently destroys `PATH`, and every subsequent command dies with `command not found`. This bit `audit-source.sh`, where it surfaced as the *misleading* error "The helper copy phase is not targeting the app Executables directory." Both scripts are `#!/bin/zsh` with `set -euo pipefail`. Other zsh-tied names to avoid: `cdpath`, `fpath`, `manpath`, `argv`, `status`.

**The helper is embedded in `Contents/MacOS/`, not `Contents/Library/LaunchServices/`.** This is the modern `SMAppService` daemon layout, not the legacy `SMJobBless` one. `audit-source.sh` asserts `dstSubfolderSpec = 6`, `CodeSignOnCopy`, `ENABLE_DEBUG_DYLIB_SUPPORT = NO` in both helper configurations, and that the LaunchDaemon's `BundleProgram` is `Contents/MacOS/FennecHelper`. If you touch the project file, re-run the audit.

**`ENABLE_DEBUG_DYLIB_SUPPORT = NO` is deliberate** on the helper. Xcode's debug-dylib splitting breaks a daemon that must be a single signed Mach-O.

**SourceKit/IDE diagnostics can disagree with the compiler.** Trust `xcodebuild` output over in-editor squiggles.

**"Builds green" never meant "signed with a Team ID"; until T-029 it meant the opposite.** The project shipped with `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"` (ad-hoc) on the app target, so every build passed `codesign --verify` while carrying `TeamIdentifier=not set`. Rule 2's Release XPC requirement demands a Team ID on both sides, so the helper could never have answered a Release app. The app and helper targets now sign with `Apple Development` under team `249X253HS3` (A & A Design Inc.); `FennecTests` deliberately stays ad-hoc. If a build machine lacks the team's certificate, signing fails loudly. That is preferable to the silent ad-hoc fallback this trap documents. Verify with `codesign -dv <app> | grep TeamIdentifier`, not just `--verify`.

**`Docs/VALIDATION.md` is a point-in-time report, not a live status.** Treat §5 of *this* file as the authority on how to build.

---

## 7. Brand direction

Everything below is derived from `Brand/Fennec-AppIcon-Master.png`. When a decision is ambiguous, go back to that image.

### The image, read literally

A cream fennec fox, dead-centre, cropped tight and facing you head-on. Enormous ears run off the top of the frame. Gold-rimmed aviators. Full-size **open-back** headphones with visible driver mesh, cables trailing down out of frame. Behind: a flat cobalt sky and two orange dune ridges (one bright, one in shadow) meeting at a lazy diagonal. No texture, no gradient, no noise. Hard-edged vector shapes and a mouth that is not smiling.

### What it means

Three ideas in tension, and the tension *is* the brand:

**Audiophile precision.** The headphones are the tell. Open-back cans leak sound in every direction; nobody wears them on a train. They mean a person who sits still in one room and cares what the soundstage does. That is Fennec's actual claim: it is not a general "sound fixer," it detects one specific Core Audio failure that only people who notice would notice.

**Punk stance.** Not punk *ornament*: there is no distressed texture, no ransom-note type, no chaos in this art, and there should be none in the UI. The punk is in the posture: a small tool that fixes the thing itself instead of filing a radar and waiting. No telemetry or account; monitoring and repair stay on the Mac, and update checks happen only when asked. It restarts a system daemon on your behalf and doesn't make a ceremony of it. DIY, self-hosted, unbothered.

**Desert stillness.** Deadvlei at noon. Flat light, no weather, nothing moving. A fennec is a listening animal; the ears are oversized precisely because the desert is silent and it is built to detect the one signal that matters. That is the product, drawn.

Composite: **a calm, oversized listener in a silent place, wearing gear that means business, that will quietly fix your audio and never mention it again.**

### Voice

Deadpan, specific, plain. Confident without selling. The fox is not grinning and neither is the copy.

**Two hard rules, set by the owner in T-043 and enforced by `RepairCopyTests`:**

1. **Never say "Core Audio" in anything a user reads.** Nobody installs Fennec because they know what Core Audio is. They heard a crackle and want it gone. Say crackle, sound, speakers, repair.
2. **Never state a timing in user-facing copy.** "Fixed in 0.54 s" answers a question nobody asked. Counts, spans, load averages and memory pressure all belong in the event log, not in a banner.

| Do | Don't |
|---|---|
| "Donesies" | "Core Audio restarted in 0.84 s." |
| "Repeated crackling on MacBook Pro Speakers." | "2 crackle signals in 5.8 s on MacBook Pro Speakers." |
| "Repair Audio Now" | "Fix My Sound!" |
| "Skipped: microphone is active." | "We couldn't do that right now." |
| "This Mac is working too hard to keep up." | "load 1.47 per core, memory pressure warning" |

Plain is not vague. Still name the thing that happened and admit the limitation: Fennec hears the failure signal, not the sound itself, and it says so. No exclamation marks, no emoji in repair outcomes, no anthropomorphising the fox in repair outcomes. The owner explicitly set the playful Settings preview and disabled-animation copy in T-076, including one emoji when the animation toggle is off; keep that exception scoped to the animation setting.

The owner-approved balanced sensitivity description ends, “You hear the crackle begin. Then silence. Then your sweet sweet beats.” Preserve that line when editing the menu-bar and Settings sensitivity text.

**Where precision still wins, and must not be plainened:**

- **The event log** (`EventLogger`, `events.jsonl`). A diagnostic artifact with a technical reader. Counts, spans, OSStatus codes, `coreaudiod`, all of it stays. `DetectionDecision` carries both: `reason` for the log, `plainReason` for the banner.
- **`PrivilegeDisclosure.swift` and the About panel** (rule 10). This is the disclosure of what runs as root. Vagueness here is not friendliness, it is concealment. It names `coreaudiod` and the literal command on purpose, and `FirstRunTests` checks the disclosed command against the executed one.
- **Internal error strings** carrying an OSStatus or an XPC failure. They surface rarely, and when they do the reader needs the code.

### Palette

Two columns, because they currently disagree. **Left** is what ships today (`Brand/README.md`, mirrored as floats in `FennecBrand` in `Fennec/FennecApp.swift`). **Right** is sampled directly from the master art.

| Role | Shipped token | Sampled from art | Δ |
|---|---|---|---|
| Sky | `#2E82CC` | `#2373C3` | shipped runs lighter/brighter |
| Dune | `#F47A1F` | `#EF792D` | shipped runs more saturated |
| Cream | `#FFE3AB` | `#FDDCAF` | shipped runs warmer |
| Sand | `#EFB76E` | `#ECB478` | near-identical |
| Ink | `#1F1F1C` | `#2C2927` | shipped runs materially darker |

The drift is small but consistent and nothing reconciles it. Resolving it is [T-009](#open); **do not silently restyle the app to close the gap**, it is a design call for the owner.

Three colours exist in the art with **no token at all**. They are the most characterful part of the image and the palette is poorer without them:

| Role | Hex | Where it comes from |
|---|---|---|
| **Aviator gold** | `#DA963E` | the sunglass frames: the single warm-metal accent |
| **Lens void** | `#23190E` | inside the lenses; a brown-black, not a neutral black |
| **Dune shadow** | `#BD5D26` | the darker ridge, for orange depth without going brown |
| **Twilight blue** | `#294D70` | shadowed blue, for depth against the sky |

Aviator gold is the highest-value addition: it is the only precious-metal note in an otherwise flat, matte palette, and it is exactly the audiophile-hardware cue (brass, VU needles, XLR pins).

### Colour semantics

Keep the existing mapping; it is already coherent:

- **Sky**: healthy, listening, nominal. The primary action tint (`.tint(FennecBrand.sky)` in `FennecApp.swift`). Blue means *Fennec is awake and hearing nothing wrong*.
- **Dune**: audio, output, and warning. Signals detected, thresholds approached, transient suppression.
- **Sand / Cream**: surfaces and mascot framing only. Never a state colour.
- **Ink**: text and hardware-adjacent chrome.
- **Aviator gold**: reserved, and now in use, for a repair that **held**. Not a repair that merely returned successfully (see rule 9). A rare, warm, earned accent, never a third warning colour.
- **Sand + ink together**: the days-without-incident sign, and nothing else. It is the one element that keeps fixed colours in both appearances, because a safety sign is a physical object and physical objects do not invert at dusk.

Blue and orange are complementary and near-maximum contrast at full strength. Do not put dune orange on sky blue in body text; use ink or cream on either.

### Form

- **Flat vector, hard edges.** No gradients, no drop shadows, no glass, no glow. The icon has zero soft edges and the UI should match.
- **Geometry over ornament.** The dune ridge is one lazy diagonal. Prefer one confident shape to three fussy ones.
- **Generous negative space.** The top third of the icon is empty sky. Let panels breathe.
- **Centred, symmetrical, frontal** for anything mascot-adjacent. The fox looks straight at you.
- **Crop confidently.** The ears run off the frame. Do not shrink art to fit a box.
- **System typography.** SF, native weights. The audiophile signal comes from precision and alignment, not a display face. If a monospace register is ever needed, reserve it for actual data (device names, PIDs, timestamps, counters), never prose.
- **Motion:** short, linear, unfussy. Nothing pulses for attention. The owner-approved exception (T-045) is a left-to-right fox crossing during a repair: the approved GIF's own gait and hop, linear travel with its feet 10 points above the physical bottom of the pointer's display (T-050), no extra bounce or celebration. Onboarding may replay the crossing after its one test repair, with one hundred total, one hundred visible, and 40-millisecond minimum spacing (T-056). Respect Reduce Motion and the user's animation preference. This is activity, not evidence that the repair held.

### Anti-patterns

Waveform/equalizer bar clichés · neon or cyberpunk gradients · distressed grunge or torn-paper "punk" textures · glassmorphism · cartoon-cute fox (this fox is cool, not adorable) · dark-mode-only design (it is a system utility; respect both appearances) · celebratory confetti or success animation · any typeface with attitude.

---

## 8. Task ledger

**This is the shared to-do list. Append to it; do not rewrite it.**

### Protocol

1. Before starting, read this section and claim a task by setting **Status** to `In progress` and putting your agent/session identifier in **Owner**.
2. IDs are `T-NNN`, assigned sequentially and **never reused**. Next free ID: **T-080**.
3. New work discovered mid-task → append a new row to **Open**. Do not silently expand the task you claimed.
4. On completion, move the row to **Done** with the completion date and the commit SHA.
5. If you abandon a task, set Status back to `Open`, clear Owner, and add a note saying what you learned. A dead end recorded is worth more than a blank row.
6. Never delete a Done row. This is the project's memory.
7. Priorities: **P0** blocks trusting the product · **P1** should happen next · **P2** nice to have.

### Open

| ID | P | Task | Status | Owner | Notes |
|---|---|---|---|---|---|
| T-005 | P0 | Run the 9-step on-device runtime validation in `Docs/VALIDATION.md` §"Still required on macOS" | Open | · | **Requires a human.** Owner's build 1 logs prove overload detection, Bluetooth auto-skip, manual repair success, output reconnection events, and a held result. Audible recovery, eligible-output automatic repair, notification, helper removal, and final build 2 behavior remain unverified. Agents must not trigger repair or helper registration unsupervised (rule 4). |
| T-007 | P2 | Fix 2 unsafe-pointer warnings in `CoreAudioProperty.swift:192` and `:223` | Open | · | "forming `UnsafeMutableRawPointer` to a variable of type `T` / `Optional<CFString>`; may contain an object reference." Real hazard for the `CFString` case. Touches Core Audio property reads; verify carefully. |
| T-008 | P2 | Fix 2 non-`Sendable` capture warnings in `HelperManager.swift:96` and `:141` | Open | · | `NSXPCConnection` captured in `@Sendable` closures. Will become an error under Swift 6 language mode; project is currently `SWIFT_VERSION = 5.0`. |
| T-009 | P2 | Reconcile brand tokens against the master art | Open | · | See the drift table in §7. Decide per-role whether the art or the shipped token wins, then align `Brand/README.md` and `FennecBrand` in `FennecApp.swift`. Consider adding aviator gold `#DA963E` and lens void `#23190E` as tokens. **Owner's design call; propose, don't unilaterally apply.** |
| T-060 | P1 | Commit the final candidate and validate its pull request before merging | Open | · | Local candidate `f83c69a` includes the source, docs, and launch kit. It has not been pushed; no candidate PR or CI run exists. Local `.claude/` worktrees and `Brand/fennec-walk.svg` remain untracked and outside the candidate. Validate the eventual PR and its CI before merging. |
| T-061 | P1 | Prepare and publish the final notarized archive and signed update feed | Open | Codex / root / 2026-09-25 | Final build 2 archive/export is in `build/ReleaseCandidate/`; app and helper pass strict Developer ID verification and the GIF matches source. A prior local draft proved Sparkle can sign and verify an appcast; the final ZIP must be notarized/stapled and then re-signed. The `fennec-notary` Keychain profile is absent. Auto-review rejected private app upload to Apple because external artifact transmission was not specifically authorized; do not bypass. No GitHub tag/release exists, and the public feed URL remains unavailable. |
| T-062 | P1 | Refresh public install/removal documentation and establish a security-reporting contact | Open | Codex / root / 2026-09-25 | README, UNINSTALL, and SECURITY copy was corrected for the current UI, update cache, network behavior, and absence of a verified security email. Owner deferred a private security contact. Verify or enable GitHub private vulnerability reporting when the repository becomes public if desired; documentation work is done. |
| T-063 | P1 | Prepare the Product Hunt listing and gallery against the public download | Open | Codex / root / 2026-09-25 | `Brand/ProductHunt/` now has a square thumbnail, two icon-derived gallery illustrations, listing copy, and a first comment. Public product/download URLs cannot be tested until the repository and release are public. Posting remains separate. |
| T-064 | P1 | Validate the signed updater installation and helper lifecycle end to end | Open | · | Existing unit tests cover disclosure/cache removal, not `FennecUpdateDriver` or `AppModel` update orchestration. Record explicit check/download/install, cancellation, repair-in-progress gating, helper unregister/restore, relaunch, and approval-required fallback results against identified builds. Needs a published/test feed and supervised helper changes; do not run root/audio paths without explicit approval. |
| T-071 | P1 | Determine whether Fennec's remaining Background Task Management entry is active | Open | · | After the owner's uninstall, a read-only BTM dump listed an enabled Fennec app item pointing into Trash even though the daemon and process were gone. It may be a historical record. Verify its live status during supervised retest; do not reset system-wide BTM state. |
| T-075 | P1 | Verify login startup default and uninstall against the installed test build | Open | · | Build `5118744` was installed in `/Applications` on 2026-09-26; its binary matches the signed Release artifact and it launched without a Welcome window after prior onboarding. Existing login registration was shown On in Settings before replacement. A fresh-profile login default and the revised complete uninstall need a supervised UI retest; no helper registration or audio repair was run. |
| T-079 | P1 | Install the blue Run Preview test build | In progress | Codex / root / 2026-09-26 | Owner approved replacing the installed app and restoring its currently running helper on 2026-09-26. Source commit `7415ac1` has a verified signed Release build, staged and signature-verified at `/Applications/.Fennec-primary-staged.app`. The installed app still has its running helper. Fennec exposes its unregister control only in Settings; the menu-bar-only app has no open window for computer control. Await the owner opening Settings, then unregister, replace, relaunch, and restore per rule 13. |

### Done

| ID | Task | Completed | Commit | Notes |
|---|---|---|---|---|
| T-069 | Make successful uninstall quit automatically and keep the app for failed steps | 2026-09-25 | f9f0051 | Owner's live test showed the bundle in Trash with Fennec still running; macOS would not reactivate its completion sheet. The stuck process was terminated cleanly through `NSRunningApplication`. Successful removal now calls quit without another click; any failed or missing earlier step leaves the bundle available for retry. All 292 tests, four app/helper Debug/Release builds, and source audit pass. The revised live uninstall was not exercised; no repair or helper registration was run. |
| T-070 | Include registered login items in uninstall even when awaiting approval | 2026-09-25 | 3e281a8 | The removal plan now includes `.requiresApproval` and refreshes Service Management status when uninstall begins. All 293 tests, four app/helper Debug/Release builds, and source audit pass. A remaining BTM entry needs the separate T-071 live check. |
| T-072 | Turn on launch at login by default during first setup | 2026-09-26 | 5118744 | A new copy in Applications registers the main app once without opening System Settings; a copy launched elsewhere waits for its move. Existing Off choices stay Off. Tests cover both paths. |
| T-073 | Keep uninstall preferences until the app bundle is removed | 2026-09-26 | 5118744 | Preferences are removed after a successful move to Trash, or kept with the app if that step fails, preventing a partial uninstall from restoring launch at login on relaunch. |
| T-074 | Keep standalone uninstall tests from touching the real app bundle | 2026-09-26 | 5118744 | The side-effecting XCTest path was removed; pure plan tests cover failed or missing removal steps. The suite passes 296 tests. |
| T-076 | Update animation preview copy and button in Settings | 2026-09-26 | 2b45cc5 | Active and disabled copy match the owner's strings; a large bordered-prominent button uses the dune-orange tint. Reduce Motion takes precedence when the toggle is on. All 297 tests, four app/helper Debug/Release builds, and the source audit pass. Installation is tracked separately in T-077. |
| T-077 | Install preview-copy build while preserving the active helper | 2026-09-26 | 2b45cc5 | Owner approved replacement. The registered helper was removed through Fennec Settings before the app swap. The old app was saved under `build/InstallBackups/`, the new signed Release app was installed in `/Applications`, and Fennec's existing one-time post-update path restored the prior helper registration after relaunch. The app and helper hashes match the build, launchd reports the helper running, and Automatic repair mode remains selected. No audio repair was triggered. Owner's visual test is pending. |
| T-078 | Give Run Preview the existing primary CTA treatment | 2026-09-26 | 7415ac1 | Removed the custom orange tint, headline font, full-width frame, and large control size. Run Preview now uses the same native bordered-prominent sky-blue button style as Repair Audio Now; action and disable gates stay intact. Source audit, Release signature, Debug tests, and all four app/helper Debug/Release builds pass. Installation is tracked in T-079. |
| T-068 | Install the current local Release build for owner testing | 2026-09-25 | e422222 | Owner approved replacing the notarized app with a Gatekeeper-rejected Apple Development build for local testing. The Release build was copied to `/Applications/Fennec.app`; strict code-signature checks pass and app/helper executable hashes match the build. The previous notarized app is preserved at `build/InstallBackups/Fennec-previous-notarized-20260925.app` and passes Gatekeeper. The old running app was quit cleanly; the owner must launch the new app to test. No repair, helper registration, notarization, or push was run. |
| T-067 | Restore Settings action hierarchy while keeping the requested order | 2026-09-25 | 53da47c | Corrected T-065's button styling: Repair Audio Now is prominent on the left, and Restart Monitor keeps its tertiary style on the right. All 291 tests, four app/helper Debug/Release builds, and source audit pass. Live Settings UI was not exercised; no repair or helper registration was run. |
| T-066 | Keep completed Fennec launches silent in the menu bar | 2026-09-25 | a18d0ef | Corrected T-065's reopen behavior: only unfinished onboarding shows Welcome; a completed launch raises no window and stays in the menu bar. Settings opens through explicit controls. All 291 tests, four app/helper Debug/Release builds, and source audit pass. No live reboot, repair, or helper registration was run. |
| T-065 | Keep completed onboarding closed on reopen; adjust Settings controls, Preview Fox burst, and menu copy | 2026-09-25 | 097f824 | Reopen now uses persisted first-run completion rather than setup readiness. Settings hit area and button priority were adjusted, Preview Fox uses the 100-request bounded burst without audio repair, and balanced sensitivity copy matches the owner's line. All 291 tests, four app/helper Debug/Release builds, and source audit pass. Reboot and live animation UI were not exercised; no repair or helper registration was run. |
| T-059 | Recheck automatic repair consent and safety gates after asynchronous work | 2026-09-25 | f83c69a | The response path rechecks pause, mode, output, episode, console session, Bluetooth rule, update preparation, and protection settings after helper recovery and before the final repair commitment. The repaired isolated probe reports zero automatic calls after Ask first, pause, or output change. After the final Bluetooth recheck, 290 tests and all four builds passed with only the four known Swift warnings. No live repair was performed. |
| T-058 | Review merge, public repository, and Product Hunt launch readiness | 2026-09-24 | f83c69a | Review verdict: not ready. All four signed app/helper builds, 290 tests with the documented command, source audit, and Release signature checks pass with no new compiler warnings. Gitleaks finds no matches in 60 local-history commits or tracked working-tree files. An isolated inert probe confirms the automatic-repair race tracked in T-059. Existing notarized export has the previous GIF; there is no GitHub release/feed or candidate PR. T-060–T-064 record merge, release, documentation/contact, listing, and updater validation work. Owner reports additional hands-on testing; exact build/results were requested and remain pending, so T-005 is not closed. No product code, helper registration, audio, installation, merge, repository visibility, or publication was changed. See `Docs/VALIDATION.md`. |
| T-057 | Apply approved frame 13 fur and frame 14 foot occlusion corrections | 2026-09-24 | f83c69a | Replaced the two approved frames in the bundled GIF; decoded comparison confirms frames 1–12 unchanged and preserves dimensions, all frame delays, looping, and transparent corners. All four app/helper builds, 290 tests, and source audit pass. Live repair not exercised. |
| T-056 | Raise the shared repair-fox burst limit to 100 if a full-overlap animation run performs well | 2026-09-24 | f83c69a | The shared burst accepts 100 total and allows 100 visible. Minimum spacing is 40 ms so all 100 can overlap on the tested display; extra clicks are discarded and only the first click repairs audio. An isolated AppKit preview linked no audio/helper code, accepted 99 of 300 extra requests, rendered 100 at once in one click-through panel, stayed responsive, and reset after the final crossing. In contemporaneous 60-sample runs, preview CPU averaged 1.1% for 100 versus 0.6% for 15; WindowServer averaged 50.2% versus 47.4% on a busy Mac, so the added cost is small but measurable. All 290 tests, four app/helper builds, and source audit pass with no new Swift warnings. Xcode Developer ID distribution `3B6BD1AF-A381-46B7-AD3E-7C259A535DD8` was uploaded; the export was stapled, and signature, stapler, and Gatekeeper checks pass. `/Applications/Fennec.app` and both local Release copies match (`fba7d289…`). No live repair or helper registration was run; quit and reopen the older running process manually. See `Docs/VALIDATION.md`. |
| T-055 | Raise the shared fox burst to fifteen simultaneous crossings if performance holds | 2026-09-24 | f83c69a | Shared onboarding/manual bursts now accept fifteen total and allow fifteen visible, preserving half-second starts and discarding later clicks. An isolated AppKit preview rendered fifteen at once in one click-through panel and reset cleanly; over 42 samples it averaged 0.6% CPU, peaked at 12.0% during load, and peaked at 59.8 MB resident memory, so the requested ten-fox fallback was unnecessary. All 290 tests, four app/helper Debug/Release builds, and source audit pass; no new compiler warnings. Xcode Developer ID distribution `630ED763-1523-4C44-B3B0-5C0338B984DD` was uploaded, the local Developer ID export was stapled with Apple's ticket, and strict signature, stapler, and Gatekeeper checks pass. `/Applications/Fennec.app` and both local Release copies match the notarized export (`8b91d502…`). No live repair or helper registration was run; the existing process needs a manual quit/reopen. See `Docs/VALIDATION.md`. |
| T-054 | Extend bounded fox replays to every manual Repair Audio control | 2026-09-24 | f83c69a | The popover, Settings, Audio menu, prompted window, and notification action share `requestRepairButton`: first click uses the guarded real repair; later clicks in the burst request foxes only, even during preparation. The ordinary burst clears after its last crossing; onboarding remains one real test per welcome window and does not set automatic cooldown. The ten-total/five-visible/half-second queue is shared. An isolated AppKit run accepted nine of 300 replays, rendered ten sprites at most five at a time, and observed automatic reset; no audio/helper path was linked. All 290 tests, four Debug/Release app/helper builds, and source audit pass. Xcode Developer ID distribution `9AA45BFE-C6EB-40F7-8E43-6142184B48CD` exported a notarized, stapled app; strict signature, stapler, and Gatekeeper checks pass. `/Applications/Fennec.app` and both local Release copies match the export (`8635e622…`); the running old process still needs a manual quit/reopen. No live repair or helper registration was run. See `Docs/VALIDATION.md`. |
| T-053 | Investigate sustained high `coreaudiod` CPU and whether Fennec contributes | 2026-09-24 | f83c69a | The screenshot's PID 72014 averaged 79% CPU in macOS's 02:03–02:05 resource report. Its busiest samples were in system audio property and plug-in/device-manager enumeration, attributed across loginwindow, Chrome, Spotify and other clients; none were attributed to Fennec. An earlier 90%-CPU report included Fennec in only one of 17 samples. The last successful Fennec repair was a user-requested restart at 01:59:30; the next request was helper-throttled, and PID 72014 started at 02:00:52. Fennec's monitor does not enumerate plug-ins. The evidence does not identify the responsible client or driver, but does not support a Fennec repair loop. Direct root-owned thread sampling was denied; no repair, helper change, or process termination was run. See `Docs/VALIDATION.md`. |
| T-052 | Make the first onboarding click repair once, then allow bounded fox replays | 2026-09-24 | f83c69a | The first click takes the existing guarded audio repair path and starts the fox; further clicks replay animation only, including while the first helper call is finishing. A bounded queue accepts ten foxes total (including the first), starts at least 0.5 seconds apart, and renders at most five simultaneously. Onboarding does not set the app's automatic-repair cooldown, and the visible fox-explainer sentence is gone. An isolated AppKit preview accepted nine of 300 rapid replays after the first and rendered ten crossings, with five maximum visible and 0.500-second observed spacing. All 290 tests, four app/helper Debug/Release builds, and source audit pass. Xcode Organizer notarization `C440D501-0BC4-4B0B-B86D-1B53A3B00124` is stapled and Gatekeeper accepted. `/Applications/Fennec.app` and both local Release copies match the notarized export (`22684e2b…`). No live repair or helper registration was run; the already-running process needs a manual quit/relaunch. See `Docs/VALIDATION.md`. |
| T-051 | Remove the popover's redundant info menu and any destinations used only by it | 2026-09-24 | f83c69a | Removed the blue info/More button and its duplicate navigation from `MenuView`. Route audit found no page exclusive to it: Repair History and the event log are linked from Settings diagnostics, About & Uninstall from Settings helper controls, and What Fennec Does is the first-run window. All 288 tests, four Debug/Release app/helper builds, and source audit pass. Xcode Organizer notarization `704A0F31-4555-4D4B-99A7-D01152859210` is stapled and Gatekeeper accepted; `/Applications/Fennec.app` and local Release copies match the export. No repair was run, and the already-running old process needs a manual quit/relaunch. See `Docs/VALIDATION.md`. |
| T-050 | Place the running fox 10 points above the physical display bottom | 2026-09-24 | f83c69a | `FoxRunMotion` now anchors the cropped fox to `screen.frame.minY + 10`, independent of Dock insets, on normal and negative-origin displays. The transparent, click-through panel uses status-bar level (25) above the Dock (20). All 288 tests, four app/helper Debug/Release builds, and source audit pass. Xcode Organizer notarization `6CBADEBA-B864-44C8-9AC3-30070AE7DDD2` is stapled and Gatekeeper accepted. `/Applications/Fennec.app` and both local Release copies match the exported binary and GIF. No audio repair was run; the already-running old process needs a manual quit/relaunch. See `Docs/VALIDATION.md`. |
| T-049 | Default new installs to Automatic and make the onboarding test repair a visible step | 2026-09-24 | f83c69a | Fresh preferences now select Automatic; existing saved choices are preserved. The welcome window shows all setup steps and pins **Try it now / Run a Test Repair** above Done, with the same repair and fox path as ordinary repairs. Cancelling a safety confirmation no longer leaves a later repair labelled as a test; a failed test shows its receipt. All 288 tests, four app/helper Debug/Release builds, and source audit pass; only the four known compiler warnings remain. Final Xcode Organizer notarization `52B844F4-9549-4400-94D3-FBBF5D770032` is stapled and Gatekeeper accepted; `/Applications/Fennec.app` and both repository-local Release copies contain the updated asset and binary. No live repair was run. See `Docs/VALIDATION.md`. |
| T-048 | Replace run-cycle frame 14 with the approved shorter far ear | 2026-09-23 | f83c69a | Owner-approved replacement in `Fennec/Resources/fennec-run.gif`. Decoded comparison confirms frames 1–13 unchanged, with all frame delays, dimensions, looping, and transparent corners preserved. All four app/helper Debug/Release builds, 286 tests, and source audit pass. Live repair not exercised. |
| T-045 | Run the approved fox across the screen when a repair starts | 2026-09-23 | `26cd07b` | Owner-approved: one mirrored, click-through crossing above the Dock on the pointer's display, completing after success and cancelling on failure. Original GIF alpha and frame delays retained; travel derives from paw motion and shares the gait's clock. The nonactivating panel stays outside ordinary window/reopen bookkeeping. Settings adds an opt-out and animation-only preview; Reduce Motion suppresses it. Administrator-prompt repairs show it only after a successful return. 278 tests pass (12 new fox cases), all four app/helper builds pass, source audit and Release signature verification pass, and no new compiler warnings. An isolated native harness verified direction, negative-origin display placement, mouse hit testing, unchanged foreground focus, completion, and disablement without running audio or helper code. Real repairs, full-screen/Spaces/Stage Manager, sleep/lock/wake, display removal, and live accessibility changes remain unverified; details in `Docs/VALIDATION.md`. |
| T-044 | One sentence for one outcome | 2026-08-30 | `0ea8d82` | Closes the inconsistency T-043 flagged and left open. The button said "Audio repaired" (T-042) while the banner said "Crackle repaired" (T-043); the owner chose "Audio repaired" for both. All three surfaces now read one shared constant, `RepairCopy.repairedTitle`, rather than three literals that happen to match: the notification title, the button's result phase, and the manual receipt headline. This matters because all three can report the same repair within seconds of each other, the banner arriving while the button the user just pressed is still on screen, and three phrasings for one event reads as three events. Pinned by `testEverySurfaceReportsASuccessInTheSameWords`, which compares the surfaces to each other and not just to a literal, so a future edit to one of them fails rather than drifting. Automatic repairs keep "Caught and fixed" on the receipt, which is a different claim (Fennec noticed it unprompted) and not a rephrasing of the same one. |
| T-043 | Plain language: no "Core Audio", no timings | 2026-08-30 | `1945971` | Owner directive, and a deliberate reversal of the register §7 used to prescribe. "Never say Core Audio, no user knows what that means. They hear a crackle and want it resolved." The repair notification is now the title "Crackle repaired" and **an empty body**, identical for automatic and manual, because which one it was is Fennec's business. Causes lost their counts and spans ("Repeated crackling on MacBook Pro Speakers."), receipts lost their durations, the stand-down reason lost its span, and the stall advisory lost the load average and memory-pressure level. The two timing tiles came out of the Activity header. `RepairCopy.duration` survives, unused by any product surface and documented as log-and-diagnostics only. `DetectionDecision` now carries two strings: `reason` stays technical for the event log, `plainReason` ("Fennec heard crackling.") goes to the banner. 33 strings rewritten across 12 files. §7 was rewritten to state the new rules and, importantly, the three places precision still wins: the event log, `PrivilegeDisclosure` and the About panel (rule 10 disclosure of what runs as root, which must stay literal), and internal errors carrying an OSStatus. Rule 12 updated to match. 25 pinned-string tests were rewritten rather than deleted, and a new `testNoUserFacingCopyNamesCoreAudioOrATiming` sweeps every banner and receipt string across four record shapes so the directive is enforced and not just applied once. **Left inconsistent, owner's call:** the button still says "Audio repaired" (T-042, explicitly requested) while the notification says "Crackle repaired"; unifying is a one-line change in `RepairCopy.primaryButtonTitle`. |
| T-042 | The button reports its own outcome | 2026-08-30 | `368b266` | Owner-directed, second half of the button pass. The primary control becomes a three-phase machine: "Repair Audio Now", "Repairing…", "Audio repaired" with a check mark, plus a second haptic tap at completion so the press and the outcome are bracketed by the same click. `working` deliberately collapses the old two-sentence narration ("Checking what is using audio…" then "Restarting Core Audio…"); those existed because a click used to leave the button looking untouched, and T-041's pressed state and haptic now do that job. Copy and symbol both moved into `RepairCopy` under rule 12, pinned by 5 new cases including one asserting the check mark belongs to exactly one phase. The confirmation is view state, not model state: a 2.5 s flash means nothing to anything that was not on screen. Disabled through the flash so a click cannot start a second restart, but drawn at full strength via the style's `readsAtFullStrengthWhileDisabled`, because a result should be readable. The completion hook sits on the Group, not the button, or the confirmation card swapping in would tear it down across the transition it watches. **Rule 9 tension, owner's call, flagged not resolved:** "Audio repaired" is a claim from `succeeded` alone, which rule 9 reserves. What is established at that instant is that the restart completed; whether the fault is gone takes a minute. Narrowed as far as the wording allows: the flash only fires on a succeeded record, and no aviator gold is spent, so the held/returned accounting is untouched. "Core Audio restarted" is a one-line swap in `RepairCopy.primaryButtonTitle` if the rule should win. |
| T-041 | The repair button becomes a physical control | 2026-08-30 | `368b266` | Owner-directed. The refresh arrows read as "reload this thing", the wrong promise for a control that restarts the audio system, so the symbol is now `wrench.and.screwdriver.fill`; a hammer was asked about and declined because it is Xcode's Build symbol to anyone who has seen one. Corner radius 5 to 10 pt. The button is drawn as a raised key: a downward drop shadow and a lit top edge at rest, and a press that travels the whole control down by exactly the resting shadow offset while the shadow collapses, so it reads as bottoming out. `offset` does not participate in layout, so nothing around it moves. A haptic tap fires on press-down via `NSHapticFeedbackManager`, which is already a no-op without a Force Touch trackpad and already honours the system haptic setting, so Fennec adds no setting of its own. Reduce Motion drops the travel animation and keeps the state change. Style extracted from `MenuView` into `PrimaryRepairButtonStyle.swift` so it can be compiled into a throwaway harness and pressed for real with a no-op action: rest, held, and disabled were captured that way, and the haptic call site was proved reached by temporary instrumentation rather than assumed. Never pressed in the real app (rule 4). |
| T-040 | The popover ends with the button | 2026-08-29 | `d09d6e5` | Owner-directed layout pass, decided from a screenshot. The repair receipt card and the days-without-incident sign both come out of the popover: the header tally, the footer line, and the Activity window already carry that information, and the popover was ending on two read-only blocks instead of the action. "Repair Audio Now" moves from the top of `repairControls` to the bottom of the content, above the Settings/status/More/Quit strip, so the button is last in the reading order and sits under the state that says whether pressing it is a good idea. The inline confirmation moves with it, keeping rule 7 intact: the surface that asks is the surface that was going to act. New `PrimaryRepairButtonStyle` at 56 pt (twice the `.large` bordered height) with a 5 pt corner, because `.borderedProminent` owns its radius; pressed and disabled fills are drawn by hand since a custom style gets neither free. `RepairCopy` untouched, so rule 12 and `RepairCopyTests` still pin every string. Left behind deliberately: `DaysWithoutIncident`, its 9 tests, and `AppModel.daysWithoutIncident` are now unreferenced by any view. Kept rather than deleted because the sign is named in §7 as a brand element and the model is pure, tested logic; if it is not coming back, remove all three together. |
| T-038 | The microphone guard vetoed every repair, forever | 2026-08-29 | `b4cb2ee` | Field bug, reported by the owner from a live banner: "Crackle repair skipped / Microphone input is active in corespeechd." with nothing recording and the orange privacy indicator off. `corespeechd` is Apple's wake-word daemon; with "Hey Siri" or dictation enabled it opens an input stream at login and never closes it, so `kAudioProcessPropertyIsRunningInput` reads true forever and `RecoverySafetyChecker` vetoed **every** automatic repair on the machine while naming a microphone nobody was using. Measured on the owner's Mac across repeated samples: `corespeechd` (bundle `com.apple.CoreSpeech`) was the sole holder of an input stream; the event log carried 12 skips attributed to it. Fixed by ignoring `com.apple.CoreSpeech` (name fallback `corespeechd` / `corespeechd_system`) alongside the existing `coreaudiod` filter. Deliberately narrow: `avconferenced` and `ContinuityCaptureAgent` open input only during real activity and still block, which is the guard working. `evaluate` was split into a pure `report(for:ownPID:protectMicrophone:protectCommunicationApps:)` so the filtering is testable; `RecoverySafetyChecker.swift` and `CoreAudioProperty.swift` joined the `FennecTests` target with 14 new cases. Discovered mid-task and deferred to T-039: the promise/retraction banner pair is unbudgeted. |
| T-037 | Announce at commitment, not at the call | 2026-08-28 | `fcafe95` | Owner-directed cadence fix. The "Crackle detected" / "Resetting speakers..." heads-up moved from 0.3 s before the privileged call to the moment the automatic path commits: right after the cheap gates (pause, stand-down, cooldown, console, helper reachable) and before the safety scan, whose utility-QoS process walk took 26 s on the last real fault because the machine was starved, which is the product's premise. The 0.3 s sleep is gone. New consequence handled: a promise the safety scan then vetoes is retracted in place ("Crackle repair skipped" + the blocker, same identifier, never budgeted, Repair Now offered); when repair notifications are off the old budgeted unrepaired-detection banner still applies. Copy pinned in `RepairCopyTests`. |
| T-036 | Repair banners must present, not just file | 2026-08-28 | `5d72cae` | Field-diagnosed minutes after T-035 shipped: a real automatic repair ran (3 signals in 3 s, restarted in ~1 s, held) and the user saw neither banner; both were sitting in Notification Centre. Two causes. The success banner was `.passive`, and on macOS passive means "notification list only, no banner", so "Crackle resolved" was engineered never to be seen. And because the result shares an identifier with the "Resetting speakers..." heads-up (by design, to replace in place), the passive replacement also withdrew the active banner before it could be read. Both now post `.active`, still soundless. Passive stays right for the genuinely quiet banners (stall advisory, pause expiry, fault-returned correction). |
| T-035 | Visible detection, faster intervention, terse notifications | 2026-08-28 | `dec3972` | Owner-directed UX pass. (1) New `detected` menu-bar state: the fennec turns system red with two sound-wave arcs in the V between the ears, from the first unsuppressed crackle signal until the repair attempt settles or one detection window plus 2 s passes quietly; suppressed while paused; it is the one deliberate exception to the template-image rule (colour is the message) and to the shipped palette (owner's call). (2) Balanced window 8 s to 3 s (threshold still 2); the drain-schedule margin test was re-derived: the binding widening bound is one active-tier drain plus leeway (0.3 s), not `deepIdle`, because the first non-empty drain snaps back to the fast tier. Real-world latency on the log-witness path is still bounded by poll cadence (30-120 s), not the window. (3) An automatic repair posts "Crackle detected" / "Resetting speakers..." 0.3 s before the privileged call (same notification identifier, so the result replaces it in place), and the success banner is now "Crackle resolved" with the restart time as its only body; cause detail stays on the receipt and in Activity. Manual, failure, and unrepaired-detection banners unchanged. |
| T-034 | Open-source cleanup pass | 2026-08-28 | `e774260` | Preparation for publishing the repository. Every em dash in prose was rewritten into plain punctuation across source, tests, scripts, CI, and docs (the standalone "—" null-value UI placeholder stays, in four source sites and the tests that pin it). Comments citing internal review-finding numbers were rewritten to state their reason. This file lost its machine-specific rows (local path, git owner, private marker), its ground rules were renumbered into presented order (they ran 1-7, 12, 11, 10, 9, 8) and the source map's rule cross-references corrected to match. Stale test counts (187/204) synced to the measured 244, and T-008's warning line numbers refreshed. Verified: 244 tests pass, all four build combinations green, exactly the 4 catalogued warnings, audit + manifest gate pass. |
| T-001 | Get the project building in Xcode | 2026-08-25 | `aa22cc6` | One compile error: `SecCodeCopySigningInformation` was passed a `SecCode` where Swift demands `SecStaticCode`. Bridged with `unsafeBitCast`; see §6. Verified green across `Fennec`/`FennecHelper` × Debug/Release, plus a clean Release build; helper confirmed embedded at `Fennec.app/Contents/MacOS/FennecHelper`. |
| T-002 | Fix `Scripts/audit-source.sh` | 2026-08-25 | `aa22cc6` | Loop variable `path` clobbered `$PATH` under zsh, failing every command from line 31 onward and reporting a false packaging error. Renamed to `required_path`. Audit now passes end to end. See §6. |
| T-003 | Publish to GitHub | 2026-08-25 | `aa22cc6` | `git init` (repo had no `.git` despite appearances), initial commit of 56 files, pushed to `alexcox245/Fennec`, default branch `main`. |
| T-004 | Regenerate `Docs/SOURCE_MANIFEST.sha256` | 2026-08-25 | `aa22cc6` | Rehashed after the T-001/T-002 edits. |
| T-006 | Add a unit-test target covering `DetectionEngine` and `EventLogger` | 2026-08-25 | `b0af227` | `FennecTests`, a standalone XCTest bundle (no `TEST_HOST`) compiling the pure-logic sources directly. `EventLogger` gained an injectable directory and size cap plus a test-only `flush(completion:)` so rotation is observable without writing 5 MB. Scheme `Fennec` now has a TestAction. |
| T-011 | Make `audit-source.sh` verify `Docs/SOURCE_MANIFEST.sha256` | 2026-08-25 | `b0af227` | Added `Scripts/update-manifest.sh` (regenerates from `git ls-files`, so new files are never missed) and a `shasum -c` gate at the end of `audit-source.sh`. `FennecTests/*.swift` added to the per-file Swift parse. |
| T-013 | Catch & Fix: automatic repair the user can see | 2026-08-25 | `35d35e8` | Auto-repair now defaults **on** (still inert until the helper is enabled). `DetectionDecision` carries the real elapsed span between signals, not just the configured window, so the copy can say "2 crackle signals in 5.8 s". Every repair is timed across the privileged call only and persisted as a `RepairRecord` in `repairs.json`; the popover shows the newest as a receipt in aviator gold, plus a running total. Notifications were rebuilt around proportionality: success is `.passive` with no sound and no buttons, failure and unrepaired-detection get a sound and an action. |
| T-014 | Always On: start with the Mac, and say what is left to do | 2026-08-25 | `bccc379` | `LoginItemState` wraps `SMAppService.Status` with a name and a next step, and `LoginItemManager` re-reads it on every `didBecomeActive` because the user can switch Fennec off in System Settings without telling the app. `SMAppServiceErrorDomain` failures are translated into the cause that is almost always true. New `SetupChecklist` is the single pure model behind every setup CTA: the popover, Settings, and (later) first-run cannot disagree about what a button means. |
| T-015 | Stop being hostile out of the box | 2026-08-25 | `1fd2b4d` | Four confirmed defects. (1) The cooldown was keyed on the last *successful* repair and sat **below** the helper gate, so a fresh install had no cooldown at all; it now keys on the last attempt and gates everything. (2) `NotificationBudget` rate-limits unrepaired-detection banners to one per 10 min and reports how many it swallowed; suppression is never silent. Stable per-class request identifiers mean a new banner replaces its predecessor rather than stacking. (3) `SystemEvents` adds quiet windows after wake (20 s), screen wake, unlock, fast-user-switch, and launch; without them the first thing Fennec did when a lid opened was restart the audio daemon. (4) The silent `osascript` fallback on an XPC failure is gone. An unexplained admin-password dialog is the visual signature of credential phishing, so Fennec now asks first and shows the literal command. Also: automatic repair is gated on being the console session, and a failed repair leaves a persistent attention mark in the menu bar rather than relying on a sound played through the audio system that is by hypothesis broken. |
| T-016 | Windows that behave like a Mac app | 2026-08-25 | `a38bf8d` | `WindowPresenter` owns every window and flips the activation policy so ⌘W/⌘Q/⌘, and the Dock icon exist for exactly as long as a window does. SwiftUI's `Settings` scene is gone: `showSettingsWindow:` returns `true` and opens nothing in an accessory app on macOS 26, verified by launching the built app and listing windows with `CGWindowListCopyWindowInfo`. `AppDelegate` adds reopen handling (double-clicking a running menu-bar app did nothing at all) and holds quit open for an in-flight repair. Settings lost its mascot banner: a `TabView` hoists its picker into the title bar, so the banner rendered *between* the tabs and their content, and rule 6 says the brand does not belong in a re-skinned system utility anyway. Settings and the popover now share `SetupStepRow`, and the popover uses a one-line `compactDetail` because three five-line paragraphs in a 384 pt popover is a wall, not onboarding. |
| T-017 | First run: a consent record, not a welcome tour | 2026-08-25 | `b525569` | Before this, double-clicking Fennec produced nothing at all: no window, no Dock icon, one more glyph in a crowded menu bar. The window states the **complete** privileged surface before asking for any of it (including the `osascript` administrator path, which every obvious version of this panel would have omitted), costs a repair in plain seconds, and ends with a real repair the user runs on purpose while nothing is at stake. No test tone: Fennec does not know the user's monitor gain. `InstallLocation` guards the `/Applications` requirement that the README previously only documented. The actual menu-bar mark is rendered inline under "Where Fennec lives", with the three real reasons a status item goes missing. |
| T-018 | Pause | 2026-08-25 | `5c19039` | The manual override. Fennec's safety checks can only see what Core Audio tells them; a person about to hit record knows more than that. `PauseState` is persisted as two plain values so a timestamp that expired while Fennec was not running resolves to "running" on the next read rather than reviving a dead pause. Every duration except the last expires on its own and posts one passive banner when it does, and the menu-bar mark carries its own paused variant, so a pause can never be quietly left on. Blocks automatic repair only; Repair Audio Now keeps working, because a person pressing the button has decided. The real reason it exists is retention: the alternative to a two-hour pause is a professional switching automatic repair off permanently after one mistimed restart. |
| T-019 | Stop claiming "fixed" until it holds | 2026-08-25 | `af1e9a5` | `RepairRecord` gained an outcome (`pending` → `held`/`returned`/`failed`), decoded tolerantly so `repairs.json` files from earlier builds still read. A detection inside the 60 s verification window marks the last repair `returned` and *replaces* the success banner in place rather than stacking a contradiction under it. Gold, and the headline tally, now require `held`. `RepairGovernor` stands Fennec down for an hour after three automatic repairs in twenty minutes that did not hold; otherwise a machine where the restart is not the cure gets its audio silenced every 45 seconds, forever, by the default configuration doing exactly what it was told. The stand-down states the real numbers and names the possibility the user needs to consider. |
| T-012 | Add a `LICENSE` | 2026-08-25 | `8b3142e` | MIT. Landed with `SECURITY.md` (disclosure contact, the privilege boundary stated precisely, and the second privileged path named rather than buried) and `UNINSTALL.md`. |
| T-020 | Take it back: uninstall, and the privilege panel | 2026-08-25 | `8b3142e` | Closes the gap nobody in the review had ranked: the root daemon survives dragging Fennec to the Trash. `Uninstaller` unregisters the daemon, removes the login item, optionally deletes the support folder, forgets preferences, moves the bundle to the Trash, and reports each step's failure separately. `AboutView` replaces the stock About panel with the four things a person evaluating a root-privileged 3 MB app actually asks: what it can do, what is running as root *right now* (read back over XPC; `ping` now returns a parseable reply, no protocol change), how to verify the build against `SOURCE_MANIFEST.sha256`, and how to remove all of it. Also closes T-012: `LICENSE`, plus `SECURITY.md` and `UNINSTALL.md`. |
| T-021 | Activity, and the sign on the wall | 2026-08-25 | `0e7fc1d` | `ActivityView` is a receipt book grouped by day, deliberately not a sortable table with filters and CSV export; every version of that is a window someone opens once, on install day, to find empty. The delighter is `DaysWithoutIncident`: an industrial safety sign in sand and ink that counts calendar days and reads **0** on a repair day with no softening. It does not invert with the appearance, because a sign is a physical object; sand is a surface and ink is the number, which is exactly what the palette reserves them for. It changes only at midnight: a sign that ticks is a timer, and nobody should watch this. |
| T-022 | Idle cost, and the documents this repo is judged by | 2026-08-25 | `4e6f5c9` | The drain timer ran at 250 ms forever, whether or not a signal had ever arrived; a product whose proudest claim is stillness should not be the loudest thing in Activity Monitor. `DrainSchedule` steps to 1 s after a quiet minute and 2 s after five, with generous leeway so the kernel can coalesce the wake-ups, and snaps back on the first non-empty drain. Safe because the property listener runs on Core Audio's side regardless and the counters are atomic: backing off delays noticing a signal, it never loses one; pinned by a test that the slowest tier still outpaces the tightest detection window. Plus `CHANGELOG.md`, a rewritten README (Gatekeeper, the `/Applications` requirement, verifying a build, uninstall, and the shell-alias question), and `.github/workflows/ci.yml`. |
| T-023 | Adversarial review, and the fixes | 2026-08-25 | `1825767` | Three lenses (IA, UX, macOS engineering) read the shipped tree; every finding was then verified against the source by a separate reviewer, and 33 survived. **Two blockers**: uninstall could trash the app after the daemon unregister failed, and silently skipped the daemon entirely when it was `.awaitingApproval` (the plan keyed off reachability rather than registration) then reported "Fennec is removed"; and a failed listener rebuild after a service restart left the monitor with a timer and no ears while the popover kept showing a blue dot and "Listening". Nine majors, including a first-run window that only completed on the Done button (so ⌘W meant it reappeared at every login forever), a quit-grace timer scheduled in `.default` mode under `.terminateLater` (so ⌘Q during a repair hung until Force Quit), confirmations raised with no window to host them, a gold seal painted from `succeeded` above the words "the fault came back", and both a declined password prompt and the helper's own 20-second rate limiter recorded as failed repairs with an alarm. |
| T-030 | Get out of Activity Monitor: the one-percent budget | 2026-08-26 | `36fa157` | Sampled at 33.9% CPU. Root cause one, 55% of main-thread samples: `MenuBarExtra` keeps the popover's hosting view alive after close, and a display-driven `TimelineView` in a live-but-invisible window renders forever. `WindowVisibilityProbe` (NSWindow occlusion, not SwiftUI appearance callbacks) now gates the graph to render *nothing* off screen, and 4 deterministic fps on screen. Root cause two: ~1 s of CPU per `OSLogStore` query at a 10 s fault cadence; watch moves to 120 s (steady-state under 1% while music plays, pinned by a test), fault to 30 s paid only during a live fault. README/ARCHITECTURE now state the honest ~2 min worst-case latency. |
| T-029 | Sign with the team, not ad-hoc | 2026-08-26 | `4e75740` | Field-diagnosed from Fennec's own guard ("The executable has no Team ID"): the app target forced `CODE_SIGN_IDENTITY[sdk=macosx*] = "-"`, so every build to date was ad-hoc; `codesign --verify` green, `TeamIdentifier=not set`. The Release XPC requirement (rule 2) could never have accepted it, which retroactively explains the helper never once answering. App and helper targets now sign `Apple Development` / team `249X253HS3` (A & A Design Inc.), verified `TeamIdentifier=249X253HS3` on the app and the embedded helper; `FennecTests` stays ad-hoc on purpose. Known-trap entry added in §6. |
| T-028 | The activity ribbon: the graph agreeing with your ears | 2026-08-26 | `e9c1050` | A strip under the graph's time axis painted for every second the output device was running IO, so a dropout is a visible break next to the stall triangle that explains it. `SystemLogMonitor`'s tick now tightens to 1 s while audio plays (silence relaxes back to 5 s per the stillness rule) and delivers running samples only; a gap in the data *is* the gap. `AudioActivitySegments` merges samples with a window wider than one tick so a coalesced wake-up cannot fake a dropout, pinned by tests. Drawn as its own Canvas strip, not a series, so the count axis stays a count axis. |
| T-027 | Onboarding that hands you the icon | 2026-08-25 | `98d845a` | The checklist gains a leading `install` step: complete in Applications, *required* when running from anywhere else (registrations bind to the bundle path, so nothing on the list is safe to do first), optional-but-noted for development builds. Its action genuinely moves: `InstallLocation.moveToApplications()` copies the bundle (trashing an older copy, never the original), relaunches from the new home, and quits. `DraggableAppIcon` puts the app icon in the first-run window as a real drag source; the Open at Login list in System Settings and the Applications folder both accept the drop, so "find the app" is a drag, not a Finder safari. No new privileged surface: writing to /Applications is plain admin file access, disclosed nowhere because it is not privileged. |
| T-026 | The popover graph: 30 seconds of signals against the real threshold | 2026-08-25 | `cdbda57` | `SignalGraphView`, a continuously scrolling strip in the popover plotting overload signals inside the configured detection window (the literal quantity the engine compares) with the threshold as a labeled dashed rule and playback stalls as baseline triangles. Shape + legend carry identity; the dune/twilight pair passes CVD validation at ΔE 28–39, and the stall marks wear adaptive secondary ink for dark-surface contrast. `TimelineView(.animation)` schedules nothing while the popover is closed; opening it triggers `pollNow()` so the window is fresh. |
| T-025 | The stall advisory: name the failure Fennec cannot fix | 2026-08-25 | `cdbda57` | Diagnosed live: load 17–25, swap 2.3/3 GB, Spotify in uninterruptible page-in waits, coreaudiod logging clean `StopIO`/`StartIO` pairs every 30–90 s with zero overloads. A starvation stall, unfixable by restart. `SystemLogMonitor` now classifies stop/start lines from the same query (with a 3-minute running-grace so the stopped device does not blind the monitor), and pure `StallAdvisor` requires the pattern (≥3 stops/3 min) *and* the cause (load ≥1.25/core or memory pressure ≥ warning); skipping-through-an-album alone never advises. One passive banner per half hour via `NotificationBudget`, copy in `RepairCopy` pinned by tests, `advisory` event kind in the record. |
| T-024 | Detect the fault the listener cannot hear: the coreaudiod overload log | 2026-08-25 | `354af6d` | Diagnosed on a live faulting machine (music audibly crackling, user present): `coreaudiod` logged `HALS_OverloadMessage` several times a second for 6+ hours, caused by an iOS Simulator `callservicesd` holding a silent audio context for 11.5 h, while Fennec's listener recorded zero signals ever. A probe confirmed a passive listener *and* a healthy sibling IOProc both observe nothing, because the overload notification fires only in the faulting client's process. New `SystemLogMonitor` polls the unified log via `OSLogStore` (admin-readable, verified unprivileged), gated by `OverloadLogSchedule`: a cheap device-is-running check in front of a ~1 s query, 30 s cadence while healthy, 10 s once faulting, never while no audio runs. Events enter the existing pipeline with their true log timestamps (`AudioSignalBatch.overloadDates`) so poll cadence bounds latency, never window math; pinned by tests. Known fragilities, documented in ARCHITECTURE: keys on private message text; needs an admin account; both degrade to the listener path with one Activity note. |
| T-010 | Refresh `Docs/VALIDATION.md` | 2026-08-25 | `9a33c30` | Rewritten. It claimed the source "has not been SDK type-checked, linked, [or] code-signed", which stopped being true at T-001. Now states what is verified and how (build matrix, unit tests, audit, codesign), what was exercised by hand on this machine, and (kept and expanded) what still needs a device, including the three new things that cannot be tested without a live root daemon. The matching README claim was fixed in `4e6f5c9`. |
| T-033 | Listening-state CPU under 1%: the growing-window leak, and the tick's device handle | 2026-08-27 | `0910042` | Measured live: 1.08% of a core while listening (cputime delta over 202 s) against the 1% budget; a 60 s / 1 ms `sample` showed baseline ~zero, so the cost was bursts. **The big one was a leak**: `queryLocked` advanced `lastProcessedDate` only to the newest *matching* entry, and on a healthy machine nothing matches, so the cursor never moved and every 120 s poll re-enumerated an ever-growing window (benchmarked ~0.18 s CPU per minute of window; CPU per poll grew linearly for as long as playback continued without a stop). Fixed by advancing the cursor to query time minus a 10 s logd-flush margin; provably skips only non-matching entries, since any matching entry would have advanced `newest` past itself. Second: the 1 s activity tick's resolve-device + HasProperty + read shape benchmarked 1.2 ms (three HAL round trips), not the "~40 µs" the comments claimed, ~0.12% continuously; now one ~0.15 ms read on a cached handle, re-resolved via `noteOutputDeviceMayHaveChanged` (device changes, service restarts), on read errors, and every 10 ticks. Poll itself benchmarks 0.45 s CPU per bounded 120 s window (0.08 s store open + 0.37 s enumerating ~2,000 coreaudiod entries; CONTAINS matching nearly free). Docs' 40 µs claims corrected. Post-fix, verified live with a movie playing through the speakers: **0.81%** of a core over 240 s (1.94 s cputime: two bounded ~0.9 s polls, 121 s apart per the 5 s-resolution trace, constant and no longer growing, plus a 10–40 ms tick drip); ~0.30% in a mixed quiet window, ~0.08% in silence. The first "0.30% with audio playing" claim was wrong; audio was off during that window; corrected here. Next lever if more headroom is ever wanted: the healthy poll cadence (120→240 s ≈ 0.45%, at the cost of worst-case detection latency). |
| T-032 | Developer ID release pipeline for direct download | 2026-08-27 | `0910042` | `Scripts/release-developer-id.sh`: audit → archive (Developer ID) → export → notarize (`notarytool`, keychain profile `fennec-notary`) → staple → zip → `spctl` assess, with the same bundle checks as `build-release.sh` on the exported bits. Preflights refuse to run without a Developer ID Application cert and stored notary credentials, and print the exact one-time setup. Refuses to notarize a development-signed export. Chosen over Mac App Store deliberately: MAS requires App Sandbox, which `SMAppService` daemon registration rules out (§2). First real run still needs the human steps in the script header (paid program cert + credentials). |
| T-031 | The helper registration heals itself | 2026-08-27 | `0113d44` | Field-diagnosed: launchd held a registration it could no longer spawn (9,736 attempts, first `EX_CONFIG` from a pre-T-029 ad-hoc Release helper refusing to start by design, then "Could not find and/or execute program" once the bundle was replaced) while `SMAppService` kept reporting `.enabled` and Fennec's only moves were "Enabled, not responding" and the admin-password prompt. Rebuilding a registration is unprivileged, so Fennec now does it itself: `HelperManager.rebuildRegistration()` (re-ping before teardown so stale news never kills a healthy registration; unregister → register from the running bundle; up to three pings after, because launchd spawns on demand), gated solely by pure `HelperHealPolicy`: only while macOS reports the daemon enabled (the user's standing approval; `.requiresApproval`/`.notRegistered` stay the user's call), never when answering, 10-min interval automatic, always for a user press. Runs at launch (+8 s), before an automatic repair is skipped, and before the manual path summons a password dialog. Settings' dead "Recheck" became "Rebuild". Every attempt/outcome is a `helper` event. Consent note: this re-registers only a daemon the user already enabled; it never converts `.requiresApproval` into a registration. |
| T-039 | Budget the promise/retraction pair, not just the unrepaired banner | 2026-09-23 | `c8b8bdb` | Moved the automatic repair heads-up until after safety checks and removed the retraction path. A protected call now receives only the rate-limited unrepaired-detection notice; Fennec never sends an unbudgeted promise it must retract. |
| T-046 | Refocus the app around automatic or prompted repair and align its screens with Figma | 2026-09-23 | `c8b8bdb` | New installs start in Ask me first; completed legacy installs retain the previous automatic default when it was implicit. Added episode-aware prompts, protected-call gating, output-change invalidation, quieter first-run/settings surfaces, and preserved the running fox crossing during repair. Verified with 286 tests, the four app/helper Debug and Release builds, and the source audit. Code signing and live repair remain unverified here. |
| T-047 | Add explicit in-app updates and prepare signed public releases | 2026-09-23 | `c8b8bdb` | Added Sparkle 2.10.0 with manual check, download, and Install & Relaunch stages; signed-feed metadata and appcast tooling; helper registration restoration; update privacy disclosure; and update-cache removal. No release was published. This environment has no signing identity, so signed bundle, notarization, and live updater behavior remain unverified. |

---

## 9. Before you hand off

Report honestly and specifically:

- What you changed, and **why**, not just what.
- Which checks you actually ran, with their real output. If something failed, say so and paste it.
- What you could **not** verify: anything needing a physical audio device, root, user approval, or a reproduction of the audible fault. This project has a large untestable surface; pretending otherwise is the main way to do damage here.
- Which ledger rows you moved, and any rows you appended.
