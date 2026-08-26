import Charts
import SwiftUI

/// The popover's live strip: the last thirty seconds of speaker trouble,
/// scrolling continuously while it is on screen.
///
/// The line plots the one quantity the engine actually compares — how many
/// overload signals fall inside the configured detection window, at every
/// instant — so the dashed threshold rule is the literal repair trigger, not
/// an illustration of it. Playback stalls (clean IO stops, the fault Fennec
/// cannot repair) sit along the baseline as triangles: identity carried by
/// shape and the legend, never by color alone. Nothing here animates for
/// attention; the only motion is time passing.
///
/// Cost: `TimelineView` schedules nothing while the popover is closed, so
/// this view costs exactly zero when nobody is looking at it.
struct SignalGraphView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings: SettingsStore
    /// Whether the hosting window is actually on screen. `MenuBarExtra`
    /// keeps its hosting view alive after the popover closes, and a
    /// display-driven `TimelineView` in a live-but-invisible window renders
    /// forever — measured at a third of a core, in an app whose brand is
    /// stillness. The occlusion probe below is the ground truth the view
    /// hierarchy cannot lie about.
    @State private var isOnScreen = false

    /// The rolling window the user watches.
    private static let span: TimeInterval = 30
    /// Step-line sampling resolution. Finer than a signal burst, coarser
    /// than pointless.
    private static let sampleStep: TimeInterval = 0.5
    /// Redraw cadence while visible. Four frames a second reads as steady
    /// motion on a 30-second window; the desert does not need 120.
    private static let frameInterval: TimeInterval = 0.25

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path")
                    .foregroundStyle(FennecBrand.dune)
                    .accessibilityHidden(true)
                Text("Signals")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("LAST 30 SECONDS")
                    .font(.caption2.weight(.bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
            }

            if isOnScreen {
                TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
                    VStack(alignment: .leading, spacing: 3) {
                        chart(at: context.date)
                            .frame(height: 62)
                        activityRibbon(at: context.date)
                            .frame(height: 6)
                    }
                }
            } else {
                // Off screen, nobody is looking: hold the layout, do no work.
                Color.clear.frame(height: 62 + 3 + 6)
            }

            legend
        }
        .padding(13)
        .background(WindowVisibilityProbe(isOnScreen: $isOnScreen))
        .onChange(of: isOnScreen) { _, visible in
            model.setGraphVisible(visible)
        }
        .background(FennecBrand.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FennecBrand.cardStroke, lineWidth: 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func chart(at now: Date) -> some View {
        let start = now.addingTimeInterval(-Self.span)
        let window = settings.sensitivity.window
        let threshold = settings.sensitivity.threshold
        let overloads = model.recentOverloadDates.sorted()
        let stalls = model.recentStallDates.filter { $0 >= start && $0 <= now }

        let samples = stride(from: 0, through: Self.span, by: Self.sampleStep).map { offset in
            let t = start.addingTimeInterval(offset)
            let cutoff = t.addingTimeInterval(-window)
            let count = overloads.reduce(into: 0) { partial, date in
                if date > cutoff && date <= t { partial += 1 }
            }
            return (time: t, count: count)
        }
        let peak = samples.map(\.count).max() ?? 0
        // Quiet, the line hugs the floor and the rule sits above it; the
        // scale only stretches when signals genuinely outgrow it.
        let yTop = max(threshold + 1, peak + 1)
        let lineColor = peak > 0 ? FennecBrand.dune : FennecBrand.sky

        return Chart {
            RuleMark(y: .value("Repair threshold", threshold))
                .foregroundStyle(.secondary)
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .annotation(position: .top, alignment: .trailing, spacing: 2) {
                    Text("repairs at \(threshold) in \(Int(window)) s")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

            ForEach(samples, id: \.time) { sample in
                LineMark(
                    x: .value("Time", sample.time),
                    y: .value("Signals in window", sample.count)
                )
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(lineColor)
            }

            ForEach(stalls, id: \.self) { stall in
                PointMark(
                    x: .value("Time", stall),
                    y: .value("Signals in window", 0)
                )
                .symbol(.triangle)
                .symbolSize(42)
                .foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: start...now)
        .chartYScale(domain: 0...yTop)
        .chartXAxis {
            AxisMarks(values: [start, start.addingTimeInterval(Self.span / 2), now]) { value in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(xLabel(for: date, now: now))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(.quaternary)
                AxisValueLabel()
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// The proof-of-life strip under the time axis: painted for every second
    /// the output device was actually running IO, blank where it was not. A
    /// break in the ribbon while music was supposed to be playing *is* the
    /// dropout — the graph agreeing with the user's ears. Drawn as its own
    /// strip rather than a series so the count axis stays a count axis.
    private func activityRibbon(at now: Date) -> some View {
        let start = now.addingTimeInterval(-Self.span)
        let segments = AudioActivitySegments.merged(
            sampleDates: model.recentAudioActivity.filter { $0 >= start.addingTimeInterval(-2) }
        )
        return Canvas { context, size in
            for segment in segments {
                // Each sample covers its second, so a lone sample still
                // paints a visible sliver rather than a zero-width rect.
                let from = max(0, segment.lowerBound.timeIntervalSince(start))
                let to = min(Self.span, segment.upperBound.timeIntervalSince(start) + 1)
                guard to > from else { continue }
                let rect = CGRect(
                    x: from / Self.span * size.width,
                    y: 0,
                    width: (to - from) / Self.span * size.width,
                    height: size.height
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: size.height / 2),
                    with: .color(FennecBrand.sky.opacity(0.55))
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func xLabel(for date: Date, now: Date) -> String {
        let ago = now.timeIntervalSince(date)
        return ago < 1 ? "now" : "\(Int(ago.rounded())) s"
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(FennecBrand.dune)
                    .frame(width: 12, height: 2)
                Text("signals in last \(Int(settings.sensitivity.window)) s")
            }
            HStack(spacing: 5) {
                Image(systemName: "triangle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                Text("playback stall")
            }
            HStack(spacing: 5) {
                Capsule()
                    .fill(FennecBrand.sky.opacity(0.55))
                    .frame(width: 12, height: 4)
                Text("audio playing")
            }
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var accessibilitySummary: String {
        let cutoff = Date().addingTimeInterval(-Self.span)
        let overloads = model.recentOverloadDates.filter { $0 > cutoff }.count
        let stalls = model.recentStallDates.filter { $0 > cutoff }.count
        let playingSeconds = model.recentAudioActivity.filter { $0 > cutoff }.count
        return "Last 30 seconds: \(overloads) overload signal\(overloads == 1 ? "" : "s"), "
            + "\(stalls) playback stall\(stalls == 1 ? "" : "s"), "
            + "audio playing for about \(min(playingSeconds, Int(Self.span))) seconds. "
            + "Repairs at \(settings.sensitivity.threshold) signals in \(Int(settings.sensitivity.window)) seconds."
    }
}

/// Reports whether the view's window is genuinely on screen — attached,
/// visible, and not fully occluded. SwiftUI's own appearance callbacks are
/// not that: `MenuBarExtra` keeps the popover's hosting view alive after it
/// closes, so `onAppear`/`onDisappear` cannot be trusted to bracket
/// visibility, and anything animation-driven keeps rendering unseen.
private struct WindowVisibilityProbe: NSViewRepresentable {
    @Binding var isOnScreen: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { [self] visible in
            if isOnScreen != visible {
                isOnScreen = visible
            }
        }
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onChange = { [self] visible in
            if isOnScreen != visible {
                isOnScreen = visible
            }
        }
    }

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        deinit {
            observers.forEach(NotificationCenter.default.removeObserver(_:))
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver(_:))
            observers = []
            if let window {
                // Occlusion flips both ways when the popover opens and
                // closes; willClose is the belt for teardown paths that
                // never post an occlusion change.
                let names: [Notification.Name] = [
                    NSWindow.didChangeOcclusionStateNotification,
                    NSWindow.willCloseNotification
                ]
                observers = names.map { name in
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: .main
                    ) { [weak self] _ in
                        self?.report()
                    }
                }
            }
            report()
        }

        private func report() {
            let visible = window.map {
                $0.isVisible && $0.occlusionState.contains(.visible)
            } ?? false
            let onChange = onChange
            // Next runloop turn: this can fire mid-layout, and mutating
            // SwiftUI state from inside a layout pass is undefined.
            DispatchQueue.main.async {
                onChange?(visible)
            }
        }
    }
}
