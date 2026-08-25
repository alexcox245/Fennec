# Changelog

Notable changes, newest first. Fennec has not had a tagged release yet; these
are the milestones on `main`.

## Unreleased

### Added

- **A second detection witness: `coreaudiod`'s own overload log.** The
  processor-overload notification fires in the process whose IO cycle missed
  its deadline, so the property listener is deaf to the commonest form of the
  field fault — another client (verified live: an iOS Simulator daemon's
  silent audio context) overloading `coreaudiod` for hours while Fennec's
  counters stayed at zero. `SystemLogMonitor` polls the unified log for
  `HALS_OverloadMessage` entries, only while the output device is running IO,
  and feeds each event's true timestamp into the same detection engine,
  suppression windows, and safety gates as the listener path.
- **The stall advisory.** Playback stopping and starting on a starved Mac is
  not the crackle fault — coreaudiod logs clean IO stops, no overloads, and a
  restart would not help. When the stop/start pattern coincides with heavy
  load or memory pressure, Fennec posts one quiet banner naming the numbers
  and the actual likely cause, budgeted to one per half hour.
- **A live signal graph in the popover.** The last 30 seconds of overload
  signals plotted against the exact repair threshold, with playback stalls
  marked on the baseline. Scrolls continuously while visible; costs nothing
  while the popover is closed.
- **First-run window.** Launching Fennec used to produce nothing at all. It
  now opens a consent record that states the complete privileged surface —
  both XPC methods *and* the administrator-prompt path — the cost of a repair
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
- **Activity window** — every repair grouped by day — and **days without
  incident**, an industrial safety sign that reads 0 on a repair day.
- **About panel** with the running helper's build and path read back over XPC,
  the three commands that verify a build, and **Uninstall Fennec…**.
- **Uninstaller**, because the root LaunchDaemon survives dragging the app to
  the Trash. Plus `UNINSTALL.md`, `SECURITY.md`, and `LICENSE`.
- **Setup checklist** driving every setup CTA from one model, so the popover,
  Settings, and first run cannot disagree.
- **187 unit tests** in a standalone XCTest bundle, and CI that runs them.

### Fixed

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
  resigns key — on the code path that restarts the audio system.
- **Windows with no menu bar.** ⌘W, ⌘Q, and ⌘, did nothing in an
  `LSUIElement` app. Activation policy now follows the windows.
- **Claiming "fixed" too early**, and looping forever on a machine where the
  restart is not the cure.
- **Escalating by sound** — through the audio subsystem that is, by
  hypothesis, broken. Failures now leave a persistent menu-bar mark.
- **Waking four times a second forever.** The drain backs off to 1 s and then
  2 s after a quiet minute and five, and snaps back on the first real signal.

### Changed

- Automatic repair defaults **on** (inert until the helper is enabled).
- Settings lost its mascot banner: a `TabView` hoists its picker into the
  title bar, so the banner rendered between the tabs and their content.
- `audit-source.sh` now verifies `Docs/SOURCE_MANIFEST.sha256`.

## 2026-08-25 — `aa22cc6`

First commit. Core Audio monitoring, the privileged helper, detection
thresholds, safety checks, and the menu-bar UI.
