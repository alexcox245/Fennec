import Foundation

/// Exactly what Fennec will do to a Mac, stated once, in one place.
///
/// This is the text behind the first-run window and the About panel, and it
/// exists as data rather than as strings inside two views for one reason: a
/// disclosure that can drift from the behaviour is worse than none, because
/// it converts an honest gap into a false claim.
///
/// The specific trap it was written to avoid: every reasonable version of an
/// About panel enumerates the XPC surface — `ping` and `restartCoreAudio` —
/// and stops there. That is a true sentence engineered to mislead, because
/// there is a **second** privileged path. When the helper is not enabled,
/// Fennec asks macOS for an administrator password and runs the same command
/// through `osascript`. A user who reads "exactly two methods" and then sees
/// a password dialog has been told something false by omission.
enum PrivilegeDisclosure {

    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let detail: String
        /// Rendered monospaced: real data, per AGENTS.md §7.
        let code: String?
    }

    /// The one-paragraph answer to the question every reader asks first.
    static let whyNotAShellAlias = """
        Restarting Core Audio is one command, and you already know it. Fennec's job is the parts \
        around it: noticing at 2am that the fault started, refusing while your microphone is live, \
        refusing again when the last restart did not help, and writing down what it saw so you can \
        tell whether the problem is Core Audio or your hardware.
        """

    /// Every way Fennec can act with privilege. All of them.
    static var privilegedActions: [Item] {
        [
            Item(
                id: "helper",
                title: "A root helper with two calls",
                detail: "Fennec installs a LaunchDaemon that runs as root and answers exactly two "
                    + "requests: one that reports it is alive, and one that restarts Core Audio. "
                    + "It cannot be given a command, a path, or an argument.",
                code: "ping · restartCoreAudio"
            ),
            Item(
                id: "command",
                title: "One command, fixed at compile time",
                detail: "That is the whole privileged surface. The helper refuses to run it more "
                    + "than once every 20 seconds, and confirms a new Core Audio process appeared "
                    + "before it reports success.",
                code: PrivilegedPromptRepair.command
            ),
            Item(
                id: "prompt",
                title: "An administrator prompt, only if you ask",
                detail: "If the helper is not enabled, Fennec can run the same command through a "
                    + "standard macOS password prompt instead. It always asks you first and always "
                    + "shows you the command. It will never do this on its own after a failure.",
                code: nil
            )
        ]
    }

    /// What it costs, and what it does not do.
    static var facts: [Item] {
        [
            Item(
                id: "cost",
                title: "Every repair silences all audio for about a second",
                detail: "Restarting Core Audio disconnects playback and recording system-wide, for "
                    + "every app and every logged-in user. Fennec refuses while a microphone is "
                    + "live, while a call or recording app is using audio, and when it is not the "
                    + "session at the keyboard.",
                code: nil
            ),
            Item(
                id: "network",
                title: "No network, no account, no telemetry",
                detail: "Fennec contains no networking code. Nothing it observes leaves your Mac.",
                code: nil
            ),
            Item(
                id: "files",
                title: "Two files, both readable",
                detail: "A rotating log of everything Fennec saw, and a receipt for every repair it "
                    + "performed. Nothing else is written.",
                code: "~/Library/Application Support/Fennec/"
            ),
            Item(
                id: "limitation",
                title: "It detects the failure signal, not the sound",
                detail: "Fennec watches Core Audio for missed real-time deadlines. That is the best "
                    + "low-overhead system signal for this fault, but it is still a proxy: it cannot "
                    + "prove every overload was audible, and it cannot recognise a Mac that was "
                    + "already broken before Fennec started.",
                code: nil
            )
        ]
    }

    /// The three reasons a status item is not where the user is looking.
    static let missingFromMenuBar: [Item] = [
        Item(
            id: "manager",
            title: "A menu-bar manager is hiding it",
            detail: "Bartender, Ice, and Hidden Bar hide new items by default. Look in their "
                + "overflow area, or tell them to show Fennec.",
            code: nil
        ),
        Item(
            id: "notch",
            title: "The menu bar ran out of room",
            detail: "On a Mac with a notch, items past the notch are hidden rather than wrapped. "
                + "Quitting another menu-bar app, or widening the window you are in, brings it back.",
            code: nil
        ),
        Item(
            id: "dragged",
            title: "It was dragged off the bar",
            detail: "Holding Command and dragging a status item off the menu bar removes it until "
                + "the app is relaunched. Quit Fennec and open it again.",
            code: nil
        )
    ]
}
