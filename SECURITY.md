# Security

Fennec installs a `LaunchDaemon` that runs as root. That is a serious thing to
ask of anyone, so this document states the boundary precisely and tells you how
to report it when the boundary is wrong.

## Reporting a vulnerability

Open a private security advisory on the repository, or email the maintainer at
the address on the GitHub profile that owns it. Please include the macOS
version, the Fennec build number (**About Fennec** shows it), and what you did.

Expect an acknowledgement within **7 days** and an assessment within **30**.
Fennec is a single-maintainer project with a narrow, user-triggered update
surface; if that timeline is not acceptable for what you have found, say so in
the first message.

Please do not open a public issue for anything that would let a local process
escalate privilege.

## The privilege boundary

The helper exposes exactly two XPC methods, and neither takes a command, a
path, or an argument:

```
ping                → a status string
restartCoreAudio    → runs /usr/bin/killall -TERM coreaudiod
```

The executable and its arguments are fixed at compile time in
`FennecHelper/HelperService.swift`. There is no general execution API and
adding one is prohibited by the project's own ground rules (`AGENTS.md` §3).

Both ends verify the other. Release builds require a matching Apple Team ID
**and** bundle identifier via `NSXPCConnection.setCodeSigningRequirement` and
`NSXPCListener.setConnectionCodeSigningRequirement`. Identifier-only matching
exists only under `#if DEBUG`, so a locally ad-hoc-signed build can be
developed against; it is not present in a release binary.

The helper enforces its own 20-second floor between restarts, independently of
anything the app asks for, and confirms a new `coreaudiod` process actually
appeared before reporting success.

## Other privileged paths

The administrator-prompt repair path is also disclosed in the app. When the
helper is **not** installed, Fennec can run the same command through a standard
macOS administrator prompt (`osascript … with administrator privileges`). It
always asks first and always shows the literal command before macOS asks for a
password. It will never take this path on its own after an XPC failure. That
behaviour existed, and was removed, because an unexplained admin-password
dialog is the visual signature of credential phishing.

When you choose **Install & Relaunch**, Sparkle replaces Fennec with a signed
release. If your account cannot write to `/Applications`, macOS may ask for
administrator authorization. This path does not touch audio or change helper
permissions.

## What Fennec does not do

The monitor and repair path do not send observed audio signals or repair
records off the Mac. Sparkle contacts the signed GitHub release feed only when
the user chooses **Check for Updates**, and downloads only after the user
chooses **Download Update**. Automatic checks, automatic downloads, automatic
installation, system profiling, telemetry, and crash reporting are disabled.
Fennec keeps its event log and repair receipts under
`~/Library/Application Support/Fennec`; Sparkle keeps temporary update files
under `~/Library/Caches/com.ludicrousdesigns.Fennec/org.sparkle-project.Sparkle`.
No kernel extension, audio driver, or virtual device.

## Verifying a build

`Docs/SOURCE_MANIFEST.sha256` is a SHA-256 of every tracked source file.
`Scripts/audit-source.sh` fails if the tree does not match it.

```zsh
shasum -a 256 -c Docs/SOURCE_MANIFEST.sha256
codesign -dv --verbose=4 /Applications/Fennec.app
codesign -dv --verbose=4 /Applications/Fennec.app/Contents/MacOS/FennecHelper
```

## Removal

See `UNINSTALL.md`. The daemon survives dragging the app to the Trash; there is
an in-app uninstaller and a documented command-line fallback.
