# Fennec

Fennec is a local-only macOS menu-bar utility for the specific failure mode where Core Audio begins crackling under heavy local workloads and stays corrupted until `coreaudiod` is restarted.

It watches the current output device for Core Audio processor-overload and abnormal-I/O notifications. When the configured threshold is reached, it can safely restart `coreaudiod` through a tightly restricted privileged helper while leaving Claude Code, Claude, Google Drive, Spotify, browsers, and other applications open.


## Visual identity

Fennec uses a compact desert-listening identity built around the app mascot: a cream fennec fox in aviators and open-back headphones against a Deadvlei-inspired blue sky and orange dunes. The UI intentionally keeps the illustration concentrated in the app icon and headers while the controls remain native macOS.

Core palette:

- Sky blue: `#2E82CC`
- Dune orange: `#F47A1F`
- Fennec cream: `#FFE3AB`
- Warm sand: `#EFB76E`
- Headphone ink: `#1F1F1C`

The branded asset is included as `FennecMascot` in the asset catalog, and the generated icon is supplied at every standard macOS app-icon size.

## What this build does

- Monitors the current default output device using native Core Audio property listeners.
- Detects:
  - `kAudioDeviceProcessorOverload`
  - `kAudioDevicePropertyIOStoppedAbnormally`
  - output-device, sample-rate, and Core Audio service changes
- Rebuilds the complete listener graph after a Core Audio service restart and suppresses normal transient signals during device/format renegotiation.
- Performs no allocation, logging, shell execution, UI work, or locking in the real-time Core Audio callback. The callback only increments C11 atomic counters.
- Supports Conservative, Balanced, and Immediate detection thresholds.
- Offers one-click manual repair at all times.
- Supports automatic repair through a root LaunchDaemon installed with `SMAppService`.
- Refuses automatic repair during active microphone input or protected call/recording apps by default.
- Skips Bluetooth outputs by default because the reported problem is mainly on built-in and wired output paths.
- Rate-limits repairs and keeps a rotating local JSONL audit log.
- Runs as a menu-bar app and can launch at login.

## Important limitation

Fennec detects the Core Audio failure signal, not the acoustic sound coming from the speaker. This is the best low-overhead system-level signal, but it is still a proxy:

- It can catch the overload that begins the crackling and repair immediately.
- It cannot prove that every overload was audible.
- It may not recognize a pre-existing corrupted state if Fennec was not running when the initiating event occurred. Use **Repair Audio Now** in that case.
- Restarting `coreaudiod` briefly disconnects playback and recording. The goal is an automatic sub-second recovery, not a mathematically gapless reset.

## Requirements

- macOS 14.2 or later
- Xcode 15.1 or later; Xcode 26 is recommended for macOS Tahoe
- An Apple Development or Developer ID signing team selected for both targets

The app is intentionally not sandboxed because a non-sandboxed `SMAppService` daemon is used for the fixed privileged repair action.

## Build

1. Open `Fennec.xcodeproj` in Xcode.
2. Select the **Fennec** project in the navigator.
3. Under **Signing & Capabilities**, select the same development team for both:
   - `Fennec`
   - `FennecHelper`
4. Build the shared `Fennec` scheme.
5. For reliable Service Management registration, copy the resulting `Fennec.app` to `/Applications` before enabling the helper.

You can also run:

```zsh
./Scripts/build-release.sh
```

The script assumes signing has already been configured in the Xcode project.

## First-run setup

1. Launch Fennec.
2. Open the menu-bar icon or **Settings → General**.
3. Click **Enable Helper**.
4. Approve Fennec under **System Settings → General → Login Items & Extensions → Allow in the Background** if macOS asks.
5. Return to Fennec and click **Recheck Helper**.
6. Enable **Repair automatically after a likely crackle event**.
7. Enable **Launch Fennec at login**.

Recommended settings for the reported MacBook/Claude Code issue:

- Detection sensitivity: **Balanced** initially
- After one confirmed test: **Immediate** for the fastest recovery
- Protect active microphone: **On**
- Protect call/recording apps: **On**
- Skip Bluetooth outputs: **On**
- Cooldown: **45 seconds**

## Controlled test

1. Start Spotify, VLC, or a long YouTube video on the MacBook speakers.
2. Confirm **Repair Audio Now** performs a successful reset.
3. Start the same Claude Code job in the Google Drive-backed project that normally triggers crackling.
4. Open **Settings → Diagnostics** and watch:
   - overload signals
   - abnormal stops
   - detections
   - repairs
5. If an audible crackle occurs with no counter increase, keep Fennec running and use the event log to document that miss. That means this Mac's failure is not publishing the native overload notification and a second detector will be needed.

## Security design

The privileged helper is deliberately narrow:

- It accepts only code-signed XPC clients matching the Fennec bundle identifier and signing Team ID.
- The app likewise verifies the helper's bundle identifier and Team ID.
- It exposes only two XPC calls: `ping` and `restartCoreAudio`.
- The repair method can run only the fixed command:

```text
/usr/bin/killall -TERM coreaudiod
```

- It cannot accept a path, command, arguments, script, or arbitrary shell input from the app.
- The helper enforces its own 20-second restart limit in addition to the app-level cooldown.

Manual repair falls back to a fixed `osascript` administrator prompt when the helper is not enabled.

## Local data

Fennec does not use the network and does not upload anything. Its event logs are stored at:

```text
~/Library/Application Support/Fennec/events.jsonl
```

The active log rotates at 5 MB to `events.previous.jsonl`.

## Troubleshooting helper setup

The built app must contain both files:

```text
Fennec.app/Contents/MacOS/FennecHelper
Fennec.app/Contents/Library/LaunchDaemons/com.ludicrousdesigns.Fennec.helper.plist
```

Inspect them with:

```zsh
find /Applications/Fennec.app/Contents -maxdepth 4 -type f -print
codesign -dv --verbose=4 /Applications/Fennec.app 2>&1
codesign -dv --verbose=4 /Applications/Fennec.app/Contents/MacOS/FennecHelper 2>&1
```

If macOS has retained broken Background Task Management state from repeated development builds, Apple's documented development reset is:

```zsh
sudo sfltool resetbtm
```

Reboot afterward. Do not use that command as normal maintenance; it resets Background Items state system-wide.

## Project layout

```text
Fennec/               SwiftUI app and Core Audio monitor
FennecHelper/         restricted privileged XPC daemon
Shared/                     XPC protocol, identifiers, signing checks
LaunchDaemons/              SMAppService launchd property list
Scripts/                    build and source-audit scripts
Docs/                       implementation and security notes
AGENTS.md                   agent operating guide, brand direction, task ledger
```

`AGENTS.md` is the entry point for AI agents working on this repository: repo location, build and
verification commands, load-bearing ground rules, known traps, the brand direction, and a shared
task ledger. Read it before making changes.


## Validation status

The project has passed property-list/project linting, Swift syntax parsing, pure detection/logging behavior tests, real-time C callback checks, and static helper-packaging checks. It has **not** been compiled or run with the macOS SDK in the source-generation environment. The first Xcode build on a Mac is therefore the final SDK, linker, signing, and runtime verification step. See `Docs/VALIDATION.md` for the exact checks and test protocol.

## Apple references

- Core Audio processor overload notification: https://developer.apple.com/documentation/coreaudio/kaudiodeviceprocessoroverload
- Abnormal I/O stop notification: https://developer.apple.com/documentation/coreaudio/kaudiodevicepropertyiostoppedabnormally
- Core Audio property listeners: https://developer.apple.com/documentation/coreaudio/audioobjectaddpropertylistenerblock(_:_:_:_:)
- Service Management: https://developer.apple.com/documentation/servicemanagement/smappservice
- XPC peer code-signing requirements: https://developer.apple.com/documentation/foundation/nsxpcconnection/setcodesigningrequirement(_:)
