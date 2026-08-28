import AppKit
import SwiftUI

/// Windows for an app that does not really have any.
///
/// Fennec is `LSUIElement`, which is right: it belongs in the menu bar, not
/// the Dock. But an accessory app has no main menu, and that quietly breaks
/// every window it opens: ⌘W does nothing, ⌘Q does nothing, ⌘, does nothing,
/// and the window will not reliably come to the front. Users read that as a
/// broken app, not as a deliberate design choice.
///
/// The fix every good menu-bar utility uses: be an accessory while only the
/// popover is showing, and become a regular app for exactly as long as a real
/// window is open. The Dock icon and the menu bar appear with the window and
/// leave with it, so the standard shortcuts work the entire time a user can
/// see something to type them at.
@MainActor
final class WindowPresenter: NSObject, NSWindowDelegate {
    static let shared = WindowPresenter()

    enum ID {
        static let settings = "fennec.settings"
        static let welcome = "fennec.welcome"
        static let activity = "fennec.activity"
        static let about = "fennec.about"
    }

    // MARK: The app's windows

    /// Settings is hosted here rather than in SwiftUI's `Settings` scene.
    ///
    /// That scene's only programmatic entry point is the undocumented
    /// `showSettingsWindow:` responder action, which reports success and then
    /// does nothing at all in an `LSUIElement` app (verified on macOS 26).
    /// Owning the window means ⌘, , the menu item, the popover's Settings
    /// button, and a Dock reopen all take one code path that demonstrably
    /// works, instead of three that hope.
    /// The first-run window. Full-size content so the masthead runs under the
    /// title bar; there is no title worth showing above "Fennec".
    func showWelcome(model: AppModel) {
        show(
            id: ID.welcome,
            title: "Welcome to Fennec",
            size: CGSize(width: 620, height: 720),
            // Must not be below WelcomeView's own minHeight, or the host
            // clips the footer, and the footer holds Done.
            minSize: CGSize(width: 560, height: 640)
        ) {
            WelcomeView(model: model).tint(FennecBrand.sky)
        }
    }

    /// The privilege panel. Replaces the standard About panel, which shows a
    /// version number and a copyright line, not what anyone wants to know
    /// about an app that installs a root LaunchDaemon.
    func showAbout(model: AppModel) {
        show(
            id: ID.about,
            title: "About Fennec",
            size: CGSize(width: 580, height: 660),
            minSize: CGSize(width: 540, height: 560)
        ) {
            AboutView(model: model).tint(FennecBrand.sky)
        }
    }

    /// The receipt book. Everything Fennec has had to do, grouped by day.
    func showActivity(model: AppModel) {
        show(
            id: ID.activity,
            title: "Fennec Activity",
            size: CGSize(width: 620, height: 560),
            minSize: CGSize(width: 520, height: 460)
        ) {
            ActivityView(model: model).tint(FennecBrand.sky)
        }
    }

    func showSettings(model: AppModel) {
        show(
            id: ID.settings,
            title: "Fennec Settings",
            size: CGSize(width: 650, height: 580),
            minSize: CGSize(width: 650, height: 560)
        ) {
            SettingsView(model: model).tint(FennecBrand.sky)
        }
    }

    private var windows: [String: NSWindow] = [:]
    private var observers: [NSObjectProtocol] = []
    /// When a window was last asked for. Dropping back to `.accessory` inside
    /// this grace period would undo an open that is still in flight; the
    /// SwiftUI `Settings` scene, in particular, materialises its window a few
    /// run-loop turns after the action is sent.
    private var lastOpenRequest = Date.distantPast
    private static let openGrace: TimeInterval = 2.5

    private override init() {
        super.init()
        // The Settings scene is SwiftUI's window, not ours, but it has the
        // same problem, so watch every window, not just the ones we made.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    WindowPresenter.shared.scheduleActivationPolicySync()
                }
            })
        }
    }

    // MARK: Presenting

    /// Shows the window for `id`, creating it the first time. Calling it again
    /// brings the existing window forward instead of opening a second copy.
    func show<Content: View>(
        id: String,
        title: String,
        size: CGSize,
        resizable: Bool = true,
        minSize: CGSize? = nil,
        /// Lets content run under the title bar. Right for a window whose top
        /// edge is artwork; wrong for one that starts with controls, which is
        /// why Settings does not use it.
        fullSizeContent: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        if let existing = windows[id] {
            bringForward(existing)
            return
        }

        var style: NSWindow.StyleMask = [.titled, .closable]
        if fullSizeContent { style.insert(.fullSizeContentView) }
        if resizable {
            style.insert(.resizable)
            style.insert(.miniaturizable)
        }

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.identifier = NSUserInterfaceItemIdentifier(id)
        window.contentViewController = NSHostingController(rootView: content())
        window.setContentSize(size)
        if let minSize {
            window.contentMinSize = minSize
        } else if !resizable {
            window.contentMinSize = size
            window.contentMaxSize = size
        }
        // Each window remembers where the user put it, per macOS convention.
        window.setFrameAutosaveName("Fennec.\(id)")
        if window.frame.origin == .zero {
            window.center()
        }

        windows[id] = window
        bringForward(window)
    }

    func close(_ id: String) {
        windows[id]?.performClose(nil)
    }

    func isOpen(_ id: String) -> Bool {
        windows[id]?.isVisible ?? false
    }

    /// True while any window a person can focus is on screen. The
    /// `MenuBarExtra` popover is borderless and cannot become main, so it
    /// never counts.
    var hasVisibleWindow: Bool {
        NSApp.windows.contains(where: isRealWindow)
    }

    private func bringForward(_ window: NSWindow) {
        // Order matters: become a regular app first so the window has a menu
        // bar to attach to, then activate, then show.
        lastOpenRequest = Date()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Activation policy

    /// Called for **every** way a window closes: the red button, ⌘W, ⌘Q, and
    /// the app's own `close(_:)`.
    var onWindowClosed: ((String) -> Void)?

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow,
           let id = window.identifier?.rawValue {
            onWindowClosed?(id)
        }
        scheduleActivationPolicySync()
    }

    /// Runs on the next turn of the run loop so `isVisible` reflects the close
    /// that is currently in flight.
    private func scheduleActivationPolicySync() {
        DispatchQueue.main.async { [weak self] in
            self?.syncActivationPolicy()
        }
    }

    /// A "real" window is one a person can focus and type into. The
    /// `MenuBarExtra` popover is borderless and cannot become main, so it
    /// never counts, which is what keeps the Dock icon from appearing every
    /// time someone opens the menu.
    private func isRealWindow(_ window: NSWindow) -> Bool {
        // `isVisible` is false for a miniaturised window, so without the
        // second clause minimising Activity and then opening the popover drops
        // the app to .accessory while one of its windows sits in the Dock.
        (window.isVisible || window.isMiniaturized)
            && window.canBecomeMain
            && window.styleMask.contains(.titled)
            && !(window is NSPanel)
    }

    private func syncActivationPolicy() {
        // A "real" window is one a person can focus and type into. The
        // MenuBarExtra popover is borderless and cannot become main, so it
        // never counts, which is what keeps the Dock icon from flickering
        // every time someone opens the menu.
        let desired: NSApplication.ActivationPolicy = hasVisibleWindow ? .regular : .accessory
        if desired == .accessory, Date().timeIntervalSince(lastOpenRequest) < Self.openGrace {
            // A window was requested moments ago and has not appeared yet.
            // Flipping back now would cancel it. Re-check after the grace.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.openGrace) { [weak self] in
                self?.syncActivationPolicy()
            }
            return
        }
        guard NSApp.activationPolicy() != desired else { return }
        NSApp.setActivationPolicy(desired)
    }
}
