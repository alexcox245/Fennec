# Changelog

Notable changes, newest first. Fennec has not had a tagged release yet; these
are the milestones on `main`.

## Unreleased

### Added

- **The red mark: crackle detection you can see.** From the first
  unsuppressed crackle signal until the repair settles, the menu-bar fennec
  turns red and wears sound waves between its ears: the user hearing the
  fault can see that Fennec hears it too and is waiting out the detection
  window before acting. The mark clears when the repair resolves or the
  window lapses quietly, and never shows while Fennec is paused.

- **A direct-download release pipeline.** `Scripts/release-developer-id.sh`
  archives with Developer ID, notarizes, staples, zips, and finishes with the
  exact Gatekeeper assessment a downloaded copy faces. Direct download is the
  distribution path on purpose: the Mac App Store requires App Sandbox, which
  the root helper's `SMAppService` registration rules out.

- **The helper registration heals itself.** An `SMAppService` registration
  binds to the bundle path and signature that made it, so a replaced build or
  a moved app left macOS reporting the helper *enabled* while launchd held a
  record it could no longer spawn, and Fennec's only moves were "Enabled,
  not responding" and a password prompt. Rebuilding the registration from the
  running bundle needs no password, so Fennec now does it itself: shortly
  after launch, before an automatic repair would be skipped over a silent
  helper, and before a manual repair falls back to the administrator prompt.
  Guarded by a pure, tested policy: only when macOS reports the daemon
  enabled (the user's approval is on record), never when the helper answers,
  at most once per ten minutes automatically. Every attempt lands in
  the event log. The Settings action for that state now says what it does:
  Rebuild, not Recheck.
- **A second detection witness: `coreaudiod`'s own overload log.** The
  processor-overload notification fires in the process whose IO cycle missed
  its deadline, so the property listener is deaf to the commonest form of the
  field fault: another client (verified live: an iOS Simulator daemon's
  silent audio context) overloading `coreaudiod` for hours while Fennec's
  counters stayed at zero. `SystemLogMonitor` polls the unified log for
  `HALS_OverloadMessage` entries, only while the output device is running IO,
  and feeds each event's true timestamp into the same detection engine,
  suppression windows, and safety gates as the listener path.
- **The stall advisory.** Playback stopping and starting on a starved Mac is
  not the crackle fault: coreaudiod logs clean IO stops, no overloads, and a
  restart would not help. When the stop/start pattern coincides with heavy
  load or memory pressure, Fennec posts one quiet banner naming the numbers
  and the actual likely cause, budgeted to one per half hour.
- **A live signal graph in the popover.** The last 30 seconds of overload
  signals plotted against the exact repair threshold, with playback stalls
  marked on the baseline. Scrolls continuously while visible; costs nothing
  while the popover is closed.
- **The activity ribbon.** A strip under the graph's time axis painted for
  every second audio was actually flowing, so a dropout shows as a visible
  break next to the stall triangle that explains it: the graph agreeing
  with your ears.
- **Onboarding that hands you the icon.** The setup checklist now leads with
  where Fennec lives: one click copies it to Applications and relaunches it
  there, and the first-run window offers the app icon as a real drag source;
  the Open at Login list in System Settings and the Applications folder both
  accept the drop.
- **First-run window.** Launching Fennec used to produce nothing at all. It
  now opens a consent record that states the complete privileged surface
  (both XPC methods *and* the administrator-prompt path), the cost of a repair
  in seconds, that there is no network code, and the two files it writes.
  Ends with a test repair you run on purpose while nothing is at stake.
- **A real menu-bar mark.** A template-rendered fennec silhouette with
  listening, repairing, paused, and attention states, replacing the stock
  `waveform` symbol.
- **Pause**, with durations that expire on their own and a menu-bar state that
  makes a running pause impossible to forget.
- **Repair verification and a stand-down breaker.** A repair is provisional
  until the fault has failed to return for a minute. Three that did not hold
  means restarting is not the cure, so Fennec stops for an hour and says so.
- **Activity window** (every repair grouped by day) and **days without
  incident**, an industrial safety sign that reads 0 on a repair day.
- **About panel** with the running helper's build and path read back over XPC,
  the three commands that verify a build, and **Uninstall Fennec…**.
- **Uninstaller**, because the root LaunchDaemon survives dragging the app to
  the Trash. Plus `UNINSTALL.md`, `SECURITY.md`, and `LICENSE`.
- **Setup checklist** driving every setup CTA from one model, so the popover,
  Settings, and first run cannot disagree.
- **259 unit tests** in a standalone XCTest bundle, and CI that runs them.

### Changed

- **The popover ends with the button.** "Repair Audio Now" moved from the
  top of the controls to the bottom of the content, at twice the height and
  with a 5 pt corner: last in the reading order, directly under the state
  that says whether pressing it is a good idea, and still above the
  Settings and Quit strip. The repair receipt and the days-without-incident
  sign came out with it; the running tally is still in the header and the
  footer, and every repair is still in the Activity window.

### Fixed

- **The microphone guard that never let a repair through.** `corespeechd`,
  Apple's wake-word daemon, opens a Core Audio input stream at login when
  "Hey Siri" or dictation is enabled and never closes it. Fennec asked Core
  Audio "is any process running input", got a permanent yes, and refused
  every automatic repair while telling the user a microphone was live: the
  orange privacy indicator was off, nothing was recording, and the guard was
  wrong every single time. Always-on speech daemons are now excluded by
  bundle identifier. Conferencing and continuity daemons still block, because
  those open input only when something real is happening.

- **The notification cannon.** The repair cooldown was keyed on the last
  *successful* repair and sat below the helper-reachable gate, so a fresh
  install with no helper had no cooldown at all and answered every signal
  burst with another sound-playing banner.
- **No wake suppression.** Core Audio renegotiates the whole output path on
  wake, unlock, and fast-user-switch. Without a quiet window, the first thing
  Fennec did when a laptop lid opened was restart the audio daemon.
- **The silent administrator prompt.** A transient XPC failure could raise a
  password dialog the user never asked for and Fennec never explained.
- **A confirmation dialog that dismissed itself.** An `.alert` presented from
  a `MenuBarExtra` scene attaches to a panel that closes the instant it
  resigns key, on the code path that restarts the audio system.
- **Windows with no menu bar.** ⌘W, ⌘Q, and ⌘, did nothing in an
  `LSUIElement` app. Activation policy now follows the windows.
- **Claiming "fixed" too early**, and looping forever on a machine where the
  restart is not the cure.
- **Escalating by sound**, through the audio subsystem that is, by
  hypothesis, broken. Failures now leave a persistent menu-bar mark.
- **Waking four times a second forever.** The drain backs off to 1 s and then
  2 s after a quiet minute and five, and snaps back on the first real signal.

### Changed

- **Balanced mode intervenes in 3 seconds, not 8.** The default detection
  window shrank: two crackle signals within three seconds now trigger the
  repair, so the fault is cut short while it is still starting. Conservative
  (3 in 12 s) and Immediate (first signal) are unchanged.
- **The repair notifications got terse, and they lead.** The moment the
  automatic path commits to a repair, before the safety scan that precedes
  the privileged call, Fennec posts "Crackle detected" / "Resetting
  speakers...", so the user who just heard the fault is told it is being
  handled in the same breath; the result banner, "Crackle resolved",
  replaces it in place with the restart time as its only body, typically
  about a second later. If the safety scan then vetoes (a live microphone, a
  protected call), the promise is retracted in place: "Crackle repair
  skipped" with the blocker, never budgeted away, with Repair Now offered.
  The cause detail stays on the menu receipt and in Activity, where it can
  be read at leisure. Failure and unrepaired-detection banners are
  unchanged. Both repair banners are delivered at the active interruption
  level: the success banner used to be passive, which on macOS means
  "notification list only, no banner", so the one notification the product
  exists to deliver was landing unseen. Still no sound on success.
- **The listening-state CPU cost dropped back under the one-percent budget.**
  Measured at 1.08% of a core while music played. The main cause was a leak:
  the log poll's cursor only advanced past *matching* entries, and a healthy
  machine has none, so every poll re-scanned an ever-growing window, and
  CPU per poll grew for as long as playback continued without a stop. The
  cursor now advances to query time (minus a logd flush margin), bounding
  every poll to one cadence of entries. Second find: the 1 s activity tick
  was re-resolving the output device and re-checking its properties on every
  tick: 1.2 ms of HAL round trips, not the 40 µs the comments claimed. The
  tick now reads through a cached device handle (~0.15 ms), invalidated by
  device-change events, read errors, a service restart, and a ten-tick
  refresh cadence, so a device switch cannot paint more than a beat of false
  gap in the activity ribbon.
- Automatic repair defaults **on** (inert until the helper is enabled).
- Settings lost its mascot banner: a `TabView` hoists its picker into the
  title bar, so the banner rendered between the tabs and their content.
- `audit-source.sh` now verifies `Docs/SOURCE_MANIFEST.sha256`.

## 2026-08-25 (`aa22cc6`)

First commit. Core Audio monitoring, the privileged helper, detection
thresholds, safety checks, and the menu-bar UI.
