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
   signs, notarizes, staples, verifies, and zips the app, then uses Sparkle's
   `generate_appcast` to sign an appcast in `build/updates/`.
4. Review the appcast and release archive, create a GitHub release tagged
   `v<MARKETING_VERSION>`, and upload the new app archive, any new delta
   archives, and `build/updates/appcast.xml`. The feed must keep entries and
   assets for still-supported earlier versions. Keep `build/updates/` between
   releases so Sparkle can preserve the feed history and produce deltas.

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

The website's Download buttons point to the latest public GitHub release.
Publish both `Fennec.zip` for visitors and the versioned ZIP referenced by the
signed feed, with identical contents and a `SHA256SUMS.txt` file. Verify the
anonymous download after publication.
