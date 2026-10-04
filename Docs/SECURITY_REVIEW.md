# Fennec security review

Reviewed on 2026-10-04 against source commit `48913f25a408a39fea6712fa5bd87f78463ce219`, using Xcode 26.6 on the owner's Mac. This review examines how a local malicious process or a compromised update host could cause unwanted repairs, interfere with files, or cross the root helper boundary. It documents findings and proposed mitigations; application behavior has not been changed.

The highest priority is authenticating the source of log events before they can cause an automatic repair. The monitor currently trusts the name `coreaudiod`, which another user process can adopt. The helper also accepts genuine development builds that permit debugger access. These are concrete weaknesses around a narrowly privileged action. This review did not demonstrate arbitrary root code execution or a remote compromise.

## Scope and evidence

The review covered the app and helper sources, XPC requirements, repair and update orchestration, process execution, local persistence, installation and removal, signing configuration, release scripts, CI, and the pinned Sparkle dependency. The attacker models are an ordinary process running as the logged-in user, another local account, and a compromised release host. Possession of the maintainer's signing keys is considered separately because it substantially changes what an attacker can do.

Runtime probes were isolated from the real app. They used temporary files, static signature checks, synthetic process snapshots, and a test executable named `coreaudiod` emitting a unique harmless log message. The test message contained none of Fennec's fault markers. No helper was installed, registered, contacted, or removed; no audio restart, debugger injection, update installation, or microphone recording was performed. Exploit chains that require those actions remain unverified.

## Findings and priorities

Priorities below follow the project ledger. Severity describes demonstrated impact with the stated prerequisites, without assigning a speculative CVSS score.

| Finding | Priority | Severity | Evidence | Mitigation task |
|---|---|---|---|---|
| Another process can impersonate the log witness | P1 | Moderate, local audio disruption | Name filter reproduced; repair chain inferred from source | T-091 |
| Release helper requirements accept debuggable clients | P1 | Moderate, conditional misuse of a root action | Signature acceptance reproduced; injection not exercised | T-092 |
| Process names bypass microphone protection | P1 | Moderate, protection bypass | Pure decision reproduced with an unrelated bundle ID | T-093 |
| Log appends follow symlinks and history loads have no input cap | P2 | Low, local integrity and availability | Symlink append reproduced; history limit gap established from source | T-094 |
| Release check does not verify the feed signature | P1 | Low, release assurance gap | Unsigned fixture passes the check | T-095 |
| Helper trusts process names and has unbounded subprocess waits | P2 | Low, conditional false success or stalled repair | Name lookup reproduced; stall scenarios not exercised | T-096 |

### Another process can impersonate the log witness

[SystemLogMonitor.swift](../Fennec/SystemLogMonitor.swift#L199) selects entries with `process == 'coreaudiod'` and a matching message. It does not restrict the executable path or verify that an entry came from Apple's daemon. Two matching overload events can feed the same detection pipeline as real events.

An executable in the review's build directory, running as UID 502, emitted a harmless unique log message. `OSLogStore` returned that message through a predicate using the same process-name condition as Fennec. Adding `processImagePath == '/usr/sbin/coreaudiod'` rejected it. The log predicate's ability to trust a forged name is therefore reproduced. Real overload messages were deliberately not emitted, so the complete automatic repair chain was not executed.

An attacker could use this condition to supply fabricated detections. For an automatic reset, Fennec must already have Automatic mode and an answering approved helper, audio must be running or recently running, and its session, safety, cooldown, and governor checks must allow repair. Ask me first would instead expose the user to false repair requests. The existing cooldown and governor limit frequency; they do not establish whether the input is genuine.

**Mitigation:** constrain the query to the verified system executable image path, and validate any supported OS versions where that path differs. Use trusted process metadata where available; a subsystem or bundle name by itself can also be copied. Preserve correct handling of historical log entries across daemon replacement, rather than validating an old entry solely against a live PID that may have been reused. If provenance cannot be established, do not use that entry to authorize an automatic repair. Test fabricated entries against an inert repair sink and verify that real daemon entries still reach detection. The path filter was tested only against the impostor, so compatibility with actual overload logs still needs supervised validation.

### Release helper requirements accept debuggable clients

[CodeSigningRequirement.swift](../Shared/CodeSigningRequirement.swift#L22) requires an Apple anchor, the bundle identifier, and the current executable's Team ID. A genuine development build of Fennec satisfies all three. Its debugger entitlement is not excluded. Restricting identifier-only matching to `DEBUG` does not prevent a team-signed Debug client from satisfying a Release helper's stronger expression.

Static Security framework checks produced these results with the production requirement for team `249X253HS3`:

| Local artifact | `get-task-allow` | Current requirement | Requirement additionally rejecting that entitlement |
|---|---|---|---|
| Ordinary Debug build | true | Accepted | Rejected |
| Ordinary Release build signed with Apple Development | true | Accepted | Rejected |
| Existing Developer ID export | absent | Accepted | Accepted |

The tested additional clause was `and ! entitlement["com.apple.security.get-task-allow"] exists`. It parsed successfully and rejected the development artifacts with `errSecCSReqFailed` (`-67050`). This is a candidate policy, not an applied fix. It also rejects an explicitly present false entitlement; choose and test the intended production policy before shipping.

A local attacker who obtains a genuine development artifact and can gain code execution inside it may inherit its access to the helper. The exposed root capability is the fixed audio reset, not arbitrary command execution. No debugger attachment or live XPC bypass was tested. Apple describes the runtime injection risk of this entitlement in its [notarization guidance](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

**Mitigation:** have production peers reject debugger and injection exceptions in addition to preserving Team ID and bundle ID checks. Keep development interoperability explicitly confined to a development policy, preferably a separate development service identity. Verify the entitlements and hardened runtime of both exported app and helper in the release gate. Ship the Developer ID export, not an ordinary Release build. Do not rely on the text of the unbuilt entitlements plist: Xcode injects signing entitlements during a normal local build.

### Process names bypass microphone protection

[RecoverySafetyChecker.swift](../Fennec/RecoverySafetyChecker.swift#L136) ignores a process when either its bundle identifier is in the always-on set or its name is in the daemon name set. This name check applies even when the supplied bundle identifier contradicts the claimed identity.

The pure production decision returned `canAutoRepair == true` for each synthetic process named `coreaudiod`, `corespeechd`, and `corespeechd_system`, with an active input stream and bundle ID `com.example.untrusted`. This establishes the decision bypass. A real impostor opening a microphone was not tested.

The purpose of exempting the real speech daemon is justified by the existing field evidence. The issue is granting the exemption to an unrelated process. An attacker controlling a recording process could hide that process from Fennec's guard. Other genuine recording processes would still block, so this does not bypass every possible blocker. Microphone access itself still depends on macOS permissions.

**Mitigation:** authenticate exempt daemons using their Apple signature and expected executable path, associated with the live process identity. Use names for display. An unrelated or unverifiable process that reports active input should block automatic repair. Add cases for a conflicting bundle ID, a copied Apple bundle ID without Apple signing, an absent bundle ID, and PID reuse, while retaining the measured exemption for the real daemon. Identity resolution must happen outside the real-time callback.

### Local storage follows symlinks and lacks read limits

[EventLogger.swift](../Fennec/EventLogger.swift#L98) opens an existing path with `FileHandle(forWritingTo:)`. A temporary `events.jsonl` symlink to an unrelated temporary file caused the real logger to append its JSON record to that target. This is a confirmed append through a redirected path. It runs with the app's user privileges and was not a root write. The attacker must be able to modify the support directory; for ordinary files already writable by the same user, this offers little additional authority. It can still corrupt unrelated files or compromise the reliability of diagnostic records.

Directory and file modes rely on the inherited umask. A newly created probe directory was mode `0755`; actual cross-account readability also depends on its parent directories and ACLs, which were not assessed. [RepairHistoryStore.swift](../Fennec/RepairHistoryStore.swift#L225) reads and decodes the entire file before sorting it. Its 500-record cap applies when adding a record, not when loading an externally enlarged history. A local writer can therefore impose unbounded allocation and sorting at startup. No large-file exhaustion experiment was run.

**Mitigation:** create the support directory with mode `0700` and files with mode `0600`. Open log files relative to a validated directory descriptor, reject symlinks with `O_NOFOLLOW`, and check type and ownership with `fstat`. A preceding `fileExists` or `lstat` check alone leaves a replacement race. Use equivalent constraints for rotation and history writes. Bound history bytes, decoded record count, and individual strings before expensive processing. Test these operations in temporary directories. Local preferences and receipts remain user-controlled data; permissions do not make them a trustworthy authorization record against another process with the same UID.

### Release check does not verify the feed signature

[release-developer-id.sh](../Scripts/release-developer-id.sh#L146) accepts any generated XML containing `sparkle:edSignature`. That attribute normally occurs on the update archive's enclosure. It does not prove that the enclosing feed itself was signed, or that either signature verifies with Fennec's public key. An unsigned fixture containing an enclosure with a dummy signature passed the exact grep check.

The existing local draft feed has Sparkle's trailing feed-signature comment, so this review does not claim that it is unsigned. The gap is the release gate's assurance. Runtime settings enable `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`, so an invalid archive should still be rejected by Sparkle. A missing feed signature normally breaks updates rather than immediately granting code execution. Sparkle also documents a default 20-day feed-validation failure fallback; setting `SUSignedFeedFailureExpirationInterval` to zero disables that expiry. Archive validation remains separate. See [Sparkle security settings](https://sparkle-project.org/documentation/customization/).

**Mitigation:** cryptographically verify the generated feed and each enclosure against the public key in the exported app, rather than checking for a string. Assert that the built app retains both security settings. Explicitly choose the feed failure expiry policy and document the key recovery tradeoff. In an isolated updater harness, test tampered feed bytes, tampered archives, wrong keys, and the explicit check/download/install stages. Existing T-064 tracks the supervised installer and helper lifecycle; the passing pure unit suite does not exercise that lifecycle.

### Helper process identity and execution bounds

[HelperService.swift](../FennecHelper/HelperService.swift#L96) identifies a replacement solely with `/usr/bin/pgrep -x coreaudiod`. An independent query included the harmless user-owned impostor's PID. A new same-name process can therefore enter the set used to establish success. The fixed `killall` also selects by name across owners. The demonstrated consequence is weak target identification; false repair success was not induced because no signal was sent.

The [subprocess runner](../FennecHelper/HelperService.swift#L122) waits for exit before draining either pipe and has no execution timeout. Large output can block a child on a full pipe while the parent waits. The app's XPC timeout invalidates its connection, but does not terminate helper work. These are source-established availability risks; resource flooding was not performed. The helper's 20-second limiter uses wall time and resets with the helper process, so it is not a durable authorization boundary.

**Mitigation:** identify the actual system daemon using executable path, owner, and Apple signing, and confirm replacement with that identity rather than a name alone. Keep the action fixed and update the literal privilege disclosure if the executed command changes. Drain bounded output concurrently, impose a subprocess deadline, serialize repair work, and use a monotonic clock for the interval. Define whether the helper may accept a genuine client from a background login session: currently the app owns the console-session gate, while the helper checks its own root UID but not the requesting user's session. Any new helper-side session gate needs fast-user-switch validation.

## Protections that were present

The root XPC interface has exactly two methods with no caller-supplied command, path, or argument list. Both sides set Apple-supported code-signing requirements before activating communication. Release fails when its own Team ID is unavailable; the weaker identifier-only fallback is compiled only for Debug. See Apple's [listener requirement documentation](https://developer.apple.com/documentation/foundation/nsxpclistener/setconnectioncodesigningrequirement(_:)).

The app and helper enable the hardened runtime. The source entitlement file requests no runtime exceptions. Shell interpolation in the administrator repair contains a compile-time fixed command; device names and log messages are not passed into it. Local event output is JSON encoded, and update release notes are presented as plain text. The reviewed app has no general network server or audio upload path. Uninstallation accounts for registered helpers awaiting approval, login items, local support files, update cache, and preferences.

Sparkle is pinned to 2.10.0 at revision `eef1a539a373c1f1a320624b1130fc5de7b2e100`. The reviewed upstream advisories report fixes in 2.9.2, 2.9.5, and 2.9.6, below that pin: [installer metadata spoofing](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-g3hp-f6mg-559v), [delta overwrite](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-gmj2-gq3j-vqmj), [validated path mismatch](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-3x7w-j75x-ppq5), and [root cache traversal](https://github.com/sparkle-project/Sparkle/security/advisories/GHSA-4v99-qgq9-6pxp). These specific advisories do not establish that the pinned version is affected. Continue reviewing upstream advisories before each release; pinning a version is not a permanent vulnerability assessment.

## Validation and remaining limits

The standalone XCTest suite passed **298 tests with zero failures**. The Fennec and FennecHelper Debug and Release builds all succeeded. No application source was modified and the incremental build matrix emitted no compiler warnings. The isolated safety harness emitted the two already catalogued CoreAudioProperty pointer warnings, tracked in T-007. Gitleaks scanned **95 local commits** with redaction enabled and reported **no leaks**; this is a pattern scan, not proof that every possible credential is absent.

Probe sources and logs are retained locally under `build/SecurityReview/`, which is ignored by Git. Signature checks needed access to macOS trust services outside the filesystem sandbox. Initial sandboxed signature results were unusable and were excluded from the findings. The source audit and manifest verification are recorded in the completion ledger.

Still unverified: actual exploitation through the installed root helper, debugger injection, cross-account and fast-user-switch behavior, authentic overload acceptance under a hardened log predicate, signed updater installation and cancellation, and current final-candidate notarization. Those require a supervised test build and explicit approval for helper or audio actions under AGENTS.md rule 4. The existing notarized export used in the signature comparison is an older artifact, not approval of the current release candidate.

Implement T-091, T-092, and T-093 first, then validate them using inert repair sinks. Complete T-095 and existing T-061/T-064 before relying on the public release and update channel. T-094 and T-096 cover the remaining local storage and helper hardening. The four existing pointer and Sendable warnings retain their existing T-007/T-008 tasks; this review has not established an exploitable memory corruption chain from them.
