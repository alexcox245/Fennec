import AppKit
import SwiftUI

/// The AppKit half of an app that is mostly a menu-bar item.
///
/// Two things SwiftUI's `App` does not do for an `LSUIElement` process:
///
/// - **Reopen.** An unfinished first run still needs its welcome window.
///   Once dismissed, Fennec stays quiet in the menu bar on later launches.
/// - **Termination.** Quitting mid-repair would leave the user's audio in
///   whatever state the helper had reached. A repair is about a second; it is
///   worth waiting out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `FennecApp` once the model exists. Weak because the model
    /// outlives nothing; it is owned by the scene.
    @MainActor static weak var model: AppModel?

    /// How long `applicationShouldTerminate` will hold quit open for an
    /// in-flight repair before giving up. The helper's own call times out at
    /// 10 s, so this can never wait forever.
    private static let repairQuitGrace: TimeInterval = 12

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Info.plist already sets LSUIElement, but a build launched straight
        // from Xcode can come up as a regular app, leaving a stray Dock icon
        // with no windows behind it.
        MainActor.assumeIsolated {
            if NSApp.activationPolicy() != .accessory && !WindowPresenter.shared.hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            // AppKit's flag also counts the click-through fox panel. Only
            // a window someone can use should suppress a Dock reopen.
            guard !WindowPresenter.shared.hasInteractiveWindowOnScreen else { return true }
            guard let model = Self.model else { return true }
            // After onboarding, a relaunch should only restore the menu-bar
            // utility. Settings opens when the user explicitly chooses it.
            if model.settings.shouldShowWelcomeOnReopen {
                WindowPresenter.shared.showWelcome(model: model)
            }
            return true
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model = Self.model, model.isRepairing else { return .terminateNow }

            let deadline = Date().addingTimeInterval(Self.repairQuitGrace)
            // Poll rather than observe: this runs once, on quit, and a Combine
            // subscription that has to be torn down correctly during
            // termination is more ways to hang than a timer.
            //
            // `.common` is load-bearing. AppKit runs the loop in
            // `NSModalPanelRunLoopMode` while a termination is deferred, so a
            // `Timer.scheduledTimer` (which registers in `.default` only)
            // never fires, `reply(toApplicationShouldTerminate:)` is never
            // called, and ⌘Q hangs until Force Quit.
            let timer = Timer(timeInterval: 0.25, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard let model = Self.model else {
                        timer.invalidate()
                        NSApp.reply(toApplicationShouldTerminate: true)
                        return
                    }
                    if !model.isRepairing || Date() >= deadline {
                        timer.invalidate()
                        // If the grace ran out we are almost certainly waiting
                        // on a human at an administrator password dialog.
                        // Leaving that dialog on screen owned by a process
                        // that is about to exit is exactly the signature of
                        // a credential-phishing prompt, so cancel it.
                        if Date() >= deadline { PrivilegedPromptRepair.cancelInFlight() }
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            return .terminateLater
        }
    }
}
