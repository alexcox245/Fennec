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
    private var onboardingAttemptID: UUID?
    private var onboardingBurst = RepairFoxBurst()
    private var onboardingAutoReset = false
    private var onboardingLoadTask: Task<Void, Never>?
    private var onboardingWakeTask: Task<Void, Never>?
    private var onboardingAsset: FoxRunAsset?
    private var onboardingMotion: FoxRunMotion?
    private var onboardingPanel: NSPanel?
    private var onboardingSprites: [UUID: CALayer] = [:]
    private var enabled = false
    private var screensAwake = true
    private var sessionActive = true
    private var screenLocked = false
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var distributedTokens: [NSObjectProtocol] = []
    var onManualBurstFinished: (@MainActor (UUID) -> Void)?

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
        onboardingLoadTask?.cancel()
        onboardingWakeTask?.cancel()
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

    var canShowUserBurst: Bool { mayPresent && assetURL != nil }

    private func preload() {
        guard assetTask == nil, let assetURL else { return }
        assetTask = Task.detached(priority: .utility) {
            try? FoxRunAsset.load(from: assetURL)
        }
    }

    func show(for id: UUID) {
        guard mayPresent, onboardingAttemptID == nil else { return }
        let screens = NSScreen.screens
        guard let index = FoxRunMotion.screenIndex(containing: NSEvent.mouseLocation, frames: screens.map(\.frame)),
              lifecycle.begin(id) else { return }
        // Snapshot once: moving the pointer must not move an in-flight fox.
        let screen = screens[index]
        let screenFrame = screen.frame
        preload()
        guard let assetTask else { finish(id); return }
        let requestedAt = CACurrentMediaTime()
        presentationTask = Task { [weak self] in
            let asset = await assetTask.value
            guard let self, self.lifecycle.currentID == id, !Task.isCancelled else { return }
            guard self.mayPresent, CACurrentMediaTime() - requestedAt < 2,
                  let asset,
                  let motion = FoxRunMotion(
                    screenFrame: screenFrame, cycleDuration: asset.cycle.duration
                  ) else { self.finish(id); return }
            self.present(asset, motion: motion, id: id)
            self.presentationTask = nil
        }
    }

    func cancel(for id: UUID) { finish(id) }

    /// The first onboarding click starts one real repair and one crossing.
    /// Later clicks only add requests to this bounded animation queue.
    @discardableResult
    func startOnboarding(for attemptID: UUID, autoReset: Bool = false) -> Bool {
        guard mayPresent, onboardingAttemptID == nil else { return false }
        let screens = NSScreen.screens
        guard let index = FoxRunMotion.screenIndex(containing: NSEvent.mouseLocation, frames: screens.map(\.frame))
        else { return false }
        preload()
        guard let assetTask else { return false }

        if let currentID = lifecycle.currentID { finish(currentID) }
        onboardingAttemptID = attemptID
        onboardingAutoReset = autoReset
        onboardingBurst.reset()
        _ = onboardingBurst.request()
        let screenFrame = screens[index].frame
        onboardingLoadTask = Task { [weak self] in
            let asset = await assetTask.value
            guard let self, self.onboardingAttemptID == attemptID, !Task.isCancelled else { return }
            guard self.mayPresent, let asset,
                  let motion = FoxRunMotion(screenFrame: screenFrame, cycleDuration: asset.cycle.duration)
            else { self.resetOnboarding(); return }
            self.onboardingAsset = asset
            self.onboardingMotion = motion
            self.onboardingLoadTask = nil
            self.pumpOnboarding()
        }
        return true
    }

    @discardableResult
    func queueOnboardingReplay() -> Bool {
        guard mayPresent else { return false }
        if onboardingAttemptID == nil { return startOnboarding(for: UUID()) }
        guard onboardingBurst.request() else { return false }
        pumpOnboarding()
        return true
    }

    func cancelOnboarding(for attemptID: UUID) {
        guard onboardingAttemptID == attemptID else { return }
        resetOnboarding()
    }

    func resetOnboarding() {
        let finishedID = onboardingAutoReset ? onboardingAttemptID : nil
        onboardingLoadTask?.cancel()
        onboardingLoadTask = nil
        onboardingWakeTask?.cancel()
        onboardingWakeTask = nil
        onboardingSprites.values.forEach {
            $0.removeAllAnimations()
            $0.removeFromSuperlayer()
        }
        onboardingSprites.removeAll()
        onboardingPanel?.orderOut(nil)
        onboardingPanel?.close()
        onboardingPanel = nil
        onboardingAsset = nil
        onboardingMotion = nil
        onboardingAttemptID = nil
        onboardingAutoReset = false
        onboardingBurst.reset()
        if let finishedID { onManualBurstFinished?(finishedID) }
    }

    func stop() {
        if let id = lifecycle.currentID { finish(id) }
        resetOnboarding()
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

    private func pumpOnboarding() {
        onboardingWakeTask?.cancel()
        onboardingWakeTask = nil
        guard mayPresent, let asset = onboardingAsset, let motion = onboardingMotion else { return }
        let now = CACurrentMediaTime()
        guard let delay = onboardingBurst.delayUntilNext(at: now) else {
            if onboardingSprites.isEmpty {
                closeOnboardingPanel()
                if onboardingAutoReset { resetOnboarding() }
            }
            return
        }
        if delay > 0 {
            onboardingWakeTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.onboardingWakeTask = nil
                self?.pumpOnboarding()
            }
            return
        }

        if onboardingPanel == nil {
            onboardingPanel = makePanel(motion: motion)
            onboardingPanel?.orderFrontRegardless()
        }
        guard let root = onboardingPanel?.contentView?.layer,
              onboardingBurst.spawn(at: now) else { return }
        let id = UUID()
        onboardingSprites[id] = addCrossing(asset, motion: motion, to: root) { [weak self] in
            self?.finishOnboarding(id)
        }
        pumpOnboarding()
    }

    private func finishOnboarding(_ id: UUID) {
        guard let sprite = onboardingSprites.removeValue(forKey: id) else { return }
        sprite.removeAllAnimations()
        sprite.removeFromSuperlayer()
        onboardingBurst.finish()
        pumpOnboarding()
    }

    private func closeOnboardingPanel() {
        onboardingPanel?.orderOut(nil)
        onboardingPanel?.close()
        onboardingPanel = nil
    }

    private func present(_ asset: FoxRunAsset, motion: FoxRunMotion, id: UUID) {
        let panel = makePanel(motion: motion)
        self.panel = panel
        panel.orderFrontRegardless()
        guard let root = panel.contentView?.layer else { finish(id); return }
        _ = addCrossing(asset, motion: motion, to: root) { [weak self] in
            self?.finish(id)
        }
    }

    private func makePanel(motion: FoxRunMotion) -> NSPanel {
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
        // The fox runs through the Dock's area but never intercepts its clicks.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.setAccessibilityElement(false)

        let view = NSView(frame: CGRect(origin: .zero, size: motion.panelFrame.size))
        let root = CALayer()
        root.masksToBounds = true
        view.layer = root
        view.wantsLayer = true
        view.setAccessibilityElement(false)
        panel.contentView = view
        return panel
    }

    @discardableResult
    private func addCrossing(
        _ asset: FoxRunAsset,
        motion: FoxRunMotion,
        to root: CALayer,
        completion: @escaping @MainActor () -> Void
    ) -> CALayer {
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
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            Task { @MainActor in completion() }
        }
        sprite.add(crossing, forKey: "crossing")
        CATransaction.commit()
        return sprite
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
