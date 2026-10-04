# Signed updates

Fennec uses Sparkle 2.10.0, pinned in the Xcode project. Checks, downloads,
and installation are manual: the About panel starts a check, the user chooses
Download Update, and a second Install & Relaunch action is required. Automatic
checks, automatic downloads, automatic installation, and system profiling stay
disabled.

The appcast URL is `https://github.com/alexcox245/Fennec/releases/latest/download/appcast.xml`.
The feed and archives must be publicly readable. Sparkle verifies the appcast
and update archive with the Ed25519 public key in `Fennec/Info.plist`; the
matching private key stays in the maintainer's login Keychain.

For each release:

1. Set `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` to the same values in
   both the Fennec and FennecHelper targets. The release script checks the
   built app and helper versions and build numbers.
2. Review `Docs/RELEASE_NOTES_v1.0.md` for the first release, then copy it to
   `build/ReleaseNotes.md` (or set `FENNEC_RELEASE_NOTES` to that tracked
   file). Keep the notes specific and brief, without repair timings or
   internal framework names.
3. Run `zsh Scripts/release-developer-id.sh`. It audits the source, builds,
   signs, notarizes, staples, and verifies the app. It creates a signed,
   notarized `build/DeveloperID/Fennec.dmg` with an Applications shortcut
   for first installs, plus a ZIP for the in-app updater. Sparkle's
   `generate_appcast` signs an appcast in `build/updates/`, and
   `Scripts/verify-updates.swift` verifies the feed and every local archive
   against the exported app's public key. It also checks the update security
   settings and confirms the feed includes the exported build.
4. Review the appcast and release archive, create a GitHub release tagged
   `v<MARKETING_VERSION>`, and upload `Fennec.dmg`, `Fennec.zip`,
   `SHA256SUMS.txt`, every archive and delta referenced by the generated feed,
   and `build/updates/appcast.xml`. The feed must keep entries and
   assets for still-supported earlier versions. Keep `build/updates/` between
   releases so Sparkle can preserve the feed history and produce deltas.
   The generator applies the current release's download prefix to retained
   archives, so upload those archives to the new release too. Check each
   enclosure URL anonymously before publishing the release as latest.

The script prepares files but does not publish a release. Never commit the
private signing key or export it into a build artifact. If it is lost, rotate
the public key only through a planned, signed application update.

If `fennec-notary` is absent but the maintainer is already signed in to Xcode,
open the verified `.xcarchive` in Organizer, choose **Distribute App → Direct
Distribution**, and wait for **Ready to distribute**. Use **Export Notarized
App** on that same Organizer archive; opening an external archive imports a
copy, so the original path does not acquire the notarization metadata.
Validate the exported app with strict code-signature checks, `stapler validate`,
and `spctl --assess` before packaging it. Generate a fresh feed from the
stapled archive, and verify both the feed and enclosure Ed25519 signatures
against the exported app's `SUPublicEDKey`; an enclosure signature alone does
not establish that the feed is signed.

## Xcode command-line notarization with its existing account

The same Xcode account can submit an archive without a `notarytool` profile.
After the maintainer authorizes sending the compiled app to Apple, copy the
Developer ID export options and change only the destination to `upload`:

```bash
cp Scripts/ExportOptions-developer-id.plist /tmp/fennec-notarize.plist
/usr/libexec/PlistBuddy -c 'Set :destination upload' /tmp/fennec-notarize.plist
xcodebuild -exportArchive -archivePath build/Release-1.0.1/Fennec-1.0.1-b4.xcarchive -exportPath build/Release-1.0.1/Notarization -exportOptionsPlist /tmp/fennec-notarize.plist
xcodebuild -exportNotarizedApp -archivePath build/Release-1.0.1/Fennec-1.0.1-b4.xcarchive -exportPath build/Release-1.0.1/Notarized
```

Adjust the archive and output paths for the candidate. Upload success alone
is not acceptance; the notarized export must succeed, then pass strict
signature verification, `xcrun stapler validate`, and Gatekeeper assessment.
This route was verified with Xcode 26.6 for 1.0.1 build 4. Use that notarized
export for packaging, rather than an earlier signed draft. Sparkle feed
signing may separately prompt for access to its existing login Keychain key;
the maintainer completes that macOS prompt without sharing the password.

## Repair mode after an update

After relaunch, Fennec restores only the helper registration that existed
before Install & Relaunch. The selected repair mode stays unchanged while
an approved helper starts responding; a failed ping does not switch
Automatic to Ask me first. The normal launch recovery waits until update
restoration and its mode decision finish, and repairs remain gated during
that work. Registration restoration retries once if it races macOS teardown.

If macOS requires approval again or registration cannot be restored, Fennec
falls back to Ask me first. That mode does not start a background registration
rebuild. Choosing Ask me first during restoration is also preserved.
`HelperUpdateRestorationTests` exercises delayed pings, teardown/retry,
approval changes, bounded failure, and concurrent callers using fake helper
operations; it never contacts launchd or runs a repair.

## DMG installs and later updates

The first-install download can use
`https://github.com/alexcox245/Fennec/releases/latest/download/Fennec.dmg`.
The website buttons use that URL. Publish and verify each new DMG before
updating the latest release. Both downloads contain
the same app and the same signed updater. Users open the DMG, drag Fennec
into Applications, eject the image, and open Fennec from Applications.

Users installed from a DMG receive later updates inside **About Fennec →
Check for Updates**. They choose **Download Update**, then **Install &
Relaunch**. Sparkle downloads the ZIP, verifies it, and replaces the app;
users do not need another manual DMG install. Publishing a release makes it
available to checks; it does not silently install it on anyone's Mac.
Increment both targets' build numbers for every update, even when the
marketing version stays the same. ZIP names include both version and build
to avoid overwriting an earlier signed archive.
Use a new GitHub tag for each release. The default is `v<MARKETING_VERSION>`;
if that version was already published, set `FENNEC_RELEASE_TAG` to a new tag
such as `v1.0-build4` when running the release script. The feed uses that exact
tag in its archive URLs. Existing users compare build numbers, so a higher
build is offered even when the displayed marketing version is unchanged.

The website can stay on HostGator. Its button points directly to the release
asset; GitHub serves the files and the already-configured signed feed.
Moving the feed to HostGator would require a signed app update that changes
`SUFeedURL`; keep the existing feed working for users who have not upgraded.

For an app already exported and notarized through Organizer, create the DMG
without rebuilding or re-signing the app:

```bash
zsh Scripts/create-dmg.sh build/WebsiteRelease/Fennec.app build/WebsiteRelease/Fennec.dmg --notarize
xcrun swift Scripts/verify-updates.swift build/WebsiteRelease/Fennec.app build/WebsiteRelease/updates/appcast.xml
```

`--notarize` requires the `fennec-notary` Keychain profile (or
`FENNEC_NOTARY_PROFILE`). Omitting it produces a signed draft DMG containing
the notarized app, but reports that the disk image itself still needs
notarization. Do not publish that draft until `notarytool submit`,
`stapler staple`, `stapler validate`, and
`spctl --assess --type open --context context:primary-signature` succeed.
No packaging or verification command installs the app, registers a helper,
or exercises the audio repair path. Live updater installation and helper
restoration still require the supervised T-064 validation.

## Xcode-only first-install packaging

When Xcode Organizer has exported the signed, notarized, stapled app, an
unsigned DMG can carry that app without a second notarization submission:

```bash
zsh Scripts/create-dmg.sh build/WebsiteRelease/Fennec.app build/XcodeDMG/Fennec.dmg --xcode-export
```

This mode leaves the app's Developer ID signature and Apple ticket intact.
It does not sign the outer image. A signed disk image without its own
notarization must not be published. Apple Developer Technical Support
[documents this packaging option](https://developer.apple.com/forums/thread/741219),
while recommending signing and notarizing the outer image when available.
Verify the image checksum, mount it read-only, and verify the contained app
with strict signatures, `stapler validate`, and Gatekeeper before publishing.
Verify a quarantined extracted copy as well. Never remove quarantine or
disable Gatekeeper to make a release pass. Keep the signed ZIP update feed
and archives unchanged when adding a DMG of the same app build.
