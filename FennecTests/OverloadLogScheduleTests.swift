import XCTest

final class OverloadLogScheduleTests: XCTestCase {
    private let epoch = Date(timeIntervalSinceReferenceDate: 1_000_000)

    // MARK: Schedule

    func testNoQueryWhileDeviceIsSilent() {
        XCTAssertNil(OverloadLogSchedule.queryInterval(deviceRunning: false, quietFor: 0))
        XCTAssertNil(OverloadLogSchedule.queryInterval(deviceRunning: false, quietFor: .infinity))
        XCTAssertFalse(OverloadLogSchedule.queryIsDue(
            deviceRunning: false,
            now: epoch,
            lastQuery: nil,
            lastOverloadSeen: epoch.addingTimeInterval(-1)
        ))
    }

    func testFirstQueryRunsOnFirstRunningTick() {
        XCTAssertTrue(OverloadLogSchedule.queryIsDue(
            deviceRunning: true,
            now: epoch,
            lastQuery: nil,
            lastOverloadSeen: nil
        ))
    }

    func testHealthyPlaybackUsesTheSlowInterval() {
        XCTAssertEqual(
            OverloadLogSchedule.queryInterval(deviceRunning: true, quietFor: .infinity),
            OverloadLogSchedule.watch
        )
        XCTAssertFalse(OverloadLogSchedule.queryIsDue(
            deviceRunning: true,
            now: epoch,
            lastQuery: epoch.addingTimeInterval(-OverloadLogSchedule.watch + 1),
            lastOverloadSeen: nil
        ))
        XCTAssertTrue(OverloadLogSchedule.queryIsDue(
            deviceRunning: true,
            now: epoch,
            lastQuery: epoch.addingTimeInterval(-OverloadLogSchedule.watch),
            lastOverloadSeen: nil
        ))
    }

    func testRecentOverloadsTightenTheInterval() {
        XCTAssertEqual(
            OverloadLogSchedule.queryInterval(deviceRunning: true, quietFor: 0),
            OverloadLogSchedule.fault
        )
        XCTAssertTrue(OverloadLogSchedule.queryIsDue(
            deviceRunning: true,
            now: epoch,
            lastQuery: epoch.addingTimeInterval(-OverloadLogSchedule.fault),
            lastOverloadSeen: epoch.addingTimeInterval(-30)
        ))
    }

    /// A playback stall is the device stopping — the grace window keeps
    /// queries flowing through short silences so the stop/start churn is
    /// still observed.
    func testRecentRunningExtendsQueriesThroughASilence() {
        XCTAssertTrue(OverloadLogSchedule.queryIsDue(
            deviceRunning: false,
            now: epoch,
            lastQuery: epoch.addingTimeInterval(-OverloadLogSchedule.watch),
            lastOverloadSeen: nil,
            lastRunningSeen: epoch.addingTimeInterval(-(OverloadLogSchedule.runningGrace - 1))
        ))
        XCTAssertFalse(OverloadLogSchedule.queryIsDue(
            deviceRunning: false,
            now: epoch,
            lastQuery: epoch.addingTimeInterval(-OverloadLogSchedule.watch),
            lastOverloadSeen: nil,
            lastRunningSeen: epoch.addingTimeInterval(-OverloadLogSchedule.runningGrace)
        ))
    }

    func testFaultIntervalLapsesBackToWatch() {
        XCTAssertEqual(
            OverloadLogSchedule.queryInterval(
                deviceRunning: true,
                quietFor: OverloadLogSchedule.faultLingers
            ),
            OverloadLogSchedule.watch
        )
    }

    /// The poll interval must never decide whether a threshold is met — only
    /// the fault's own timing may. Two events 5 s apart satisfy Balanced's
    /// "2 within 8 s" even when the second one is reported by a poll that
    /// runs 10 s after the first, because the engine sees true event dates.
    func testSlowPollingCannotStarveADetectionWindow() {
        let engine = DetectionEngine()
        let first = epoch
        let second = epoch.addingTimeInterval(5)

        XCTAssertNil(engine.ingest(
            logBatch(eventDates: [first]),
            sensitivity: .balanced
        ))
        let decision = engine.ingest(
            logBatch(eventDates: [second]),
            sensitivity: .balanced
        )
        XCTAssertEqual(decision?.signal, .processorOverload)
        XCTAssertEqual(decision?.signalCount, 2)
        XCTAssertEqual(decision?.elapsedSeconds ?? 0, 5, accuracy: 0.001)
    }

    /// The converse: events genuinely too far apart for the window stay
    /// undetected even when one poll delivers them together.
    func testTrueEventSpacingStillGatesDetection() {
        let engine = DetectionEngine()
        let batch = logBatch(eventDates: [epoch, epoch.addingTimeInterval(9)])
        XCTAssertNil(engine.ingest(batch, sensitivity: .balanced))
    }

    // MARK: The activity trace

    func testAudioTightensTheTickAndSilenceRelaxesIt() {
        XCTAssertEqual(
            OverloadLogSchedule.tickInterval(recentlyRunning: true),
            OverloadLogSchedule.activityTick
        )
        XCTAssertEqual(
            OverloadLogSchedule.tickInterval(recentlyRunning: false),
            OverloadLogSchedule.tick
        )
        XCTAssertLessThan(OverloadLogSchedule.activityTick, OverloadLogSchedule.tick)
    }

    func testContinuousSamplesMergeIntoOneSegment() {
        let samples = (0..<5).map { epoch.addingTimeInterval(Double($0)) }
        let segments = AudioActivitySegments.merged(sampleDates: samples)
        XCTAssertEqual(segments, [epoch...epoch.addingTimeInterval(4)])
    }

    func testAPlaybackGapSplitsTheRibbon() {
        // Three seconds of music, a two-second dropout, two more seconds.
        let samples = [0, 1, 2, 5, 6].map { epoch.addingTimeInterval(Double($0)) }
        let segments = AudioActivitySegments.merged(sampleDates: samples)
        XCTAssertEqual(segments, [
            epoch...epoch.addingTimeInterval(2),
            epoch.addingTimeInterval(5)...epoch.addingTimeInterval(6)
        ])
    }

    func testOneMissedSampleDoesNotFakeADropout() {
        // The merge window is wider than one tick, so a single late or
        // coalesced sample cannot split the ribbon.
        let samples = [0, 1, 2.5].map { epoch.addingTimeInterval($0) }
        XCTAssertEqual(AudioActivitySegments.merged(sampleDates: samples).count, 1)
    }

    func testUnsortedSamplesStillMergeCorrectly() {
        let samples = [2, 0, 1].map { epoch.addingTimeInterval(Double($0)) }
        XCTAssertEqual(
            AudioActivitySegments.merged(sampleDates: samples),
            [epoch...epoch.addingTimeInterval(2)]
        )
    }

    // MARK: Grouping

    func testMarkersCountExactly() {
        let markers = [epoch, epoch.addingTimeInterval(0.094), epoch.addingTimeInterval(1.2)]
        let noise = [epoch.addingTimeInterval(0.001), epoch.addingTimeInterval(0.002)]
        XCTAssertEqual(OverloadLogGrouper.eventDates(markers: markers, auxiliary: noise), markers)
    }

    func testMarkersAreSorted() {
        let markers = [epoch.addingTimeInterval(1), epoch]
        XCTAssertEqual(
            OverloadLogGrouper.eventDates(markers: markers, auxiliary: []),
            [epoch, epoch.addingTimeInterval(1)]
        )
    }

    func testAuxiliaryLinesClusterIntoBursts() {
        // Two events, each writing three cause lines within a millisecond.
        let auxiliary = [
            epoch, epoch.addingTimeInterval(0.0004), epoch.addingTimeInterval(0.001),
            epoch.addingTimeInterval(0.094), epoch.addingTimeInterval(0.0944), epoch.addingTimeInterval(0.095)
        ]
        let events = OverloadLogGrouper.eventDates(markers: [], auxiliary: auxiliary)
        XCTAssertEqual(events, [epoch, epoch.addingTimeInterval(0.094)])
    }

    func testNoLinesMeansNoEvents() {
        XCTAssertTrue(OverloadLogGrouper.eventDates(markers: [], auxiliary: []).isEmpty)
    }

    // MARK: The synthesized batch drives the engine like a listener batch

    private func logBatch(eventDates: [Date]) -> AudioSignalBatch {
        AudioSignalBatch(
            date: eventDates.max() ?? epoch,
            overloads: UInt64(eventDates.count),
            abnormalStops: 0,
            defaultOutputChanges: 0,
            sampleRateChanges: 0,
            deviceStateChanges: 0,
            serviceRestarts: 0,
            device: .unavailable,
            source: .systemLog,
            overloadDates: eventDates
        )
    }

    func testLogSourcedBatchTripsBalancedDetection() {
        let engine = DetectionEngine()
        let decision = engine.ingest(
            logBatch(eventDates: [epoch, epoch.addingTimeInterval(0.1)]),
            sensitivity: .balanced
        )
        XCTAssertEqual(decision?.signal, .processorOverload)
        XCTAssertEqual(decision?.signalCount, 2)
    }

    func testSignalSourceDefaultsToListener() {
        let batch = AudioSignalBatch(
            date: epoch,
            overloads: 1,
            abnormalStops: 0,
            defaultOutputChanges: 0,
            sampleRateChanges: 0,
            deviceStateChanges: 0,
            serviceRestarts: 0,
            device: .unavailable
        )
        XCTAssertEqual(batch.source, .listener)
    }
}
