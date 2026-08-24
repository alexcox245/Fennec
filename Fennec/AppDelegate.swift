import AppKit
import SwiftUI

/// The AppKit half of an app that is mostly a menu-bar item.
///
/// Two things SwiftUI's `App` does not do for an `LSUIElement` process:
///
/// - **Reopen.** Double-clicking Fennec while it is already running does
///   nothing at all by default. There is no Dock icon to bounce and no window
///   to raise, so the second launch is silently swallowed and the user
///   concludes the app is broken. `applicationShouldHandleReopen` turns it
///   into "show me what you are".
/// - **Termination.** Quitting mid-repair would leave the user's audio in
///   whatever state the helper had reached. A repair is about a second; it is
///   worth waiting out.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by `FennecApp` once the model exists. Weak because the model
    /// outlives nothing — it is owned by the scene.
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
            guard !flag else { return true }
            guard let model = Self.model else { return true }
            WindowPresenter.shared.showSettings(model: model)
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
            Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { timer in
                MainActor.assumeIsolated {
                    guard let model = Self.model else {
                        timer.invalidate()
                        NSApp.reply(toApplicationShouldTerminate: true)
                        return
                    }
                    if !model.isRepairing || Date() >= deadline {
                        timer.invalidate()
                        NSApp.reply(toApplicationShouldTerminate: true)
                    }
                }
            }
            return .terminateLater
        }
    }
}
