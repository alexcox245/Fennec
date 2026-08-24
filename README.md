# Fennec

A macOS menu-bar utility for one specific failure: Core Audio starts crackling
under heavy local load and stays broken until `coreaudiod` is restarted.

Fennec watches the current output device for missed real-time deadlines. When
the fault is confirmed and its safety checks pass, it restarts Core Audio
through a tightly scoped root helper — leaving every application open — and
tells you what it did, in numbers.

<img src="Brand/Fennec-AppIcon-Master.png" width="180" alt="Fennec app icon">

## Why this is not a shell alias

Restarting Core Audio is one command, and if you are reading this you probably
already know it:

```zsh
sudo killall coreaudiod
```

Fennec's job is the parts around it. Noticing at 2am that the fault started.
Refusing while your microphone is live, while a call app is using audio, or
when you are not the session at the keyboard. Refusing *again* when the last
restart did not help, instead of silencing your audio every 45 seconds
forever. And writing down what it saw, so you can tell whether the problem is
Core Audio or your hardware.

If none of that is worth a menu-bar item to you, the command above is genuinely
the right answer.

## What it actually does

- Attaches Core Audio property listeners to the current default output device
  and watches for `kAudioDeviceProcessorOverload` and
  `kAudioDevicePropertyIOStoppedAbnormally`.
- Does **no** work in the real-time audio callback — only relaxed atomic
  increments on preallocated storage. Everything else happens after a timer
  drains those counters onto a normal queue.
- Waits for the fault to confirm itself. One overload is usually a harmless
  blip; two in a row is the failure that stays broken. You hear about a second
  of crackle, then it is gone.
- Restarts Core Audio through a root helper that can do exactly one thing.
- Verifies the repair. A restart is *provisional* until the fault has failed to
  return for a minute — Fennec does not call it fixed before then.
- Gives up when it should. Three restarts that did not hold means restarting is
  not the cure, so Fennec stands down for an hour and says so.
- Stays quiet after wake, screen unlock, and fast-user-switch, because Core
  Audio renegotiates the whole output path at those moments and would otherwise
  look exactly like the fault.
- Rebuilds its entire listener graph after a Core Audio service restart.
- Keeps a rotating event log and a receipt for every repair, both plain text,
  both on your Mac only.

## What it does not do

**Fennec detects the failure *signal*, not the sound.** That is the best
low-overhead system-level signal for this fault, but it is a proxy:

- It cannot prove every overload was audible.
- It cannot recognise a Mac that was already broken before Fennec started —
  use **Repair Audio Now** for that.
- Restarting Core Audio briefly disconnects playback and recording for every
  app and every logged-in user. The goal is a sub-second recovery, not a
  gapless one.

No network code of any kind. No account, no telemetry, no update check, no
crash reporting. No kernel extension, no audio driver, no virtual device.

## Requirements

- macOS 14.2 or later, Apple silicon
- Xcode 26 to build (verified on 26.6)
- An Apple Development or Developer ID signing team for both targets

Fennec is intentionally **not** sandboxed: `SMAppService` daemon registration
requires it.

## Install

Fennec has no notarised release build yet, so you build it yourself.

```zsh
git clone https://github.com/alexcox245/Fennec.git
cd Fennec
open Fennec.xcodeproj      # set your signing team on both targets
zsh Scripts/build-release.sh
```

Then **copy the built app to `/Applications` before enabling the helper**.
This is not a style preference: `SMAppService` binds the helper's registration
to the app's bundle path, so enabling it from `~/Downloads` and moving the app
later produces a helper that is registered, not running, and gives no
explanation. Fennec checks its own location on first run and refuses to offer
the Enable button when it is somewhere that will break.

If you ever run an unsigned or un-notarised copy from a download, macOS will
refuse it with *"Fennec is damaged and can't be opened"* or *"Apple could not
verify Fennec is free of malware."* Right-click → **Open**, or
**System Settings → Privacy & Security → Open Anyway**.

## First run

Launching Fennec opens a window that states, before asking for anything:

- the complete privileged surface — both XPC methods **and** the administrator
  prompt path;
- what a repair costs, in seconds;
- that there is no network code;
- the two files it writes and where.

Then it offers a **test repair** you run on purpose, while nothing is at
stake, so you know exactly what an automatic one will cost on your machine.
It does not play a test tone: Fennec does not know your monitor gain, and a
sine wave through open-back headphones at whatever level the last session left
them is a hearing risk.

Recommended settings for the MacBook + heavy-local-workload case: **Balanced**,
protections on, skip Bluetooth on, cooldown 45 s. Move to **Immediate** only
after you have confirmed that a single overload correlates with what you
actually hear.

## Security

The helper exposes exactly two XPC methods and runs one command, fixed at
compile time. Both ends verify the other's Team ID and bundle identifier.
There is a second privileged path — a standard administrator prompt, used only
when the helper is not installed and only after Fennec has shown you the
command. See [`SECURITY.md`](SECURITY.md) for the full boundary and for how to
report a vulnerability.

## Verify this build

`Docs/SOURCE_MANIFEST.sha256` is a SHA-256 of every tracked source file, and
`Scripts/audit-source.sh` fails if the tree does not match it. So you can check
that the code you are reading is the code that built the binary:

```zsh
shasum -a 256 -c Docs/SOURCE_MANIFEST.sha256
codesign -dv --verbose=4 /Applications/Fennec.app
codesign -dv --verbose=4 /Applications/Fennec.app/Contents/MacOS/FennecHelper
```

The same three commands are in **About Fennec**, with a Copy button.

## Uninstall

Dragging Fennec to the Trash leaves the root LaunchDaemon registered with
macOS. **About Fennec → Uninstall Fennec…** removes all of it. If the app is
already gone, see [`UNINSTALL.md`](UNINSTALL.md) for the command-line
fallback.

## Build, test, verify

```zsh
# Build
xcodebuild -project Fennec.xcodeproj -scheme Fennec \
  -configuration Release -destination 'platform=macOS' build

# Test — 187 unit tests, standalone bundle, no app launch
xcodebuild -project Fennec.xcodeproj -scheme Fennec \
  -configuration Debug -destination 'platform=macOS' test

# Static audit: plists, packaging, per-file Swift parse, C warnings, manifest
zsh Scripts/audit-source.sh

# Everything, plus a clean build and codesign --verify
zsh Scripts/build-release.sh
```

## Validation status

The full Debug and Release matrix builds for both targets, 187 unit tests
pass, `audit-source.sh` passes including the source-manifest check, and
`build-release.sh` verifies the bundle layout and code signature.

**Not yet verified on a device:** helper registration and the System Settings
approval flow, an actual privileged repair, notification delivery, and
detection against a reproduction of the audible fault. Those need a signed
build in `/Applications` and a human. They are tracked as **T-005** in
`AGENTS.md` §8, and nobody should switch detection to **Immediate** before
that is done.

## Layout

```text
Fennec/               the app
FennecHelper/         the root LaunchDaemon
FennecTests/          standalone XCTest bundle (no TEST_HOST)
Shared/               XPC protocol, identifiers, signing checks
LaunchDaemons/        SMAppService property list
Scripts/              build, audit, and manifest tooling
Docs/                 ARCHITECTURE.md, ROADMAP.md, VALIDATION.md, SOURCE_MANIFEST.sha256
Brand/                the master icon art and what it means
AGENTS.md             ground rules, known traps, brand direction, task ledger
```

`AGENTS.md` is the entry point for anyone — human or otherwise — working on
this repository. Read it first.

## Apple references

- [`kAudioDeviceProcessorOverload`](https://developer.apple.com/documentation/coreaudio/kaudiodeviceprocessoroverload)
- [`kAudioDevicePropertyIOStoppedAbnormally`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyiostoppedabnormally)
- [`AudioObjectAddPropertyListenerBlock`](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:))
- [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [`NSXPCConnection.setCodeSigningRequirement`](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))

## Licence

MIT. See [`LICENSE`](LICENSE).
