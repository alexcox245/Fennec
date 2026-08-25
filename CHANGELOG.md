# Changelog

Notable changes, newest first. Fennec has not had a tagged release yet; these
are the milestones on `main`.

## Unreleased

### Added

- **Onboarding that grants what it can and asks for what it cannot.** Fennec
  now registers its own login item and raises the notification prompt itself
  the first time it launches, leaving the administrator password as the single
  thing a person is asked for. The rule is one sentence — Fennec grants what
  costs the user nothing and asks for what costs them something — and root is
  never on the granting side of it. Each permission row names who granted it,
  and the login item carries its own off switch in the same line, so a default
  set for you is never a default you have to hunt for. Applied once per
  install and tracked separately from first-run completion, so reopening the
  window can never switch back on something you switched off.
- **First-run window.** Launching Fennec used to produce nothing at all. It
  now opens a consent record that reads in one order: what Fennec does, what
  that costs this Mac — the complete privileged surface, both XPC methods
  *and* the administrator-prompt path, the cost of a repair in seconds, that
  there is no network code, the two files it writes — and only then what it
  needs from you. Ends with a test repair you run on purpose while nothing is
  at stake.
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
