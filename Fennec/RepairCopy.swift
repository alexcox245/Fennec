import Foundation

/// Every user-facing sentence Fennec says about a repair.
///
/// It lives in one place for two reasons. The obvious one: the notification,
/// the menu receipt, and the activity list must not drift apart. The real
/// one: this copy is the product.
///
/// The register is plain, not technical (owner directive, T-043). Nobody
/// installs this because they know what Core Audio is; they install it
/// because they hear crackling and want it to stop. So the words the user
/// reads are the words they would use: a crackle, heard, fixed. The
/// mechanism is still recorded exactly, in the event log and in the About
/// panel's privilege disclosure, where precision is the point and an
/// audience that wants it is the one reading.
///
/// Two rules follow, and the tests enforce both: no "Core Audio" in
/// anything a banner or a popover shows, and no timings. "Fixed in 0.54 s"
/// answers a question nobody asked.
enum RepairCopy {

    // MARK: First run

    static let onboardingTestTitle = "Try it now"
    static let onboardingTestButton = "Run a Test Repair"
    static let onboardingTestWorking = "Repairing…"
    static let onboardingTestDetail = "Run a test repair. Sound restarts across this Mac; your apps stay open."
    static let onboardingReplayButton = "Run Again"
    static let onboardingReplayHelp = "Another fox runs. Only the first click repairs audio."
    static let replayButtonSymbol = "play.fill"

    // MARK: The repair fox

    static let foxSection = "Repair Animation"
    static let foxSetting = "Show fox during repairs"
    static let foxPreview = "Run Preview"
    static let foxPreviewHelp = "Preview the animation. Your sound stays on."
    static let foxDetail = "Press the preview button....you know you want to..."
    static let foxDisabledDetail = "You turned off my cute little running fennec fox...🥺"
    static let foxReducedMotion = "The fox stays off while Reduce Motion is enabled in macOS."

    static func foxDescription(enabled: Bool, reduceMotion: Bool) -> String {
        if !enabled { return foxDisabledDetail }
        return reduceMotion ? foxReducedMotion : foxDetail
    }

    // MARK: Prompted repair

    static let promptTitle = "Fennec heard crackling."
    static let promptConsequence = "Repairing stops all sound on this Mac."
    static let promptRepairTitle = "Repair Audio"
    static let promptDismissTitle = "Not now"

    static func promptMessage(deviceName: String) -> String {
        let device = deviceName.isEmpty ? "your speakers" : deviceName
        return "Crackling on \(device). \(promptConsequence)"
    }

    // MARK: Numbers

    /// Durations the way an engineer reads them: precise when small, coarse
    /// when large. `0.84 s`, `1.2 s`, `12 s`.
    ///
    /// No product surface calls this any more (T-043): banners, receipts and
    /// the Activity window do not speak in seconds. It is kept, and kept
    /// tested, for the event log and for anything diagnostic that wants a
    /// consistent format. Do not put it back into user-facing copy.
    static func duration(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value < 1 { return String(format: "%.2f s", value) }
        if value < 10 { return String(format: "%.1f s", value) }
        return String(format: "%.0f s", value)
    }

    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value) \(value == 1 ? singular : plural)"
    }

    // MARK: What happened

    /// The cause clause: what Fennec heard, on which speakers. Always a
    /// complete sentence so it can lead a notification body.
    ///
    /// Named from the user's side of the glass. They did not observe an
    /// overload count inside a real-time thread, they heard their music go
    /// wrong, and the device name is the only technical noun here because it
    /// is the one they chose themselves in Sound settings.
    static func cause(for record: RepairRecord) -> String {
        let device = record.deviceName.isEmpty ? "your speakers" : record.deviceName

        switch record.signal {
        case .ioStoppedAbnormally:
            return "Sound cut out on \(device)."

        case .processorOverload:
            if record.signalCount <= 1 {
                return "Crackling on \(device)."
            }
            return "Repeated crackling on \(device)."

        case nil:
            return "You asked for a reset on \(device)."
        }
    }

    /// The result clause: what Fennec did about it.
    static func outcome(for record: RepairRecord) -> String {
        record.succeeded ? "Fennec fixed it." : record.message
    }

    // MARK: The primary button

    /// What the popover's one big button is doing right now.
    ///
    /// `working` deliberately covers both halves of a manual repair, the
    /// safety scan and the restart itself. They used to read as two separate
    /// sentences, because before the button changed shape on press there was
    /// nothing else to prove the click had landed. The pressed state and the
    /// haptic do that job now, so the button can say the one thing the user
    /// cares about instead of narrating its own internals.
    enum PrimaryPhase: String, CaseIterable, Sendable {
        case idle
        case working
        case repaired
    }

    static func primaryButtonTitle(for phase: PrimaryPhase) -> String {
        switch phase {
        case .idle: return "Repair Audio Now"
        case .working: return "Repairing…"
        case .repaired: return repairedTitle
        }
    }

    /// Kept beside the title so the two can never drift: a check mark next to
    /// "Repairing…" would be a lie for as long as it was on screen.
    static func primaryButtonSymbol(for phase: PrimaryPhase) -> String {
        switch phase {
        case .idle, .working: return "wrench.and.screwdriver.fill"
        case .repaired: return "checkmark.circle.fill"
        }
    }

    // MARK: Notifications

    /// The heads-up posted once the automatic path passes its safety checks,
    /// immediately before the restart. The result banner replaces it.
    static func repairStartingTitle() -> String {
        "Crackle detected"
    }

    static func repairStartingBody() -> String {
        "Resetting speakers..."
    }

    /// One line, and the same line whether Fennec caught it or the user
    /// pressed the button. Whether the repair was automatic is Fennec's
    /// business, not news.
    ///
    /// The exact words are shared with the button's result phase and with
    /// the manual receipt (T-044). Three surfaces can report the same event
    /// within seconds of each other: the banner, the button the user is
    /// still looking at, and the row in Activity. Three different phrasings
    /// for one outcome reads as three outcomes.
    static func notificationTitle(for record: RepairRecord) -> String {
        record.succeeded ? repairedTitle : "Fennec could not fix the crackle"
    }

    /// The one sentence for "it worked", used everywhere it is said.
    /// Changing it here changes the banner, the button, and the receipt
    /// together, which is the point.
    static let repairedTitle = "Donesies"

    /// A successful repair has an empty body on purpose. The title already
    /// says the only thing the user wanted to know, and a second line
    /// restating it in longer words is a banner nobody finishes reading.
    ///
    /// A failure still gets a body, because that is the case where there is
    /// something left for the user to do.
    static func notificationBody(for record: RepairRecord) -> String {
        record.succeeded ? "" : record.message
    }

    // MARK: The menu receipt

    /// Short enough for a 384 pt popover row.
    ///
    /// The wording still tracks the *outcome*, not the call's return value
    /// (rule 9). The instant a repair finishes, the only established fact is
    /// that the reset went through; "fixed" is a claim about the next minute,
    /// and `pending` says so without pretending otherwise.
    static func receiptHeadline(for record: RepairRecord) -> String {
        switch record.outcome {
        case .failed:
            return "Repair failed"
        case .pending:
            return "Repaired · listening for it to come back"
        case .returned:
            return "Repaired, but the crackle came back"
        case .held:
            return record.trigger == .automatic ? "Caught and fixed" : repairedTitle
        }
    }

    static func receiptDetail(for record: RepairRecord) -> String {
        switch record.outcome {
        case .failed:
            return record.message
        case .returned:
            return "\(cause(for: record)) The repair did not make it stay gone."
        case .pending, .held:
            return cause(for: record)
        }
    }

    /// The banner that replaces "Fennec fixed your audio" when it turns out
    /// not to have. Same notification identifier, so it corrects itself in
    /// place rather than stacking a contradiction underneath.
    static func faultReturnedTitle(for record: RepairRecord) -> String {
        "The crackle came back"
    }

    static func faultReturnedBody(for record: RepairRecord) -> String {
        "Fennec repaired \(record.deviceName.isEmpty ? "your speakers" : record.deviceName) "
            + "and the crackling returned. Something else is causing it."
    }

    // MARK: The helper blocker

    /// Why an automatic repair could not use the helper, in terms of what
    /// the user can actually do about it. "Not enabled" told a person who
    /// had just approved the helper that they had not, which is worse than
    /// no message at all.
    static func helperBlocker(for state: RepairHelperState) -> String {
        switch state {
        case .awaitingApproval:
            return "macOS is waiting for you to allow Fennec under Login Items & Extensions."
        case .enabled:
            return "The repair helper is enabled but did not answer, and rebuilding its "
                + "registration has not brought it back. If it stays silent, switch Fennec "
                + "off and on under Login Items & Extensions."
        case .notConfigured:
            return "The automatic repair helper is not enabled."
        case .unavailable(let message):
            return message
        }
    }

    // MARK: The stall advisory

    /// The banner for the failure Fennec cannot fix: playback starving under
    /// system load. Named precisely so nobody reaches for Repair Audio Now
    /// expecting it to help.
    static func stallAdvisoryTitle() -> String {
        "Audio is stalling, not crackling"
    }

    /// The load average and the memory-pressure level are gone from the
    /// banner (T-043): "load 1.47 per core" is a number the reader either
    /// already knows how to get or cannot use. Both are still recorded in
    /// the event log alongside this advisory, where a technical reader will
    /// look for them.
    static func stallAdvisoryBody(for advisory: StallAdvisory) -> String {
        let minutes = max(1, Int(advisory.windowSeconds / 60))
        return "Your sound stopped and started "
            + count(advisory.stopCount, "time", "times")
            + " in \(count(minutes, "minute", "minutes")). "
            + "This Mac is working too hard to keep up. "
            + "That is not the fault Fennec repairs, and repairing will not help. "
            + "Heavy apps, backups, or sync clients are the likely cause."
    }

    // MARK: Running totals

    /// The line under the counter. Deadpan, and true even at zero.
    static func summaryLine(for summary: RepairSummary, now: Date = Date()) -> String {
        guard summary.held > 0 else {
            return "No repairs yet. Fennec is listening."
        }
        let repairs = count(summary.held, "repair", "repairs")
        guard let first = summary.firstDate else { return repairs }

        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        let sinceDay = Calendar.current.isDate(first, inSameDayAs: now)
            ? "today"
            : "since \(formatter.string(from: first))"
        return "\(repairs) \(sinceDay)."
    }

    /// The one number that makes the value obvious at a glance.
    static func headlineNumber(for summary: RepairSummary) -> String {
        "\(summary.held)"
    }
}
