# AGENTS.md — Fennec

Operating guide for AI agents working on this repository. Read this file **before** touching code. If you change how the project is built, validated, or branded, update this file in the same commit.

---

## 1. Where this lives

| | |
|---|---|
| **Local working copy** | `/Users/helpit/Documents/Fennec` |
| **Remote** | `https://github.com/alexcox245/Fennec` (**private**) |
| **Default branch** | `main` |
| **Git owner** | `alexcox245` (auth via `gh`, HTTPS) |
| **Xcode project** | `Fennec.xcodeproj` (no standalone `.xcworkspace`, no SPM packages, no CocoaPods) |
| **Targets** | `Fennec` (app), `FennecHelper` (privileged helper), `FennecTests` (unit tests) |
| **Schemes** | `Fennec` (builds the app, runs `FennecTests`), `FennecHelper` — both shared |
| **Bundle IDs** | `com.ludicrousdesigns.Fennec`, `com.ludicrousdesigns.Fennec.helper` |
| **Team ID** | `249X253HS3` |
| **Deployment target** | macOS 14.2 · Swift 5 language mode · arm64 |
| **Verified toolchain** | Xcode 26.6 (17F113) |

There are **no external dependencies**. Everything builds from the checked-in sources against the macOS SDK.

---

## 2. What Fennec is

A local-only macOS menu-bar utility for one specific failure mode: Core Audio starts crackling under heavy local workloads and stays corrupted until `coreaudiod` is restarted.

Fennec watches the default output device for `kAudioDeviceProcessorOverload` and `kAudioDevicePropertyIOStoppedAbnormally`, and — when a threshold is met and safety checks pass — restarts `coreaudiod` through a tightly scoped root helper, leaving every application open.

It is **not** sandboxed, by design: `SMAppService` daemon registration requires it.

---

## 3. Ground rules

These are load-bearing. Violating one produces a build that looks fine and fails in the field.

1. **Never do work in the real-time audio callback.** `Fennec/RTSignalCounters.c` and the Core Audio property listener may be invoked from a real-time I/O thread. Allowed: relaxed atomic increments on fixed preallocated storage. **Not** allowed: allocation, logging, `os_log`, locks, Swift closures, XPC, `dispatch_async`, string formatting, `print`. All higher-level work happens after a 250 ms timer drains the counters onto a normal serial queue.

2. **Do not weaken the privilege boundary.** `Shared/CodeSigningRequirement.swift` intentionally restricts identifier-only peer matching to `#if DEBUG`. Release builds require Team ID **and** bundle identifier on both sides of the XPC connection. Do not "simplify" that `#if` away.

3. **Do not add a general execution API to the helper.** `Shared/HelperProtocol.swift` exposes exactly two methods (`ping`, `restartCoreAudio`). The helper invokes fixed absolute executables with fixed arguments and verifies a new `coreaudiod` PID appeared. Never add a method that takes a command, path, or argument list from the app.

4. **Do not run the repair path or install the helper without explicit user approval.** `restartCoreAudio` kills audio system-wide for a moment; installing the LaunchDaemon needs root and a user approval in System Settings. Never `sudo ditto` into `/Applications`, never invoke `SMAppService` registration, and never trigger a repair as part of "just testing." Ask first, every time.

5. **Regenerate the source manifest after editing any tracked file** with `zsh Scripts/update-manifest.sh`. `audit-source.sh` verifies it and fails when it is stale, so skipping this breaks the audit rather than shipping quietly.

6. **Keep it a system utility.** Native macOS materials, typography, and controls stay intact. The brand lives in the icon, accents, and voice — not in a re-skinned UI. See §7.

7. **Never present an `.alert` or `.confirmationDialog` from the `MenuBarExtra` scene.** The popover is a panel that dismisses the moment it resigns key, and presenting an alert *is* what makes it resign key — so the dialog flashes and vanishes, on the code path that restarts the audio system. Ask inline with `PendingConfirmation` instead. Settings may use a sheet, but it renders the same `PendingConfirmation` so the two cannot disagree.

12. **Fennec must stay removable, and the daemon is the part that is not.** Dragging the app to the Trash leaves the root LaunchDaemon registered in Background Task Management, the login item in place, and the support folder on disk — demonstrable in thirty seconds by anyone. `Uninstaller` unwinds all of it and reports failures **per step**, because "uninstall failed" tells a user nothing they can act on. `UNINSTALL.md` carries the command-line fallback for the case where the app is already gone. If you add anything that persists outside the bundle, add it to `UninstallPlan.steps` in the same commit.

11. **A repair is provisional until it holds.** The instant `restartCoreAudio` returns, the only established fact is that a new `coreaudiod` PID exists — whether the *fault* is gone takes a minute of quiet to find out. `RepairRecord.outcome` tracks that (`pending` → `held` or `returned`), the headline tally counts only repairs that held, and aviator gold is not spent until one does. Three automatic repairs inside twenty minutes that did not hold trips `RepairGovernor`, and Fennec stands down for an hour rather than looping every 45 seconds on a machine where the restart is not the cure. Do not make the UI call a repair "fixed" from `succeeded` alone.

10. **Every privileged path is disclosed in `PrivilegeDisclosure.swift`, and there are three of them.** The obvious version of an About panel enumerates the XPC surface — `ping` and `restartCoreAudio` — and stops. That is a true statement engineered to mislead, because `PrivilegedPromptRepair` runs the same command through an `osascript` administrator prompt when the helper is not enabled. A user who reads "exactly two methods" and then sees a password dialog has been lied to by omission. If you add a way for Fennec to act with privilege, it goes in that file, and `FirstRunTests` will tell you if the disclosed command drifts from the executed one.

9. **Every window goes through `WindowPresenter`, including Settings.** Fennec is `LSUIElement`, so it has no main menu — which silently breaks ⌘W, ⌘Q and ⌘, in any window it opens. `WindowPresenter` is `.accessory` while only the popover shows and `.regular` for exactly as long as a real window is open, so the standard shortcuts work whenever there is something to type them at. Do **not** reintroduce SwiftUI's `Settings` scene: its only programmatic entry point is the undocumented `showSettingsWindow:` responder action, which reports success and then does nothing in an accessory app (verified on macOS 26). Never decide activation policy by counting `NSApp.windows` without filtering — the `MenuBarExtra` popover is an `NSStatusBarWindow` and counting it strands the app in `.regular` forever.

8. **User-facing repair copy lives in `RepairCopy.swift`, and it is under test.** The notification, the menu receipt, and the activity list must say the same thing in the same voice. `FennecTests/RepairCopyTests.swift` pins the exact strings, including a check that nothing shouts or uses emoji. If you need new copy, add it there rather than inlining a string in a view.

---

## 4. Source map

```
Fennec/                        app target (15 Swift files, 1 C file)
  FennecApp.swift              @main, MenuBarExtra scene, FennecBrand color tokens
  AppModel.swift               orchestrator: state, cooldown, safety gating, repair decisions
  MenuView.swift               menu-bar popover UI
  SettingsView.swift           Settings scene
  SettingsStore.swift          UserDefaults-backed preferences
  CoreAudioMonitor.swift       attaches/rebuilds the listener graph
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
  RepairCopy.swift             every user-facing sentence about a repair  ← see rule 7
  SetupChecklist.swift         pure readiness model behind every setup CTA
  NotificationBudget.swift     rate limiter for the one banner class that bursts
  SystemEvents.swift           wake/unlock/session quiet windows + console-session gate
  PendingConfirmation.swift    the inline confirmation card's model  ← see rule 8
  MenuBarIcon.swift            the fennec silhouette, drawn as a template NSImage
  WindowPresenter.swift        every window + activation-policy switching  ← see rule 9
  AppDelegate.swift            reopen and quit-during-repair handling
  SetupStepRow.swift           one setup step, shared by the popover and Settings
  WelcomeView.swift            first run: a consent record, not a tour
  PrivilegeDisclosure.swift    every privileged path, stated once  ← see rule 10
  InstallLocation.swift        guards the /Applications requirement
  ConfirmationPresentation.swift  the confirmation sheet for real windows
  PauseSchedule.swift          pause durations and the persisted pause state
  RepairGovernor.swift         verification window + the stand-down breaker  ← see rule 11
  AboutView.swift              the privilege panel: what runs as root, and removal
  Uninstaller.swift            the removal plan, and performing it  ← see rule 12
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
Docs/                          ARCHITECTURE.md, VALIDATION.md, SOURCE_MANIFEST.sha256
Brand/                         Fennec-AppIcon-Master.png (1254×1254), README.md
```

Read `Docs/ARCHITECTURE.md` for the detection path, suppression windows, and failure behavior. It is accurate and current.

---

## 5. Build, verify, commit

All commands run from the repo root.

**Build (this is the exact invocation that is known green — no signing overrides needed):**

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

Writes to `build/DerivedData/`, which is gitignored. It ends by *printing* the `/Applications` install commands — it does not run them. Do not run them yourself (rule 4).

**Regenerate `Docs/SOURCE_MANIFEST.sha256` after editing tracked files:**

```bash
zsh Scripts/update-manifest.sh
```

It rebuilds the manifest from `git ls-files` plus anything staged for addition, so new files are picked up automatically. `audit-source.sh` now verifies the manifest with `shasum -c` and fails if it is stale, so a forgotten regeneration is caught instead of silently shipped.

**Run the unit tests:**

```bash
xcodebuild -project Fennec.xcodeproj -scheme Fennec \
  -configuration Debug -destination 'platform=macOS' test
```

`FennecTests` is a **standalone** XCTest bundle with no `TEST_HOST`: it compiles Fennec's pure-logic sources directly instead of loading the app. That is deliberate — hosting the tests in `Fennec.app` would start Core Audio monitoring, request notification authorization, and touch the user's real Application Support directory on every run. Anything that talks to Core Audio, `SMAppService`, or XPC is **not** unit-testable here and belongs in [T-005](#open).

To put another source file under test, add a `PBXBuildFile` for its existing `PBXFileReference` to the `FennecTests` Sources phase (or drag it into the target in Xcode).

### Definition of done

A change is not done until:

- [ ] `Fennec` and `FennecHelper` build in **both** Debug and Release
- [ ] `xcodebuild … test` passes with no failures
- [ ] `zsh Scripts/audit-source.sh` passes
- [ ] No **new** compiler warnings (4 pre-existing ones are catalogued in [T-007](#open) / [T-008](#open))
- [ ] `Docs/SOURCE_MANIFEST.sha256` regenerated
- [ ] The task ledger in §8 updated — entry moved to Done, or a new entry appended
- [ ] Anything requiring a physical device or root is explicitly listed in your report as *not verified*

### Git conventions

Work on a branch; `main` is the release line. Commit messages: a short subject, then *why* in the body. End with:

```
Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
```

Do not commit `build/`, `DerivedData/`, `xcuserdata/`, or `.DS_Store` — `.gitignore` already covers all four. Do not push or open a PR unless asked.

---

## 6. Known traps

Each of these has already cost real time. Do not rediscover them.

**`SecCode` vs `SecStaticCode`.** `SecCodeCopySigningInformation` is typed to take a `SecStaticCode`. `SecCodeRef` and `SecStaticCodeRef` wrap the same opaque C struct and the C API accepts either, but Swift imports them as unrelated types. `Shared/CodeSigningRequirement.swift` bridges with `unsafeBitCast`. That is correct — do not "fix" it into a `SecCodeCopyStaticCode` round-trip, which reads the on-disk image and can fail if the bundle moved.

**`path` is a reserved variable in zsh.** zsh ties `$path` (array) to `$PATH` (string). Using `path` as a loop variable in any script under `Scripts/` silently destroys `PATH`, and every subsequent command dies with `command not found`. This bit `audit-source.sh`, where it surfaced as the *misleading* error "The helper copy phase is not targeting the app Executables directory." Both scripts are `#!/bin/zsh` with `set -euo pipefail`. Other zsh-tied names to avoid: `cdpath`, `fpath`, `manpath`, `argv`, `status`.

**The helper is embedded in `Contents/MacOS/`, not `Contents/Library/LaunchServices/`.** This is the modern `SMAppService` daemon layout, not the legacy `SMJobBless` one. `audit-source.sh` asserts `dstSubfolderSpec = 6`, `CodeSignOnCopy`, `ENABLE_DEBUG_DYLIB_SUPPORT = NO` in both helper configurations, and that the LaunchDaemon's `BundleProgram` is `Contents/MacOS/FennecHelper`. If you touch the project file, re-run the audit.

**`ENABLE_DEBUG_DYLIB_SUPPORT = NO` is deliberate** on the helper. Xcode's debug-dylib splitting breaks a daemon that must be a single signed Mach-O.

**SourceKit/IDE diagnostics can disagree with the compiler.** Trust `xcodebuild` output over in-editor squiggles.

**`Docs/VALIDATION.md` is a point-in-time report, not a live status.** It is dated 2026-08-20 and describes an environment without Xcode. It is now partly stale ([T-010](#open)). Treat §5 of *this* file as the authority on how to build.

---

## 7. Brand direction

Everything below is derived from `Brand/Fennec-AppIcon-Master.png`. When a decision is ambiguous, go back to that image.

### The image, read literally

A cream fennec fox, dead-centre, cropped tight and facing you head-on. Enormous ears run off the top of the frame. Gold-rimmed aviators. Full-size **open-back** headphones with visible driver mesh, cables trailing down out of frame. Behind: a flat cobalt sky and two orange dune ridges — one bright, one in shadow — meeting at a lazy diagonal. No texture, no gradient, no noise. Hard-edged vector shapes and a mouth that is not smiling.

### What it means

Three ideas in tension, and the tension *is* the brand:

**Audiophile precision.** The headphones are the tell. Open-back cans leak sound in every direction — nobody wears them on a train. They mean a person who sits still in one room and cares what the soundstage does. That is Fennec's actual claim: it is not a general "sound fixer," it detects one specific Core Audio failure that only people who notice would notice.

**Punk stance.** Not punk *ornament* — there is no distressed texture, no ransom-note type, no chaos in this art, and there should be none in the UI. The punk is in the posture: a small, unsigned, local-only tool that fixes the thing itself instead of filing a radar and waiting. No telemetry, no account, no cloud. It restarts a system daemon on your behalf and doesn't make a ceremony of it. DIY, self-hosted, unbothered.

**Desert stillness.** Deadvlei at noon. Flat light, no weather, nothing moving. A fennec is a listening animal — the ears are oversized precisely because the desert is silent and it is built to detect the one signal that matters. That is the product, drawn.

Composite: **a calm, oversized listener in a silent place, wearing gear that means business, that will quietly fix your audio and never mention it again.**

### Voice

Deadpan, specific, technically literal. Confident without selling. The fox is not grinning and neither is the copy.

| Do | Don't |
|---|---|
| "Core Audio overloaded twice in 8 seconds." | "Uh oh! Something went wrong 😬" |
| "Repair Audio Now" | "Fix My Sound!" |
| "Skipped — microphone is active." | "We couldn't do that right now." |
| "Detects the failure signal, not the sound." | "AI-powered audio healing." |

State the mechanism. Name the threshold. Admit the limitation — the README already does this well ("Fennec detects the Core Audio failure signal, not the acoustic sound"). Keep that register. No exclamation marks, no emoji in product UI, no anthropomorphising the fox in copy.

### Palette

Two columns, because they currently disagree. **Left** is what ships today (`Brand/README.md`, mirrored as floats in `FennecBrand` in `Fennec/FennecApp.swift`). **Right** is sampled directly from the master art.

| Role | Shipped token | Sampled from art | Δ |
|---|---|---|---|
| Sky | `#2E82CC` | `#2373C3` | shipped runs lighter/brighter |
| Dune | `#F47A1F` | `#EF792D` | shipped runs more saturated |
| Cream | `#FFE3AB` | `#FDDCAF` | shipped runs warmer |
| Sand | `#EFB76E` | `#ECB478` | near-identical |
| Ink | `#1F1F1C` | `#2C2927` | shipped runs materially darker |

The drift is small but consistent and nothing reconciles it. Resolving it is [T-009](#open) — **do not silently restyle the app to close the gap**, it is a design call for the owner.

Three colours exist in the art with **no token at all**. They are the most characterful part of the image and the palette is poorer without them:

| Role | Hex | Where it comes from |
|---|---|---|
| **Aviator gold** | `#DA963E` | the sunglass frames — the single warm-metal accent |
| **Lens void** | `#23190E` | inside the lenses; a brown-black, not a neutral black |
| **Dune shadow** | `#BD5D26` | the darker ridge, for orange depth without going brown |
| **Twilight blue** | `#294D70` | shadowed blue, for depth against the sky |

Aviator gold is the highest-value addition: it is the only precious-metal note in an otherwise flat, matte palette, and it is exactly the audiophile-hardware cue (brass, VU needles, XLR pins).

### Colour semantics

Keep the existing mapping — it is already coherent:

- **Sky** — healthy, listening, nominal. The primary action tint (`.tint(FennecBrand.sky)` in `FennecApp.swift`). Blue means *Fennec is awake and hearing nothing wrong*.
- **Dune** — audio, output, and warning. Signals detected, thresholds approached, transient suppression.
- **Sand / Cream** — surfaces and mascot framing only. Never a state colour.
- **Ink** — text and hardware-adjacent chrome.
- **Aviator gold** — reserved, and now in use: a repair that **held**. Not a repair that merely returned successfully — see rule 11. A rare, warm, earned accent, never a third warning colour.
- **Sand + ink together** — the days-without-incident sign, and nothing else. It is the one element that keeps fixed colours in both appearances, because a safety sign is a physical object and physical objects do not invert at dusk.

Blue and orange are complementary and near-maximum contrast at full strength. Do not put dune orange on sky blue in body text — use ink or cream on either.

### Form

- **Flat vector, hard edges.** No gradients, no drop shadows, no glass, no glow. The icon has zero soft edges and the UI should match.
- **Geometry over ornament.** The dune ridge is one lazy diagonal. Prefer one confident shape to three fussy ones.
- **Generous negative space.** The top third of the icon is empty sky. Let panels breathe.
- **Centred, symmetrical, frontal** for anything mascot-adjacent. The fox looks straight at you.
- **Crop confidently.** The ears run off the frame. Do not shrink art to fit a box.
- **System typography.** SF, native weights. The audiophile signal comes from precision and alignment, not a display face. If a monospace register is ever needed, reserve it for actual data — device names, PIDs, timestamps, counters — never prose.
- **Motion:** short, linear, unfussy. Nothing bounces. Nothing pulses for attention. The desert does not animate.

### Anti-patterns

Waveform/equalizer bar clichés · neon or cyberpunk gradients · distressed grunge or torn-paper "punk" textures · glassmorphism · cartoon-cute fox (this fox is cool, not adorable) · dark-mode-only design (it is a system utility; respect both appearances) · celebratory confetti or success animation · any typeface with attitude.

---

## 8. Task ledger

**This is the shared to-do list. Append to it; do not rewrite it.**

### Protocol

1. Before starting, read this section and claim a task by setting **Status** to `In progress` and putting your agent/session identifier in **Owner**.
2. IDs are `T-NNN`, assigned sequentially and **never reused**. Next free ID: **T-024**.
3. New work discovered mid-task → append a new row to **Open**. Do not silently expand the task you claimed.
4. On completion, move the row to **Done** with the completion date and the commit SHA.
5. If you abandon a task, set Status back to `Open`, clear Owner, and add a note saying what you learned. A dead end recorded is worth more than a blank row.
6. Never delete a Done row. This is the project's memory.
7. Priorities: **P0** blocks trusting the product · **P1** should happen next · **P2** nice to have.

### Open

| ID | P | Task | Status | Owner | Notes |
|---|---|---|---|---|---|
| T-005 | P0 | Run the 9-step on-device runtime validation in `Docs/VALIDATION.md` §"Still required on macOS" | Open | — | **Requires a human.** Needs signing, `/Applications` install, helper approval in System Settings, and reproducing the audible fault. Until this is done, nobody should trust automatic repair or switch detection to Immediate. Agents must not attempt this unsupervised (rule 4). |
| T-007 | P2 | Fix 2 unsafe-pointer warnings in `CoreAudioProperty.swift:192` and `:223` | Open | — | "forming `UnsafeMutableRawPointer` to a variable of type `T` / `Optional<CFString>`; may contain an object reference." Real hazard for the `CFString` case. Touches Core Audio property reads — verify carefully. |
| T-008 | P2 | Fix 2 non-`Sendable` capture warnings in `HelperManager.swift:90` and `:135` | Open | — | `NSXPCConnection` captured in `@Sendable` closures. Will become an error under Swift 6 language mode; project is currently `SWIFT_VERSION = 5.0`. |
| T-009 | P2 | Reconcile brand tokens against the master art | Open | — | See the drift table in §7. Decide per-role whether the art or the shipped token wins, then align `Brand/README.md` and `FennecBrand` in `FennecApp.swift`. Consider adding aviator gold `#DA963E` and lens void `#23190E` as tokens. **Owner's design call — propose, don't unilaterally apply.** |

### Done

| ID | Task | Completed | Commit | Notes |
|---|---|---|---|---|
| T-001 | Get the project building in Xcode | 2026-08-25 | `aa22cc6` | One compile error: `SecCodeCopySigningInformation` was passed a `SecCode` where Swift demands `SecStaticCode`. Bridged with `unsafeBitCast` — see §6. Verified green across `Fennec`/`FennecHelper` × Debug/Release, plus a clean Release build; helper confirmed embedded at `Fennec.app/Contents/MacOS/FennecHelper`. |
| T-002 | Fix `Scripts/audit-source.sh` | 2026-08-25 | `aa22cc6` | Loop variable `path` clobbered `$PATH` under zsh, failing every command from line 31 onward and reporting a false packaging error. Renamed to `required_path`. Audit now passes end to end. See §6. |
| T-003 | Publish to GitHub | 2026-08-25 | `aa22cc6` | `git init` (repo had no `.git` despite appearances), initial commit of 56 files, pushed to `alexcox245/Fennec` — private, default branch `main`. |
| T-004 | Regenerate `Docs/SOURCE_MANIFEST.sha256` | 2026-08-25 | `aa22cc6` | Rehashed after the T-001/T-002 edits. |
| T-006 | Add a unit-test target covering `DetectionEngine` and `EventLogger` | 2026-08-25 | `b0af227` | `FennecTests`, a standalone XCTest bundle (no `TEST_HOST`) compiling the pure-logic sources directly. `EventLogger` gained an injectable directory and size cap plus a test-only `flush(completion:)` so rotation is observable without writing 5 MB. Scheme `Fennec` now has a TestAction. |
| T-011 | Make `audit-source.sh` verify `Docs/SOURCE_MANIFEST.sha256` | 2026-08-25 | `b0af227` | Added `Scripts/update-manifest.sh` (regenerates from `git ls-files`, so new files are never missed) and a `shasum -c` gate at the end of `audit-source.sh`. `FennecTests/*.swift` added to the per-file Swift parse. |
| T-013 | Catch & Fix: automatic repair the user can see | 2026-08-25 | `35d35e8` | Auto-repair now defaults **on** (still inert until the helper is enabled). `DetectionDecision` carries the real elapsed span between signals, not just the configured window, so the copy can say "2 crackle signals in 5.8 s". Every repair is timed across the privileged call only and persisted as a `RepairRecord` in `repairs.json`; the popover shows the newest as a receipt in aviator gold, plus a running total. Notifications were rebuilt around proportionality: success is `.passive` with no sound and no buttons, failure and unrepaired-detection get a sound and an action. |
| T-014 | Always On: start with the Mac, and say what is left to do | 2026-08-25 | `bccc379` | `LoginItemState` wraps `SMAppService.Status` with a name and a next step, and `LoginItemManager` re-reads it on every `didBecomeActive` because the user can switch Fennec off in System Settings without telling the app. `SMAppServiceErrorDomain` failures are translated into the cause that is almost always true. New `SetupChecklist` is the single pure model behind every setup CTA — the popover, Settings, and (later) first-run cannot disagree about what a button means. |
| T-015 | Stop being hostile out of the box | 2026-08-25 | `1fd2b4d` | Four confirmed defects. (1) The cooldown was keyed on the last *successful* repair and sat **below** the helper gate, so a fresh install had no cooldown at all; it now keys on the last attempt and gates everything. (2) `NotificationBudget` rate-limits unrepaired-detection banners to one per 10 min and reports how many it swallowed — suppression is never silent. Stable per-class request identifiers mean a new banner replaces its predecessor rather than stacking. (3) `SystemEvents` adds quiet windows after wake (20 s), screen wake, unlock, fast-user-switch, and launch; without them the first thing Fennec did when a lid opened was restart the audio daemon. (4) The silent `osascript` fallback on an XPC failure is gone — an unexplained admin-password dialog is the visual signature of credential phishing, so Fennec now asks first and shows the literal command. Also: automatic repair is gated on being the console session, and a failed repair leaves a persistent attention mark in the menu bar rather than relying on a sound played through the audio system that is by hypothesis broken. |
| T-016 | Windows that behave like a Mac app | 2026-08-25 | `a38bf8d` | `WindowPresenter` owns every window and flips the activation policy so ⌘W/⌘Q/⌘, and the Dock icon exist for exactly as long as a window does. SwiftUI's `Settings` scene is gone — `showSettingsWindow:` returns `true` and opens nothing in an accessory app on macOS 26, verified by launching the built app and listing windows with `CGWindowListCopyWindowInfo`. `AppDelegate` adds reopen handling (double-clicking a running menu-bar app did nothing at all) and holds quit open for an in-flight repair. Settings lost its mascot banner: a `TabView` hoists its picker into the title bar, so the banner rendered *between* the tabs and their content, and rule 6 says the brand does not belong in a re-skinned system utility anyway. Settings and the popover now share `SetupStepRow`, and the popover uses a one-line `compactDetail` because three five-line paragraphs in a 384 pt popover is a wall, not onboarding. |
| T-017 | First run: a consent record, not a welcome tour | 2026-08-25 | `b525569` | Before this, double-clicking Fennec produced nothing at all — no window, no Dock icon, one more glyph in a crowded menu bar. The window states the **complete** privileged surface before asking for any of it (including the `osascript` administrator path, which every obvious version of this panel would have omitted), costs a repair in plain seconds, and ends with a real repair the user runs on purpose while nothing is at stake. No test tone: Fennec does not know the user's monitor gain. `InstallLocation` guards the `/Applications` requirement that the README previously only documented. The actual menu-bar mark is rendered inline under "Where Fennec lives", with the three real reasons a status item goes missing. |
| T-018 | Pause | 2026-08-25 | `5c19039` | The manual override. Fennec's safety checks can only see what Core Audio tells them; a person about to hit record knows more than that. `PauseState` is persisted as two plain values so a timestamp that expired while Fennec was not running resolves to "running" on the next read rather than reviving a dead pause. Every duration except the last expires on its own and posts one passive banner when it does, and the menu-bar mark carries its own paused variant, so a pause can never be quietly left on. Blocks automatic repair only — Repair Audio Now keeps working, because a person pressing the button has decided. The real reason it exists is retention: the alternative to a two-hour pause is a professional switching automatic repair off permanently after one mistimed restart. |
| T-019 | Stop claiming "fixed" until it holds | 2026-08-25 | `af1e9a5` | `RepairRecord` gained an outcome (`pending` → `held`/`returned`/`failed`), decoded tolerantly so `repairs.json` files from earlier builds still read. A detection inside the 60 s verification window marks the last repair `returned` and *replaces* the success banner in place rather than stacking a contradiction under it. Gold, and the headline tally, now require `held`. `RepairGovernor` stands Fennec down for an hour after three automatic repairs in twenty minutes that did not hold — otherwise a machine where the restart is not the cure gets its audio silenced every 45 seconds, forever, by the default configuration doing exactly what it was told. The stand-down states the real numbers and names the possibility the user needs to consider. |
| T-012 | Add a `LICENSE` | 2026-08-25 | `8b3142e` | MIT. Landed with `SECURITY.md` (disclosure contact, the privilege boundary stated precisely, and the second privileged path named rather than buried) and `UNINSTALL.md`. |
| T-020 | Take it back: uninstall, and the privilege panel | 2026-08-25 | `8b3142e` | Closes the gap nobody in the review had ranked: the root daemon survives dragging Fennec to the Trash. `Uninstaller` unregisters the daemon, removes the login item, optionally deletes the support folder, forgets preferences, moves the bundle to the Trash, and reports each step's failure separately. `AboutView` replaces the stock About panel with the four things a person evaluating a root-privileged 3 MB app actually asks: what it can do, what is running as root *right now* (read back over XPC — `ping` now returns a parseable reply, no protocol change), how to verify the build against `SOURCE_MANIFEST.sha256`, and how to remove all of it. Also closes T-012: `LICENSE`, plus `SECURITY.md` and `UNINSTALL.md`. |
| T-021 | Activity, and the sign on the wall | 2026-08-25 | `0e7fc1d` | `ActivityView` is a receipt book grouped by day, deliberately not a sortable table with filters and CSV export — every version of that is a window someone opens once, on install day, to find empty. The delighter is `DaysWithoutIncident`: an industrial safety sign in sand and ink that counts calendar days and reads **0** on a repair day with no softening. It does not invert with the appearance, because a sign is a physical object; sand is a surface and ink is the number, which is exactly what the palette reserves them for. It changes only at midnight — a sign that ticks is a timer, and nobody should watch this. |
| T-022 | Idle cost, and the documents this repo is judged by | 2026-08-25 | `4e6f5c9` | The drain timer ran at 250 ms forever, whether or not a signal had ever arrived — a product whose proudest claim is stillness should not be the loudest thing in Activity Monitor. `DrainSchedule` steps to 1 s after a quiet minute and 2 s after five, with generous leeway so the kernel can coalesce the wake-ups, and snaps back on the first non-empty drain. Safe because the property listener runs on Core Audio's side regardless and the counters are atomic: backing off delays noticing a signal, it never loses one — pinned by a test that the slowest tier still outpaces the tightest detection window. Plus `CHANGELOG.md`, a rewritten README (Gatekeeper, the `/Applications` requirement, verifying a build, uninstall, and the shell-alias question), and `.github/workflows/ci.yml`. |
| T-023 | Adversarial review, and the fixes | 2026-08-25 | `1825767` | Three lenses (IA, UX, macOS engineering) read the shipped tree; every finding was then verified against the source by a separate reviewer, and 33 survived. **Two blockers**: uninstall could trash the app after the daemon unregister failed — and silently skipped the daemon entirely when it was `.awaitingApproval`, because the plan keyed off reachability rather than registration, then reported "Fennec is removed"; and a failed listener rebuild after a service restart left the monitor with a timer and no ears while the popover kept showing a blue dot and "Listening". Nine majors, including a first-run window that only completed on the Done button (so ⌘W meant it reappeared at every login forever), a quit-grace timer scheduled in `.default` mode under `.terminateLater` (so ⌘Q during a repair hung until Force Quit), confirmations raised with no window to host them, a gold seal painted from `succeeded` above the words "the fault came back", and both a declined password prompt and the helper's own 20-second rate limiter recorded as failed repairs with an alarm. |
| T-010 | Refresh `Docs/VALIDATION.md` | 2026-08-25 | `9a33c30` | Rewritten. It claimed the source "has not been SDK type-checked, linked, [or] code-signed", which stopped being true at T-001. Now states what is verified and how (build matrix, 204 tests, audit, codesign), what was exercised by hand on this machine, and — kept and expanded — what still needs a device, including the three new things that cannot be tested without a live root daemon. The matching README claim was fixed in `4e6f5c9`. |

---

## 9. Before you hand off

Report honestly and specifically:

- What you changed, and **why** — not just what.
- Which checks you actually ran, with their real output. If something failed, say so and paste it.
- What you could **not** verify — anything needing a physical audio device, root, user approval, or a reproduction of the audible fault. This project has a large untestable surface; pretending otherwise is the main way to do damage here.
- Which ledger rows you moved, and any rows you appended.
