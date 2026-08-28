# Fennec roadmap

Written 2026-08-25, after the two requested features (T-013 Catch & Fix, T-014 Always On) shipped.

Every item below is one commit. Ordered by execution, not by how interesting it is.

**Status: all ten items shipped on 2026-08-25.** Commit SHAs are in the task
ledger (`AGENTS.md` §8, rows T-015 through T-023). R10's adversarial review
found 33 verified defects (including two blockers in features written the
same night), and they are fixed in `1825767`.

---

## The thesis

Fennec is a root-privileged background process that starts at login and acts on the user's audio
without asking. Everything it does is one Terminal command (`sudo killall coreaudiod`) that its
target user already knows. So the product is not the command. The product is **the judgement around
the command**: noticing at 2am that the fault started, refusing while a microphone is live,
refusing again when the last restart did not help, and writing down what it saw.

That means the roadmap is not a feature list. It is, in order:

1. **Stop being wrong.** A background process that misfires is worse than no process.
2. **Be operable.** An app with no window, no menu, and a confirmation dialog that dismisses itself
   is not usable, however good the engine is.
3. **Be legible.** Say what happened, in numbers, and never claim more than was verified.
4. **Be removable.** An app that asks for root and cannot be cleanly taken back has no standing to
   talk about restraint.
5. **Then, and only then, be liked.**

---

## What this roadmap is reacting to

Four independent reviews (an audio engineer, a macOS/HIG specialist, a product manager, and an
adversarial reviewer) plus three judges and a completeness critic. They converged on something
uncomfortable: the highest-value work is not new features, it is **defects in what already ships**.

Confirmed against the source, not asserted:

| # | Defect | Where |
|---|---|---|
| D1 | Unrepaired-detection notifications have no rate limit, and the cooldown is keyed on the last *successful* repair and sits **above** the helper gate, so a fresh install with no helper has no cooldown at all and posts a sound-playing two-button banner on every detection | `AppModel.respondToDetection` |
| D2 | `.alert` presented from inside a `MenuBarExtra(.window)` scene attaches to a panel that dismisses the moment it resigns key: the "Audio is in use" confirmation is unusable | `MenuView`, `SettingsView` |
| D3 | No wake / unlock / launch suppression. Opening a laptop lid renegotiates the audio graph; the first thing Fennec does is restart the audio daemon | `AppModel.handle` |
| D4 | On an XPC hiccup the app silently falls back to an `osascript … with administrator privileges` prompt. An unexplained admin-password dialog is the visual signature of credential phishing | `AppModel.performRepair` |
| D5 | "Fennec fixed your audio" claims more than was verified. The only established fact is that a new `coreaudiod` PID exists. On a fault a restart cannot cure, Fennec restarts forever | `RepairCopy` |
| D6 | The root LaunchDaemon survives dragging Fennec to the Trash. The only unregister path lives inside the app that no longer exists | no uninstall path anywhere |
| D7 | Failure escalates by playing a sound (through the audio subsystem that is, by hypothesis, broken) and never through a persistent visual state | `NotificationController` |
| D8 | A repair is system-wide, but the safety checks only see the current user's processes. On a Mac with a second account logged in, Fennec can cut someone else's call and report the machine was clear | `RecoverySafetyChecker` |
| D9 | `SMAppService` registration binds to the bundle path. Enabling the helper from `~/Downloads` and later moving the app silently produces "Enabled, not responding" with no explanation | no location guard |

---

## The plan

### R1: Stop being hostile out of the box · **P0**

Fixes D1, D3, D4, D8. Nothing here is visible when it works, which is the point.

- **Notification budget.** At most one unrepaired-detection banner per 10 minutes, coalesced onto a
  stable request identifier so a burst replaces rather than stacks. Repair results are never
  budgeted; they are rare by construction.
- **Move the cooldown below the helper gate** and key it on the last repair *attempt*, not the last
  success, so a machine that has never successfully repaired still rate-limits itself.
- **Quiet windows after wake, unlock, and launch.** `suppressSignalsUntil` already exists and covers
  service restart (12 s) and device change (2 s). Four `NSWorkspace` subscriptions extend it to the
  three events that renegotiate the whole graph.
- **Console-session gate.** Automatic repair only from the session at the keyboard.
- **Never fall back silently.** An enabled helper that fails to answer surfaces the failure. The
  administrator prompt happens only when the user asks for it, having been told what it will run.

### R2: Windows that behave like a Mac app · **P0**

Fixes D2. Prerequisite for R3, R6, R7.

- `WindowPresenter`: accessory while only the popover shows, regular for exactly as long as a real
  window is open, so ⌘W, ⌘Q, ⌘, and the Dock icon all work while there is something to type at.
- A real main menu, and `applicationShouldHandleReopen` so double-clicking Fennec again does
  something instead of nothing.
- Replace the broken modal alert with an inline confirmation card in the popover.

### R3: First run, a consent record, not a welcome tour · **P0**

Fixes D9. The single biggest reason someone deletes this app in ten seconds.

One window, opened on first launch and on every launch until setup completes. It states the
**complete** privilege surface (both XPC methods by name *and* the administrator-prompt path), the
literal cost of a repair, that there is no network code, and the two files it writes. It runs the
existing `SetupChecklist`, so it cannot disagree with the popover.

Two things it does that a tour would not:

- **Test Repair.** A real repair, on purpose, while nothing is at stake, reporting the measured
  cost. No test tone: nobody knows the user's monitor gain, and Fennec is not going to be the app
  that puts a sine wave through someone's open-back headphones.
- **"Not in the menu bar?"**: the three real causes (a menu-bar manager hiding it, notch overflow,
  a ⌘-drag removal) and what to do about each.

Plus the location guard: if Fennec is not in `/Applications`, say so and disable Enable Helper,
because registering from `~/Downloads` produces the worst failure state the app has.

### R4: Hold · **P1**

The manual override. Fennec's safety checks can only see what Core Audio tells them; a person
tracking a take knows things Core Audio does not.

A persisted end date, one early return, a distinct menu-bar mark, and a forced expiry so it can
never be silently left on.

### R5: Stop claiming "fixed" · **P1**

Fixes D5, D7.

- A repair is **provisional** until the fault fails to return. Aviator gold, reserved in the brand
  for a repair that worked, is not spent when the helper reports a new PID. It is spent 60 seconds
  later, if the machine is still quiet.
- **Circuit breaker.** Three repairs that did not hold means the restart is not the cure. Fennec
  stands down for an hour and says the real numbers instead of trying a fourth time.
- **Escalate visibly, not audibly.** A failure switches the menu-bar mark to its attention state and
  leaves it there until the user looks. A sound played through a broken audio system is not an
  escalation channel, and for a Deaf user it never was one.

### R6: Take it back · **P1**

Fixes D6. For an app whose whole pitch is restraint, being uninstallable is not a polish item.

- An About window that enumerates the privilege surface, shows the *running* helper's version and
  path (appended to the existing `ping` reply: no new XPC method, boundary untouched), and answers
  the question every reader asks first: why is this not a shell alias?
- **Uninstall Fennec…**: unregister the daemon, disable the login item, optionally delete the
  support directory, move the bundle to the Trash, quit. Report honestly, by step, if macOS refuses.
- `UNINSTALL.md` for the case where the app is already gone.

### R7: Activity, and the delighter · **P1**

- One window listing repair receipts grouped by day, with running totals. Deliberately not a
  sortable table with filters and CSV export: that is a window people open once, on install day, to
  find it empty.
- **The delighter: "Days Without Incident."** An industrial safety sign, ink on sand, in the
  popover. It changes only at midnight. On a day Fennec had to repair something it reads `0` with no
  softening, no apology, and no animation, which is the entire joke and the entire brand. Read
  honestly from the boot time and the repair log.

### R8: What it costs while doing nothing · **P2**

99.99% of Fennec's life is idle, and it currently wakes four times a second to confirm that. The
drain steps back to 1 s then 2 s after a quiet minute and snaps to 250 ms on the first real signal.
A product whose proudest claim is stillness should not be the loudest thing in Activity Monitor.

### R9: The documents a root-privileged utility is judged by · **P2**

`LICENSE`, `SECURITY.md`, `CHANGELOG.md`, a README that covers Gatekeeper, install location,
uninstall, and (the strongest thing this repo has and mentions nowhere a user will look) how to
verify that the source you are reading is the source that built the binary.

### R10: Adversarial review · **P1**

Information architecture, user experience, and macOS engineering, reviewed against the shipped tree
by reviewers told to find what is wrong. Then fix what they find.

---

## Deliberately cut

Recorded so they stay cut, and so the reasoning survives.

| Idea | Why not |
|---|---|
| A verification **tone** through the user's output device | Nobody knows their monitor gain. A sine wave through open-back headphones at whatever level the last session left them is a hearing risk and a tacky one. The Test Repair in R3 proves the same chain with no audio. |
| Animated or coloured menu-bar mark (ears that turn; gold for three seconds after a repair) | A non-template status item is the number-one tell of a non-native utility and breaks light/dark/highlight inversion. And the brand is explicit: nothing pulses for attention, the desert does not animate. |
| Per-device profiles keyed by device UID | Aggregate and USB UIDs churn, the list accumulates ghosts, and it multiplies the state space of the two components whose correctness matters most. |
| A curated 20-app DAW allowlist shipped as law | Wrong the day it ships, unbounded maintenance, and it gives false confidence: "it's a DAW, so I'm covered." |
| Device and sample-rate restore after the restart | The best idea nobody else had, and still wrong for now: it races macOS's own device-restore logic, needs Core Audio setters in a file that already carries unsafe-pointer warnings, and cannot be validated without a physical USB DAC. Deferred, not dismissed; logged in the ledger. |
| A persistence gate before acting | Sound instinct, wrong trade: it adds up to four more seconds of audible crackle to avoid a repair that costs one. R5's verification window gets the same protection after the fact, for free. |
| Full repair-history window with sortable table, filters, CSV export | A window most people open once and find empty. R7 ships the useful tenth of it. |
| Swift 6 concurrency migration | Real debt, zero user-visible surface, and it means touching the XPC lifecycle and the Core Audio property reads, the two files where a mistake is least recoverable. Stays as T-007 / T-008. |
| Localisation restructure | The completeness critic is right that every night of new copy welds the app harder to English, and right that unit-testing exact English strings makes the eventual pass a test rewrite. It is also a night of its own. Logged as a ledger item with the reasoning rather than half-done. |
| Sparkle, auto-update, crash reporting | All three need the network. The constraint is absolute, and the no-network claim is only worth making if it stays true. |
