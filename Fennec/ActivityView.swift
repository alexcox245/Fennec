import SwiftUI

/// Everything Fennec has ever had to do, grouped by day.
///
/// Deliberately not a sortable table with filters and a CSV export. Every
/// version of that is a window a person opens once, on install day, to find
/// it empty. This is a receipt book: what happened, when, on what, and
/// whether it worked — in the same words the notification used, because they
/// come from the same place.
struct ActivityView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var history: RepairHistoryStore

    init(model: AppModel) {
        self.model = model
        _history = ObservedObject(wrappedValue: model.repairHistory)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if history.records.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(minWidth: 520, minHeight: 460)
        .task { model.refreshAll() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 20) {
                statistic(RepairCopy.headlineNumber(for: history.summary), "repairs that held", accent: FennecBrand.gold)
                statistic("\(history.summary.last7Days)", "attempts in 7 days")
                if let typical = history.summary.typicalSeconds {
                    statistic(RepairCopy.duration(typical), "typical gap")
                }
                if let fastest = history.summary.fastestSeconds {
                    statistic(RepairCopy.duration(fastest), "fastest")
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Text(RepairCopy.summaryLine(for: history.summary))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let device = history.summary.busiestDeviceName {
                    Text("Most often on \(device).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reveal Event Log") { model.openEventLog() }
                    .controlSize(.small)
                    .help("The raw JSONL stream: every signal, every skipped repair, every device change.")
            }
        }
        .padding(20)
    }

    private func statistic(_ value: String, _ label: String, accent: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(accent)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(label)")
    }

    // MARK: Contents

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(nsImage: MenuBarIcon.image(for: .listening, size: CGSize(width: 44, height: 44)))
                .opacity(0.35)
                .accessibilityHidden(true)
            Text("Nothing to report")
                .font(.title3.weight(.medium))
            Text("Fennec has not had to restart Core Audio. This page fills in when it does.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groupedByDay, id: \.day) { group in
                    Section {
                        ForEach(group.records) { record in
                            row(record)
                            Divider().padding(.leading, 20)
                        }
                    } header: {
                        Text(group.title)
                            .font(.caption.weight(.bold))
                            .tracking(0.4)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 7)
                            .background(.bar)
                            .accessibilityAddTraits(.isHeader)
                    }
                }
            }
        }
    }

    private func row(_ record: RepairRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(record.date, style: .time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 78, alignment: .leading)

            Image(systemName: record.outcome.symbolName)
                .foregroundStyle(FennecBrand.accent(for: record.outcome))
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(RepairCopy.receiptHeadline(for: record))
                    .font(.callout.weight(.medium))
                Text(RepairCopy.receiptDetail(for: record))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 8)

            Text(record.trigger.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(record.date.formatted(date: .omitted, time: .shortened)). "
            + "\(RepairCopy.receiptHeadline(for: record)). \(RepairCopy.receiptDetail(for: record))"
        )
    }

    // MARK: Grouping

    private struct DayGroup {
        let day: Date
        let title: String
        let records: [RepairRecord]
    }

    private var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: history.records) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { day in
            DayGroup(
                day: day,
                title: day.formatted(.dateTime.weekday(.wide).day().month(.wide)).uppercased(),
                records: (grouped[day] ?? []).sorted { $0.date > $1.date }
            )
        }
    }
}
