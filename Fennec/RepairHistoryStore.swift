import Foundation

/// One completed repair attempt.
///
/// `EventLogger` writes the raw stream: every signal, every skip, every
/// device change. A `RepairRecord` is the part a person actually wants to
/// read: Fennec restarted Core Audio, here is why, on what, and how long the
/// gap in your audio was.
struct RepairRecord: Identifiable, Codable, Equatable, Sendable {
    enum Trigger: String, Codable, Sendable {
        /// Fennec decided on its own, after the detection threshold was met.
        case automatic
        /// The user pressed Repair Audio Now.
        case manual
        /// The test repair the first-run window asks the user to run. Listed
        /// in Activity, but never counted as an incident: nothing was wrong.
        case rehearsal

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .manual: return "Manual"
            case .rehearsal: return "Test"
            }
        }
    }

    let id: UUID
    let date: Date
    let trigger: Trigger
    /// `nil` for a manual repair: the user did not need a reason.
    let signal: AudioSignalKind?
    let signalCount: Int
    /// Wall-clock span between the first and last signal that triggered this
    /// repair. Zero when every signal arrived inside one 250 ms drain.
    let elapsedSeconds: Double
    let deviceName: String
    let transport: AudioTransport
    /// How long the repair itself took, from the XPC call to a confirmed new
    /// `coreaudiod`. This is roughly the length of the audio gap.
    let durationSeconds: Double
    let succeeded: Bool
    let message: String
    /// What became of it once there was time to find out. Older files have no
    /// such field; they decode as `.held` or `.failed` from `succeeded`.
    var outcome: RepairOutcome

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        trigger: Trigger,
        signal: AudioSignalKind?,
        signalCount: Int,
        elapsedSeconds: Double,
        deviceName: String,
        transport: AudioTransport,
        durationSeconds: Double,
        succeeded: Bool,
        message: String,
        outcome: RepairOutcome? = nil
    ) {
        self.id = id
        self.date = date
        self.trigger = trigger
        self.signal = signal
        self.signalCount = signalCount
        self.elapsedSeconds = elapsedSeconds
        self.deviceName = deviceName
        self.transport = transport
        self.durationSeconds = durationSeconds
        self.succeeded = succeeded
        self.message = message
        self.outcome = outcome ?? (succeeded ? .pending : .failed)
    }

    /// Tolerant of `repairs.json` files written before outcomes existed.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        signal = try container.decodeIfPresent(AudioSignalKind.self, forKey: .signal)
        signalCount = try container.decode(Int.self, forKey: .signalCount)
        elapsedSeconds = try container.decode(Double.self, forKey: .elapsedSeconds)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        transport = try container.decode(AudioTransport.self, forKey: .transport)
        durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        succeeded = try container.decode(Bool.self, forKey: .succeeded)
        message = try container.decode(String.self, forKey: .message)
        outcome = try container.decodeIfPresent(RepairOutcome.self, forKey: .outcome)
            ?? (succeeded ? .held : .failed)
    }
}

/// Everything the UI wants to say about a run of repairs, computed in one
/// pass so no view has to reduce the array itself.
struct RepairSummary: Equatable, Sendable {
    let total: Int
    /// Restarts that completed. Say "restarts performed" when showing this.
    let successes: Int
    /// Restarts the fault did not survive. The only number that earns gold.
    let held: Int
    let failures: Int
    let automatic: Int
    let last24Hours: Int
    let last7Days: Int
    let last30Days: Int
    let firstDate: Date?
    let lastDate: Date?
    let fastestSeconds: Double?
    let typicalSeconds: Double?
    let busiestDeviceName: String?

    static let empty = RepairSummary(
        total: 0, successes: 0, held: 0, failures: 0, automatic: 0,
        last24Hours: 0, last7Days: 0, last30Days: 0,
        firstDate: nil, lastDate: nil,
        fastestSeconds: nil, typicalSeconds: nil, busiestDeviceName: nil
    )

    static func make(from records: [RepairRecord], now: Date = Date()) -> RepairSummary {
        guard !records.isEmpty else { return .empty }

        // A repair that did not hold is not a repair. Counting it would make
        // the popover's headline number a measure of how broken the machine
        // is rather than how much Fennec helped. `held` is stricter still: it
        // excludes repairs that are only *provisionally* fine, so gold is
        // never spent on an unverified one.
        //
        // Rehearsals (the test repair first run asks for) are excluded from
        // both. Nothing was wrong.
        let real = records.filter { $0.trigger != .rehearsal }
        let successes = real.filter { $0.outcome == .held || $0.outcome == .pending }
        let held = real.filter { $0.outcome == .held }
        let durations = successes.map(\.durationSeconds).filter { $0 > 0 }.sorted()

        var deviceCounts: [String: Int] = [:]
        for record in successes where !record.deviceName.isEmpty {
            deviceCounts[record.deviceName, default: 0] += 1
        }
        // Ties break alphabetically so the label never flickers between runs.
        let busiest = deviceCounts
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .first?.key

        // Attempts, not held repairs: the labels say "attempts" so the two
        // numbers in the Activity header cannot be read as one population.
        func count(within interval: TimeInterval) -> Int {
            let cutoff = now.addingTimeInterval(-interval)
            return real.filter { $0.date >= cutoff }.count
        }

        return RepairSummary(
            total: records.count,
            successes: successes.count,
            held: held.count,
            failures: records.count - successes.count,
            automatic: records.filter { $0.trigger == .automatic }.count,
            last24Hours: count(within: 24 * 3_600),
            last7Days: count(within: 7 * 24 * 3_600),
            last30Days: count(within: 30 * 24 * 3_600),
            firstDate: records.map(\.date).min(),
            lastDate: records.map(\.date).max(),
            fastestSeconds: durations.first,
            typicalSeconds: durations.isEmpty ? nil : durations[durations.count / 2],
            busiestDeviceName: busiest
        )
    }
}

/// Persists repair receipts next to the event log, newest first.
///
/// Deliberately small and boring: one JSON array, written atomically, capped.
/// Fennec should never be the reason a Mac runs out of disk.
@MainActor
final class RepairHistoryStore: ObservableObject {
    /// Newest first. The UI reads this directly.
    @Published private(set) var records: [RepairRecord] = []
    @Published private(set) var summary: RepairSummary = .empty
    @Published private(set) var lastError: String?

    /// Roughly a year of a very bad machine. Older receipts fall off the end.
    static let maximumRecords = 500

    let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL? = nil) {
        let directory = directory ?? EventLogger.defaultDirectory()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(AppConstants.repairHistoryFileName)

        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder.dateDecodingStrategy = .iso8601

        load()
    }

    var lastSuccessfulRepair: RepairRecord? {
        records.first { $0.succeeded }
    }

    /// A repair still inside its verification window, if any.
    var pendingVerification: RepairRecord? {
        records.first { $0.outcome == .pending }
    }

    /// Records the verdict once the window closes, or once the fault returns.
    func setOutcome(_ outcome: RepairOutcome, for id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        guard records[index].outcome != outcome else { return }
        records[index].outcome = outcome
        recomputeSummary()
        persist()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            recomputeSummary()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            records = try decoder.decode([RepairRecord].self, from: data)
                .sorted { $0.date > $1.date }
            resolveStalePendingRecords()
            lastError = nil
        } catch {
            // A corrupt history is not worth losing the app over, but the user
            // should be able to find out why their receipts vanished.
            records = []
            lastError = "Fennec could not read its repair history: \(error.localizedDescription)"
        }
        recomputeSummary()
    }

    /// A repair left `.pending` by a quit is settled in the machine's favour.
    ///
    /// Fennec was not running to see whether the fault came back, so it cannot
    /// know, but leaving it `.pending` forever would mean a repair performed
    /// seconds before the user quit never counted at all. The benefit of the
    /// doubt is the honest reading, and it is stated here rather than hidden.
    private func resolveStalePendingRecords() {
        let cutoff = Date().addingTimeInterval(-RepairGovernor.verificationWindow)
        var changed = false
        for index in records.indices where records[index].outcome == .pending && records[index].date < cutoff {
            records[index].outcome = .held
            changed = true
        }
        if changed { persist() }
    }

    @discardableResult
    func record(_ repair: RepairRecord) -> RepairRecord {
        records.insert(repair, at: 0)
        if records.count > Self.maximumRecords {
            records.removeLast(records.count - Self.maximumRecords)
        }
        recomputeSummary()
        persist()
        return repair
    }

    func clear() {
        records = []
        recomputeSummary()
        persist()
    }

    func refreshSummary(now: Date = Date()) {
        summary = RepairSummary.make(from: records, now: now)
    }

    private func recomputeSummary() {
        summary = RepairSummary.make(from: records)
    }

    private func persist() {
        do {
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Fennec could not save its repair history: \(error.localizedDescription)"
        }
    }
}
