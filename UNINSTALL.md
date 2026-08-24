# Removing Fennec

Dragging Fennec to the Trash is **not** enough. macOS keeps the root
LaunchDaemon registered in Background Task Management, keeps the login item,
and keeps the support folder. This page exists because that is the single most
damaging thing anyone can demonstrate about an app that asks for root, and it
takes thirty seconds to demonstrate.

## From inside the app

**Fennec → menu bar icon → More (ⓘ) → About & Uninstall…**, then **Uninstall
Fennec…**. Or from the menu bar when a Fennec window is open: **Fennec → About
Fennec** and the same button.

It unregisters the root helper, removes the login item, optionally deletes the
event log and repair history, forgets Fennec's settings, moves the app to the
Trash, and quits. If macOS refuses any step, Fennec names the step rather than
reporting a generic failure — because "uninstall failed" tells you nothing you
can act on.

## If Fennec is already in the Trash

The daemon outlives the app. These commands remove what is left:

```zsh
sudo launchctl bootout system/com.ludicrousdesigns.Fennec.helper
rm -rf ~/Library/Application\ Support/Fennec
defaults delete com.ludicrousdesigns.Fennec
```

Then check **System Settings → General → Login Items & Extensions** and remove
Fennec from **Allow in the Background** if it is still listed.

## Verifying it is gone

```zsh
# Should print nothing.
sudo launchctl list | grep -i fennec
launchctl list | grep -i fennec

# Should print nothing.
ls ~/Library/Application\ Support/Fennec 2>/dev/null

# Should print "does not exist".
defaults read com.ludicrousdesigns.Fennec 2>&1 | tail -1
```

## What Fennec never installed

For completeness, so you know what *not* to go looking for: Fennec installs no
kernel extension, no audio driver, no virtual audio device, no browser
extension, no login shell hook, and nothing in `/usr/local`. It has no
networking code, so there is no server-side account to close.
