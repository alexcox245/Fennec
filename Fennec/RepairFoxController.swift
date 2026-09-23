import AppKit
import QuartzCore

/// Owned by WindowPresenter. This is a decorative panel, never a real app
/// window: it cannot take focus, receive input, or change activation policy.
@MainActor
final class RepairFoxController {
    private let assetURL: URL?
    private var assetTask: Task<FoxRunAsset?, Never>?
    private var presentationTask: Task<Void, Never>?
    private var lifecycle = FoxRunLifecycle()
    private var panel: NSPanel?
    private var enabled = false
    private var screensAwake = true
    private var sessionActive = true
    private var screenLocked = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedTokens: [NSObjectProtocol] = []

    init(assetURL: URL?) {
        self.assetURL = assetURL
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.screensAwake = false; $0.stop() }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAwake = false; $0.stop() }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAwake = true }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionActive = false; $0.stop() }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionActive = true }
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { $0.stop() }
        }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { $0.stop() }
        observe(.default, NSApplication.didHideNotification) { $0.stop() }
        observe(.default, NSApplication.willTerminateNotification) { $0.stop() }

        // The same best-effort lock notifications SystemEventObserver uses.
        // Sleep and session notifications independently tear the panel down.
        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedTokens.append(distributed.addObserver(
                forName: Notification.Name(name), object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.screenLocked = locked
                    if locked { self?.stop() }
                }
            })
        }
    }

    deinit {
        presentationTask?.cancel()
        for (center, token) in tokens { center.removeObserver(token) }
        for token in distributedTokens { DistributedNotificationCenter.default().removeObserver(token) }
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        if enabled { preload() } else { stop() }
    }

    private var mayPresent: Bool {
        enabled && screensAwake && sessionActive && !screenLocked
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && !NSApp.isHidden
    }

    private func preload() {
        guard assetTask == nil, let assetURL else { return }
        assetTask = Task.detached(priority: .utility) {
            try? FoxRunAsset.load(from: assetURL)
        }
    }

    func show(for id: UUID) {
        guard mayPresent else { return }
        let screens = NSScreen.screens
        guard let index = FoxRunMotion.screenIndex(containing: NSEvent.mouseLocation, frames: screens.map(\.frame)),
              lifecycle.begin(id) else { return }
        // Snapshot once: moving the pointer must not move an in-flight fox.
        let screen = screens[index]
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame
        preload()
        guard let assetTask else { finish(id); return }
        let requestedAt = CACurrentMediaTime()
        presentationTask = Task { [weak self] in
            let asset = await assetTask.value
            guard let self, self.lifecycle.currentID == id, !Task.isCancelled else { return }
            guard self.mayPresent, CACurrentMediaTime() - requestedAt < 2,
                  let asset,
                  let motion = FoxRunMotion(
                    screenFrame: screenFrame, visibleFrame: visibleFrame, cycleDuration: asset.cycle.duration
                  ) else { self.finish(id); return }
            self.present(asset, motion: motion, id: id)
            self.presentationTask = nil
        }
    }

    func cancel(for id: UUID) { finish(id) }

    func stop() {
        if let id = lifecycle.currentID { finish(id) }
    }

    private func finish(_ id: UUID) {
        guard lifecycle.finish(id) else { return }
        presentationTask?.cancel()
        presentationTask = nil
        panel?.contentView?.layer?.sublayers?.forEach { $0.removeAllAnimations() }
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func present(_ asset: FoxRunAsset, motion: FoxRunMotion, id: UUID) {
        let panel = RepairFoxPanel(
            contentRect: motion.panelFrame, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("fennec.repair-fox")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.setAccessibilityElement(false)

        let view = NSView(frame: CGRect(origin: .zero, size: motion.panelFrame.size))
        let root = CALayer()
        root.masksToBounds = true
        view.layer = root
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        panel.contentView = view

        let sprite = CALayer()
        sprite.bounds = CGRect(origin: .zero, size: motion.spriteSize)
        sprite.position = motion.end
        sprite.contents = asset.frames[0]
        sprite.contentsScale = 2
        sprite.contentsGravity = .resize
        // Flip only the drawing. Translation remains left to right.
        sprite.transform = CATransform3DMakeScale(-1, 1, 1)
        root.addSublayer(sprite)

        let gait = CAKeyframeAnimation(keyPath: "contents")
        gait.values = asset.frames + [asset.frames[0]]
        gait.keyTimes = asset.cycle.keyTimes.map { NSNumber(value: $0) }
        gait.calculationMode = .discrete
        gait.duration = motion.cycleDuration
        gait.repeatDuration = motion.duration

        let travel = CABasicAnimation(keyPath: "position")
        travel.fromValue = NSValue(point: motion.start)
        travel.toValue = NSValue(point: motion.end)
        travel.duration = motion.duration
        travel.timingFunction = CAMediaTimingFunction(name: .linear)

        let crossing = CAAnimationGroup()
        crossing.animations = [gait, travel]
        crossing.duration = motion.duration
        crossing.timingFunction = CAMediaTimingFunction(name: .linear)
        // One clock for the paw cycle and translation; no per-frame timers.
        crossing.beginTime = sprite.convertTime(CACurrentMediaTime(), from: nil)
        self.panel = panel
        panel.orderFrontRegardless()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.finish(id) }
        }
        sprite.add(crossing, forKey: "crossing")
        CATransaction.commit()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor (RepairFoxController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
        tokens.append((center, token))
    }
}

private final class RepairFoxPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
