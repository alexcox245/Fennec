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

    /// The rolling window the user watches.
    private static let span: TimeInterval = 30
    /// Step-line sampling resolution. Finer than the drain interval, coarser
    /// than pointless.
    private static let sampleStep: TimeInterval = 0.25

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

            TimelineView(.animation(minimumInterval: 0.1)) { context in
                chart(at: context.date)
            }
            .frame(height: 68)

            legend
        }
        .padding(13)
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
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var accessibilitySummary: String {
        let overloads = model.recentOverloadDates.filter {
            $0 > Date().addingTimeInterval(-Self.span)
        }.count
        let stalls = model.recentStallDates.filter {
            $0 > Date().addingTimeInterval(-Self.span)
        }.count
        return "Last 30 seconds: \(overloads) overload signal\(overloads == 1 ? "" : "s"), "
            + "\(stalls) playback stall\(stalls == 1 ? "" : "s"). "
            + "Repairs at \(settings.sensitivity.threshold) signals in \(Int(settings.sensitivity.window)) seconds."
    }
}
