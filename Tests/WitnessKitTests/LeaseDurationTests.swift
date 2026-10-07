import Foundation
import XCTest
@testable import WitnessKit

final class LeaseDurationTests: XCTestCase {
    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruDurationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("leases.duckdb")
    }

    private func grant(_ reply: LeaseReply) throws -> LeaseGrant {
        XCTAssertEqual(reply.status, 200)
        return try JSONDecoder().decode(LeaseGrant.self, from: reply.body)
    }

    func testEachServiceUsesItsOwnLengthAndOutOfRangeLengthsAreRejected() async throws {
        let clock = TestClock(0)
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let media = try grant(await store.apply(.acquire, request: LeaseRequest(clusterID: "media", nodeID: "a", term: 0), leaseDuration: 120))
        XCTAssertEqual(media.expiresInSeconds, 120)
        let bot = try grant(await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "a", term: 0)))
        XCTAssertEqual(bot.expiresInSeconds, LeaseStore.leaseDuration)
        clock.advance(60)
        let blocked = await store.apply(.acquire, request: LeaseRequest(clusterID: "media", nodeID: "b", term: 0), leaseDuration: 120)
        XCTAssertEqual(blocked.status, 409)
        let expired = try grant(await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "b", term: 0)))
        XCTAssertEqual(expired.ownerNodeID, "b")
        for invalid in [0.0, 9.0, 301.0, .infinity] {
            let rejected = await store.apply(.acquire, request: LeaseRequest(clusterID: "other", nodeID: "a", term: 0), leaseDuration: invalid)
            XCTAssertEqual(rejected.status, 400)
        }
    }

    func testRenewalAppliesANewLengthAndRestartWaitsForTheLongestGrant() async throws {
        let url = try location(), clock = TestClock(0)
        var store: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        let first = try grant(await store!.apply(.acquire, request: LeaseRequest(clusterID: "media", nodeID: "a", term: 0)))
        let renewed = try grant(await store!.apply(.renew, request: LeaseRequest(clusterID: "media", nodeID: "a", term: first.term), leaseDuration: 180))
        XCTAssertEqual(renewed.expiresInSeconds, 180)
        _ = await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "a", term: 0))
        store = nil
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        let recovering = try await restarted.snapshot().recoverySeconds
        XCTAssertEqual(recovering, 180)
        clock.advance(31)
        let stillRecovering = await restarted.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "b", term: 0))
        XCTAssertEqual(stillRecovering.status, 503)
        clock.advance(150)
        let granted = await restarted.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "b", term: 0))
        XCTAssertEqual(granted.status, 200)
    }

    func testABusyServiceCannotEvictAnotherServicesHistory() async throws {
        let clock = TestClock(0)
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        _ = await store.apply(.acquire, request: LeaseRequest(clusterID: "quiet", nodeID: "a", term: 0))
        _ = await store.apply(.release, request: LeaseRequest(clusterID: "quiet", nodeID: "a", term: 1))
        for index in 0..<(LeaseStore.eventsKeptPerService + 20) {
            let node = "n\(index % 2)"
            let reply = await store.apply(.acquire, request: LeaseRequest(clusterID: "busy", nodeID: node, term: 0))
            let term = try grant(reply).term
            _ = await store.apply(.release, request: LeaseRequest(clusterID: "busy", nodeID: node, term: term))
        }
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.events.filter { $0.clusterID == "quiet" }.count, 2)
        XCTAssertEqual(snapshot.events.filter { $0.clusterID == "busy" }.count, LeaseStore.eventsShownPerService)
        let stored = try await store.makeSnapshot()
        XCTAssertEqual(stored.events.filter { $0.clusterID == "busy" }.count, LeaseStore.eventsKeptPerService)
        XCTAssertEqual(stored.events.filter { $0.clusterID == "quiet" }.count, 2)
    }
}
