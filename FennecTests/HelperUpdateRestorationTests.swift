import XCTest

@MainActor
final class HelperUpdateRestorationTests: XCTestCase {
    private final class Fixture {
        var status: HelperRegistrationStatus = .enabled
        var replies = [true]
        var registrations = 0
        var pings = 0
        var pauses: [TimeInterval] = []
        var onRegister: (() -> Void)?
        var onPing: (() -> Void)?

        func restore() async -> HelperUpdateRestorationResult {
            await HelperUpdateRestoration.restore(
                status: { self.status },
                register: { self.registrations += 1; self.onRegister?() },
                ping: {
                    self.pings += 1
                    self.onPing?()
                    return self.replies.isEmpty ? false : self.replies.removeFirst()
                },
                pause: { self.pauses.append($0) }
            )
        }
    }

    func testApprovedAutomaticSetupSurvivesTemporaryPingFailures() async {
        let f = Fixture()
        f.replies = [false, false, true]
        let result = await f.restore()
        XCTAssertEqual(result, .enabled(reachable: true))
        XCTAssertFalse(result.needsPromptedMode)
        XCTAssertEqual(f.registrations, 0)
        XCTAssertEqual(f.pings, 3)
        XCTAssertEqual(f.pauses, [1, 1])
    }

    func testApprovedButSlowHelperDoesNotRevokeAutomaticChoice() async {
        let f = Fixture()
        f.replies = [false, false, false]
        let result = await f.restore()
        XCTAssertEqual(result, .enabled(reachable: false))
        XCTAssertFalse(result.needsPromptedMode)
        XCTAssertEqual(f.pings, 3)
    }

    func testApprovalRequiredFallsBackWithoutRegisteringOrPinging() async {
        let f = Fixture()
        f.status = .requiresApproval
        let result = await f.restore()
        XCTAssertTrue(result.needsPromptedMode)
        XCTAssertEqual(result, .requiresApproval)
        XCTAssertEqual(f.registrations, 0)
        XCTAssertEqual(f.pings, 0)
    }

    func testLostRegistrationIsRestoredWithPriorApproval() async {
        let f = Fixture()
        f.status = .notRegistered
        f.onRegister = { f.status = .enabled }
        let result = await f.restore()
        XCTAssertEqual(result, .enabled(reachable: true))
        XCTAssertEqual(f.registrations, 1)
    }

    func testRegistrationThatRacesTeardownRetriesOnceAfterSettling() async {
        let f = Fixture()
        f.status = .notRegistered
        f.onRegister = { if f.registrations == 2 { f.status = .enabled } }
        let result = await f.restore()
        XCTAssertEqual(result, .enabled(reachable: true))
        XCTAssertEqual(f.registrations, 2)
        XCTAssertEqual(f.pauses, Array(repeating: 0.3, count: 5))
    }

    func testUnresolvedRegistrationHasBoundedRetriesAndFallsBack() async {
        let f = Fixture()
        f.status = .notRegistered
        let result = await f.restore()
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(result.needsPromptedMode)
        XCTAssertEqual(f.registrations, 2)
        XCTAssertEqual(f.pauses.count, 10)
        XCTAssertEqual(f.pings, 0)
    }

    func testApprovalLostDuringPingCannotCountAsSuccessfulRestoration() async {
        let f = Fixture()
        f.onPing = { f.status = .requiresApproval }
        let result = await f.restore()
        XCTAssertEqual(result, .requiresApproval)
        XCTAssertEqual(f.pings, 1)
        XCTAssertEqual(f.registrations, 0)
    }

    func testConcurrentRestoreAndLaunchHealerWaitForOneOperation() async {
        let gate = HelperUpdateRestorationGate()
        var resume: CheckedContinuation<HelperUpdateRestorationResult, Never>?
        var operations = 0
        let first = Task { await gate.restore {
            operations += 1
            return await withCheckedContinuation { resume = $0 }
        } }
        while resume == nil { await Task.yield() }
        XCTAssertTrue(gate.isRestoring)
        let second = Task { await gate.restore {
            operations += 1
            return .unavailable
        } }
        var healerRan = false
        let healer = Task {
            await gate.waitUntilFinished()
            healerRan = true
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(healerRan)
        XCTAssertEqual(operations, 1)
        resume?.resume(returning: .enabled(reachable: true))
        let firstResult = await first.value
        let secondResult = await second.value
        await healer.value
        XCTAssertEqual(firstResult, .enabled(reachable: true))
        XCTAssertEqual(secondResult, firstResult)
        XCTAssertTrue(healerRan)
        XCTAssertFalse(gate.isRestoring)
    }
}
