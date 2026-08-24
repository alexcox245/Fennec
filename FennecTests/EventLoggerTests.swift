import XCTest

/// The event log is Fennec's audit trail — the thing a user reads when they
/// want to know what a root helper did on their machine. It has to be
/// append-only, one JSON object per line, and it has to rotate.
final class EventLoggerTests: XCTestCase {
    private var directory = URL(fileURLWithPath: "/tmp")

    override func setUp() {
        super.setUp()
        directory = Fixture.temporaryDirectory("event-log")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeLogger() -> EventLogger {
        EventLogger(directory: directory)
    }

    private func waitForFlush(_ logger: EventLogger) {
        let flushed = expectation(description: "log flushed")
        logger.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
    }

    private func readLines() throws -> [String] {
        let contents = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
        return contents.split(separator: "\n").map(String.init)
    }

    func testAppendWritesOneJSONObjectPerLine() throws {
        let logger = makeLogger()
        logger.append(ActivityRecord(kind: .monitorStarted, summary: "Core Audio monitoring started."))
        logger.append(ActivityRecord(kind: .detection, summary: "Two signals in eight seconds."))
        waitForFlush(logger)

        let lines = try readLines()
        XCTAssertEqual(lines.count, 2)

        for line in lines {
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            )
            XCTAssertNotNil(object["kind"])
            XCTAssertNotNil(object["summary"])
            XCTAssertNotNil(object["date"])
        }
    }

    func testAppendPreservesEarlierEntries() throws {
        let logger = makeLogger()
        for index in 0..<20 {
            logger.append(ActivityRecord(kind: .signal, summary: "signal \(index)"))
        }
        waitForFlush(logger)

        let lines = try readLines()
        XCTAssertEqual(lines.count, 20)
        XCTAssertTrue(lines[0].contains("signal 0"))
        XCTAssertTrue(lines[19].contains("signal 19"))
    }

    func testRecordRoundTripsThroughJSON() throws {
        let record = ActivityRecord(
            kind: .repairSucceeded,
            summary: "Core Audio restarted successfully.",
            details: ["device": "MacBook Pro Speakers", "durationSeconds": "0.84"],
            date: Fixture.epoch
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(ActivityRecord.self, from: encoder.encode(record))
        XCTAssertEqual(decoded, record)
    }

    func testRotationMovesTheOldLogAsideAndStartsFresh() throws {
        // A 2 KB cap makes rotation observable without writing five megabytes.
        let logger = EventLogger(directory: directory, maximumLogSize: 2_048)
        for index in 0..<200 {
            logger.append(ActivityRecord(
                kind: .signal,
                summary: "Core Audio processor overload signal received. (\(index))"
            ))
        }
        waitForFlush(logger)

        let rotated = directory.appendingPathComponent("events.previous.jsonl")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "The log must roll over instead of growing without bound."
        )

        let activeSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: logger.logURL.path)[.size] as? NSNumber
        )
        XCTAssertLessThan(activeSize.uint64Value, 4_096)
    }

    func testLogURLLivesInsideTheGivenDirectory() {
        let logger = makeLogger()
        XCTAssertEqual(logger.logURL.deletingLastPathComponent().standardizedFileURL, directory.standardizedFileURL)
        XCTAssertEqual(logger.logURL.lastPathComponent, "events.jsonl")
    }
}
