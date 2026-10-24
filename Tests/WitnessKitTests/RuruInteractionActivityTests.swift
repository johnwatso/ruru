import Combine
import WitnessKit
import XCTest

final class RuruInteractionActivityTests: XCTestCase {
    @MainActor
    func testFiveMinuteDeadlineAndInteractionResumeWithoutPollPublications() {
        let start = ContinuousClock.now
        var elapsed = Duration.zero
        let activity = RuruInteractionActivity(now: { start.advanced(by: elapsed) })
        defer { activity.stopMonitoring() }
        var changes: [Bool] = []
        let subscription = activity.$leaseAnimationsEnabled.sink { changes.append($0) }
        defer { subscription.cancel() }

        elapsed = .seconds(299)
        XCTAssertEqual(activity.refreshIdleState(), .seconds(1))
        elapsed = .seconds(300)
        XCTAssertNil(activity.refreshIdleState())
        XCTAssertFalse(activity.leaseAnimationsEnabled)
        for _ in 0..<10_000 { XCTAssertNil(activity.refreshIdleState()) }
        XCTAssertEqual(changes, [true, false])

        activity.recordInteraction()
        XCTAssertTrue(activity.leaseAnimationsEnabled)
        // Frequent pointer/keyboard events do not republish an unchanged flag.
        for _ in 0..<10_000 { activity.recordInteraction() }
        XCTAssertEqual(changes, [true, false, true])
        elapsed = .seconds(599)
        XCTAssertEqual(activity.refreshIdleState(), .seconds(1))
        elapsed = .seconds(600)
        XCTAssertNil(activity.refreshIdleState())
        XCTAssertEqual(changes, [true, false, true, false])
    }

    @MainActor
    func testSleepingTaskActuallyPausesResumesAndCancels() async throws {
        let activity = RuruInteractionActivity(timeout: .milliseconds(50))
        defer { activity.stopMonitoring() }
        let paused = expectation(description: "inactivity pauses animations")
        let subscription = activity.$leaseAnimationsEnabled.dropFirst().filter { !$0 }.prefix(1)
            .sink { _ in paused.fulfill() }
        defer { subscription.cancel() }
        activity.recordInteraction()
        await fulfillment(of: [paused], timeout: 2)
        XCTAssertFalse(activity.leaseAnimationsEnabled)
        activity.recordInteraction()
        XCTAssertTrue(activity.leaseAnimationsEnabled)
        activity.stopMonitoring()
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(activity.leaseAnimationsEnabled, "stopped timeout must not fire later")
    }

    @MainActor
    func testInputBeforeIdleExtendsTheDeadline() {
        let start = ContinuousClock.now
        var elapsed = Duration.zero
        let activity = RuruInteractionActivity(now: { start.advanced(by: elapsed) })
        defer { activity.stopMonitoring() }
        elapsed = .seconds(299)
        activity.recordInteraction()
        elapsed = .seconds(300)
        XCTAssertEqual(activity.refreshIdleState(), .seconds(299))
        XCTAssertTrue(activity.leaseAnimationsEnabled)
        elapsed = .seconds(599)
        XCTAssertNil(activity.refreshIdleState())
        XCTAssertFalse(activity.leaseAnimationsEnabled)
    }

    func testIdleSymbolTracksRenewalWarningsExpiryAndRecovery() {
        func state(_ remaining: Double, recovering: Bool = false) -> WitnessLeasePresentation {
            .init(lease: .init(clusterID: "isolated", ownerNodeID: "node", term: 7,
                               remainingSeconds: remaining), leaseSeconds: 30, recovering: recovering)
        }
        XCTAssertEqual(state(30), .renewing)
        XCTAssertEqual(state(10), .renewing)
        XCTAssertEqual(state(9), .late)
        XCTAssertEqual(state(5), .critical)
        XCTAssertEqual(state(0), .unowned)
        XCTAssertEqual(state(30, recovering: true), .recovering)
        XCTAssertEqual(WitnessLeasePresentation(lease: nil, leaseSeconds: 30, recovering: false), .unowned)
        XCTAssertEqual(state(28).symbolName, "arrow.trianglehead.2.clockwise.rotate.90.circle.fill")
        XCTAssertEqual(state(28).idleCaption, "In Sync")
        XCTAssertNotEqual(state(4).symbolName, state(28).symbolName)
        XCTAssertNotEqual(state(0).idleCaption, "In Sync")
    }
}
