# Fennec architecture

## Detection path

1. `CoreAudioMonitor` attaches classic Core Audio property listeners to the system object and the current default output device.
2. Core Audio may invoke the callback from a real-time I/O context.
3. `RTSignalCounters.c` performs only relaxed atomic increments.
4. A private serial queue drains the counters every 250 ms.
5. `DetectionEngine` applies a time-window threshold.
6. `AppModel` checks output transport, cooldown, active microphone input, protected audio applications, and helper reachability.
7. The app asks the helper to restart Core Audio.
8. The app waits for launchd to relaunch `coreaudiod`, then rebuilds all listeners. A spontaneous Core Audio service restart also triggers a full listener rebuild because Apple documents that service-reset state must be re-established.

## Why the callback is implemented in C

Swift closures, logging, object allocation, locks, XPC, process execution, and main-thread dispatch are not appropriate inside a potentially real-time audio callback. The C callback touches fixed preallocated storage only. All higher-level work occurs after a timer drains the counters on a normal queue.

## Privilege boundary

The app itself runs as the signed-in user. The root helper is installed and managed through `SMAppService.daemon(plistName:)` and is demand-launched through its Mach service.

Both sides enforce peer code-signing requirements. Release builds require the same Apple Team ID plus the expected bundle identifier. Identifier-only matching is limited to `DEBUG` to make local ad-hoc development possible.

The XPC protocol has no general execution API. Its repair method invokes fixed absolute executables with fixed arguments and verifies that `coreaudiod` was relaunched.

## Detection trade-off

`kAudioDeviceProcessorOverload` indicates that Core Audio missed a processing deadline. It is a strong causal signal for an audio xrun but is not an acoustic classifier. Balanced mode requires two notifications within eight seconds to reduce false recovery. Immediate mode is appropriate only after confirming that one overload correlates with the user's audible failure.

## Failure behavior

- If the helper is absent, automatic repair is disabled and manual repair uses an administrator prompt.
- If safety checks cannot determine whether recording is active, automatic repair is blocked.
- If Bluetooth is selected and Bluetooth skipping is enabled, no automatic reset occurs.
- If the helper does not answer, the app times out rather than hanging.
- After repair, signals are suppressed briefly while the audio graph reconnects.

## Transient-change suppression

Normal output switches, wake transitions, and sample-rate renegotiation can emit overload or abnormal-stop notifications even when no persistent crackle exists. Fennec resets its detection window and applies a two-second grace period around those events. A Core Audio service restart applies a 12-second suppression window because the service reset has already repaired the graph.
