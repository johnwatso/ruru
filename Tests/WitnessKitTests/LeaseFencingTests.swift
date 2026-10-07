import Foundation
import XCTest
@testable import WitnessKit

// Independently written Swift scenarios informed by etcd's fencing example.
// No upstream source is copied. See Documentation/LEASE_REFERENCES.md.
final class LeaseFencingTests: XCTestCase {
    private let cluster = "guarded-worker"
    private let token = String(repeating: "isolated-fencing-test-", count: 3)

    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuruFencingTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("leases.duckdb")
    }

    private func send(_ action: LeaseAction, to router: WitnessRouter, node: String,
                      term: Int64 = 0, clusterID: String? = nil, credential: String? = nil) async throws -> LeaseReply {
        await router.route(HTTPRequest(method: "POST", path: "/v1/lease/\(action.rawValue)",
            headers: ["authorization": "Bearer " + (credential ?? token)],
            body: try JSONEncoder().encode(LeaseRequest(clusterID: clusterID ?? cluster, nodeID: node, term: term))))
    }

    private func grant(_ reply: LeaseReply, file: StaticString = #filePath, line: UInt = #line) throws -> LeaseGrant {
        XCTAssertEqual(reply.status, 200, file: file, line: line)
        return try JSONDecoder().decode(LeaseGrant.self, from: reply.body)
    }

    private func assertWrite(_ resource: FencedTestResource, grant: LeaseGrant, value: String,
                             accepted: Bool, clusterID: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        let before = await resource.snapshot()
        let result = await resource.write(clusterID: clusterID ?? cluster, grant: grant, value: value)
        let after = await resource.snapshot()
        XCTAssertEqual(result, accepted, file: file, line: line)
        if accepted {
            XCTAssertEqual(after.term, grant.term, file: file, line: line)
            XCTAssertEqual(after.owner, grant.ownerNodeID, file: file, line: line)
            XCTAssertEqual(after.value, value, file: file, line: line)
        } else {
            XCTAssertEqual(after, before, "Rejected work must leave both data and fence unchanged", file: file, line: line)
        }
    }

    func testPausedOwnerCannotOverwriteSuccessorOrChangeItsLease() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let router = try WitnessRouter(store: store, clusterID: cluster, token: token)
        let resource = FencedTestResource(clusterID: cluster)
        let first = try grant(await send(.acquire, to: router, node: "server-a"))
        await assertWrite(resource, grant: first, value: "first owner's output", accepted: true)

        // A pauses with a pending write. B acquires exactly at A's expiry and
        // installs its newer fence before A's pending write is delivered.
        clock.advance(LeaseStore.leaseDuration)
        let second = try grant(await send(.acquire, to: router, node: "server-b"))
        XCTAssertGreaterThan(second.term, first.term)
        await assertWrite(resource, grant: second, value: "successor's output", accepted: true)
        await assertWrite(resource, grant: first, value: "delayed stale output", accepted: false)

        for action in [LeaseAction.renew, .release] {
            let stale = try await send(action, to: router, node: first.ownerNodeID, term: first.term)
            XCTAssertEqual(stale.status, 409)
        }
        let state = try await store.snapshot()
        XCTAssertEqual(state.leases.first?.ownerNodeID, second.ownerNodeID)
        XCTAssertEqual(state.leases.first?.term, second.term)
        XCTAssertEqual(state.leases.first?.remainingSeconds, LeaseStore.leaseDuration)
        let renewed = try grant(await send(.renew, to: router, node: second.ownerNodeID, term: second.term))
        XCTAssertEqual(renewed.term, second.term)
        await assertWrite(resource, grant: renewed, value: "successor's renewed output", accepted: true)
    }

    func testSameNodeReacquisitionStillFencesItsEarlierWork() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let router = try WitnessRouter(store: store, clusterID: cluster, token: token)
        let resource = FencedTestResource(clusterID: cluster)
        let first = try grant(await send(.acquire, to: router, node: "stable-node-id"))
        await assertWrite(resource, grant: first, value: "old run", accepted: true)
        clock.advance(LeaseStore.leaseDuration)
        let second = try grant(await send(.acquire, to: router, node: "stable-node-id", term: first.term))
        XCTAssertEqual(second.ownerNodeID, first.ownerNodeID)
        XCTAssertGreaterThan(second.term, first.term)
        await assertWrite(resource, grant: second, value: "new run", accepted: true)
        await assertWrite(resource, grant: first, value: "old run's pending output", accepted: false)
        for action in [LeaseAction.renew, .release] {
            let stale = try await send(action, to: router, node: first.ownerNodeID, term: first.term)
            XCTAssertEqual(stale.status, 409)
        }
    }

    func testAuthorityRestartRetainsTermsAndProtectsSuccessorsOutput() async throws {
        let url = try location()
        let clock = TestClock()
        let resource = FencedTestResource(clusterID: cluster)
        var original: WitnessRouter? = try WitnessRouter(
            store: LeaseStore(databaseURL: url, clock: clock.now), clusterID: cluster, token: token)
        let first = try grant(await send(.acquire, to: original!, node: "server-a", term: 40))
        await assertWrite(resource, grant: first, value: "before authority restart", accepted: true)
        original = nil
        clock.reset(0)
        let restarted = try WitnessRouter(
            store: LeaseStore(databaseURL: url, clock: clock.now), clusterID: cluster, token: token)
        let recovering = try await send(.acquire, to: restarted, node: "server-b")
        XCTAssertEqual(recovering.status, 503)
        clock.advance(LeaseStore.leaseDuration)
        let expired = try await send(.renew, to: restarted, node: first.ownerNodeID, term: first.term)
        XCTAssertEqual(expired.status, 409)
        let second = try grant(await send(.acquire, to: restarted, node: "server-b"))
        XCTAssertGreaterThan(second.term, first.term)
        await assertWrite(resource, grant: second, value: "after authority restart", accepted: true)
        await assertWrite(resource, grant: first, value: "delayed pre-restart output", accepted: false)
    }

    func testFencesAreScopedToEachServiceRatherThanComparedGlobally() async throws {
        let otherCluster = "independent-worker"
        let otherToken = String(repeating: "other-isolated-token-", count: 3)
        let store = try LeaseStore(databaseURL: location(), clock: TestClock().now)
        let router = try WitnessRouter(store: store, services: [
            WitnessServiceCredential(clusterID: cluster, token: token),
            WitnessServiceCredential(clusterID: otherCluster, token: otherToken)
        ])
        let first = try grant(await send(.acquire, to: router, node: "server-a", term: 100))
        let second = try grant(await send(.acquire, to: router, node: "server-b",
            clusterID: otherCluster, credential: otherToken))
        XCTAssertLessThan(second.term, first.term)
        let firstResource = FencedTestResource(clusterID: cluster)
        let secondResource = FencedTestResource(clusterID: otherCluster)
        await assertWrite(firstResource, grant: first, value: "first service", accepted: true)
        await assertWrite(secondResource, grant: second, value: "second service", accepted: true, clusterID: otherCluster)
        await assertWrite(secondResource, grant: first, value: "cross-service output", accepted: false)
        await assertWrite(secondResource, grant: second, value: "second service continues", accepted: true, clusterID: otherCluster)
    }

    func testTermComparisonAloneCannotDetectExpiryBeforeSuccessorReachesResource() async throws {
        let clock = TestClock()
        let router = try WitnessRouter(store: LeaseStore(databaseURL: location(), clock: clock.now),
                                       clusterID: cluster, token: token)
        let resource = FencedTestResource(clusterID: cluster)
        let first = try grant(await send(.acquire, to: router, node: "server-a"))
        await assertWrite(resource, grant: first, value: "initial output", accepted: true)
        clock.advance(LeaseStore.leaseDuration)
        let second = try grant(await send(.acquire, to: router, node: "server-b"))
        let expired = try await send(.renew, to: router, node: first.ownerNodeID, term: first.term)
        XCTAssertEqual(expired.status, 409)
        // This deliberately bypasses the client's required local deadline.
        // The resource has not seen B's term yet, so its fence cannot reject A.
        await assertWrite(resource, grant: first, value: "expired output before new fence", accepted: true)
        await assertWrite(resource, grant: second, value: "new fence installed", accepted: true)
        await assertWrite(resource, grant: first, value: "expired output after new fence", accepted: false)
    }
}

/// A single cooperating resource, isolated to these tests. Grants come only from
/// the test authority; this is neither authentication nor a production adapter.
/// The actor performs comparison and mutation together without a suspension.
/// Its in-memory fence survives an authority restart, not a resource restart.
private actor FencedTestResource {
    struct State: Equatable, Sendable {
        var term: Int64 = 0
        var owner: String = ""
        var value: String = ""
    }

    private let clusterID: String
    private var state = State()

    init(clusterID: String) { self.clusterID = clusterID }

    func write(clusterID: String, grant: LeaseGrant, value: String) -> Bool {
        guard clusterID == self.clusterID, grant.term > 0,
              grant.term >= state.term,
              grant.term != state.term || grant.ownerNodeID == state.owner else { return false }
        state = State(term: grant.term, owner: grant.ownerNodeID, value: value)
        return true
    }

    func snapshot() -> State { state }
}
