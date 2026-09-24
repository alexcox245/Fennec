# Fennec

A macOS menu-bar utility for one specific failure: Core Audio starts crackling
under heavy local load and stays broken until `coreaudiod` is restarted.

Fennec watches the current output device for missed real-time deadlines. When
the fault is confirmed and its safety checks pass, it restarts Core Audio
through a tightly scoped root helper, leaving every application open, and
reports what happened without claiming the repair held before it is verified.

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
- Watches `coreaudiod`'s own overload record in the unified log as a second,
  independent witness. The overload notification only fires in the process
  whose IO cycle missed its deadline, so when the misbehaving client is some
  other app or daemon, the listener hears nothing while the speakers crackle.
  `coreaudiod` logs every overload it detects, for every client, and Fennec
  polls that record only while audio is actually playing.
- Tells stalling apart from crackling. Playback that keeps stopping and
  starting on a starved Mac (heavy load, memory pressure) is not a Core
  Audio fault, and restarting Core Audio will not fix it. When Fennec sees
  that pattern (clean IO stops while the system is busy) it says so, once,
  instead of staying silent or offering the wrong cure.
- Shows the last 30 seconds live. The popover carries a small rolling graph
  of overload signals against the exact repair threshold, with playback
  stalls marked along the baseline. It costs nothing while the popover is
  closed.
- Does **no** work in the real-time audio callback: only relaxed atomic
  increments on preallocated storage. Everything else happens after a timer
  drains those counters onto a normal queue.
- Waits for the fault to confirm itself. One overload is usually a harmless
  blip; two in a row is the failure that stays broken. You hear about a second
  of crackle, then it is gone; up to a couple of minutes when only the log
  path can see the fault, because polling the log costs CPU and Fennec's
  whole budget is under one percent of a core.
- Can repair automatically with the approved helper, or ask before each repair
  if you prefer not to enable it. The prompted path shows the administrator
  command before macOS asks for a password.
- Restarts Core Audio through a root helper that can do exactly one thing.
- Shows the fox crossing the bottom of the display while a repair runs. You
  can turn it off in Settings; Reduce Motion suppresses the animation.
- Rebuilds the helper's registration itself when macOS reports it enabled but
  it stops answering, the state a replaced or moved app leaves behind. No
  password is involved; the attempt and its outcome go in the event log.
- Verifies the repair. A restart is *provisional* until the fault has failed to
  return for a minute; Fennec does not call it fixed before then.
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
- It cannot recognise a Mac that was already broken before Fennec started;
  use **Repair Audio Now** for that.
- The log witness reads the system log store, which requires an administrator
  account and keys on message text Apple can reword in any macOS release. If
  either fails, Fennec says so once in Activity and the listener path carries
  on alone.
- Restarting Core Audio briefly disconnects playback and recording for every
  app and every logged-in user. The goal is a sub-second recovery, not a
  gapless one.

The repair monitor and repair path stay on this Mac. The only network activity
is a signed update check when you choose **Check for Updates**, followed by a
download only when you choose it. Fennec sends no system profile, account data,
telemetry, or crash reports. No kernel extension, audio driver, or virtual
device.

## Requirements

- macOS 14.2 or later, Apple silicon
- Xcode 26 to build (verified on 26.6)
- An Apple Development or Developer ID signing team for both targets

Fennec is intentionally **not** sandboxed: `SMAppService` daemon registration
requires it.

## Install

For a published release, download `Fennec.zip` from the
[latest GitHub release](https://github.com/alexcox245/Fennec/releases/latest),
unzip it, move `Fennec.app` to `/Applications`, and open it there. Check that
the release identifies the archive as notarized before installing. Until the
first public release is posted, you can build from source:

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

Do not bypass a macOS security warning for an unsigned or unnotarized copy.
The published archive should pass Gatekeeper and carry the team's Developer ID
signature.

## First run

The first window lets you choose **Automatically** or **Ask me first**.
Automatic repair needs the approved helper. Asked repairs work without it and
show the administrator command before macOS asks for a password. Startup and
notifications are optional; the one-time test repair is optional too.

Recommended settings for the MacBook + heavy-local-workload case: **Balanced**,
protections on, skip Bluetooth on, cooldown 45 s. Move to **Immediate** only
after you have confirmed that a single overload correlates with what you
actually hear.

## Security

The helper exposes exactly two XPC methods and runs one command, fixed at
compile time. Both ends verify the other's Team ID and bundle identifier.
The other privileged paths are a standard administrator prompt, used only
when the helper is unavailable and after Fennec shows you the command, and
authorization macOS may request when an explicitly chosen update replaces
Fennec in Applications. See [`SECURITY.md`](SECURITY.md) for the full boundary
and for how to report a vulnerability.

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

# Test: the unit suite, standalone bundle, no app launch
xcodebuild -project Fennec.xcodeproj -scheme Fennec \
  -configuration Debug -destination 'platform=macOS' test

# Static audit: plists, packaging, per-file Swift parse, C warnings, manifest
zsh Scripts/audit-source.sh

# Everything, plus a clean build and codesign --verify
zsh Scripts/build-release.sh
```

## Validation status

The latest recorded complete check built all four app/helper Debug and Release
configurations with signing, passed 290 standalone tests and the source audit,
and verified a notarized Developer ID export of the previous candidate. The
final build 2 candidate requires its own verification; see
[`Docs/VALIDATION.md`](Docs/VALIDATION.md) for exact evidence and remaining
hands-on checks. Do not switch detection to **Immediate** until T-005 in
`AGENTS.md` §8 is complete.

## Layout

```text
Fennec/               the app
FennecHelper/         the root LaunchDaemon
FennecTests/          standalone XCTest bundle (no TEST_HOST)
Shared/               XPC protocol, identifiers, signing checks
LaunchDaemons/        SMAppService property list
Scripts/              build, audit, and manifest tooling
Docs/                 ARCHITECTURE.md, ROADMAP.md, UPDATES.md, VALIDATION.md, SOURCE_MANIFEST.sha256
Brand/                the master icon art and what it means
AGENTS.md             ground rules, known traps, brand direction, task ledger
```

`AGENTS.md` is the entry point for anyone, human or otherwise, working on
this repository. Read it first.

## Apple references

- [`kAudioDeviceProcessorOverload`](https://developer.apple.com/documentation/coreaudio/kaudiodeviceprocessoroverload)
- [`kAudioDevicePropertyIOStoppedAbnormally`](https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyiostoppedabnormally)
- [`AudioObjectAddPropertyListenerBlock`](https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:))
- [`SMAppService`](https://developer.apple.com/documentation/servicemanagement/smappservice)
- [`NSXPCConnection.setCodeSigningRequirement`](https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:))

## Licence

MIT. See [`LICENSE`](LICENSE).
