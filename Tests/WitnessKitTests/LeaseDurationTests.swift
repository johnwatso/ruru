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

    func testShorterRenewalCannotInvalidateAnEarlierGrantWhenItsResponseIsLost() async throws {
        let url = try location(), clock = TestClock(0)
        var store: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        let first = try grant(await store!.apply(.acquire,
            request: LeaseRequest(clusterID: "bot", nodeID: "a", term: 0), leaseDuration: 300))
        clock.advance(5)
        // A still trusts its 300-second grant if this response never reaches it.
        let shorter = try grant(await store!.apply(.renew,
            request: LeaseRequest(clusterID: "bot", nodeID: "a", term: first.term), leaseDuration: 10))
        XCTAssertEqual(shorter.expiresInSeconds, 295)
        clock.advance(11)
        let blocked = await store!.apply(.acquire,
            request: LeaseRequest(clusterID: "bot", nodeID: "b", term: 0), leaseDuration: 10)
        XCTAssertEqual(blocked.status, 409)
        // Restart must retain the outstanding long permission too.
        store = nil
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        let recovery = try await restarted.snapshot().recoverySeconds
        XCTAssertEqual(recovery, 295)
        clock.advance(295)
        let successor = try grant(await restarted.apply(.acquire,
            request: LeaseRequest(clusterID: "bot", nodeID: "b", term: 0), leaseDuration: 10))
        XCTAssertGreaterThan(successor.term, first.term)
        XCTAssertEqual(successor.expiresInSeconds, 10)
    }

    func testShorterLengthTakesEffectAfterEarlierPermissionAgesOut() async throws {
        let clock = TestClock(0)
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let first = try grant(await store.apply(.acquire,
            request: LeaseRequest(clusterID: "bot", nodeID: "a", term: 0), leaseDuration: 30))
        clock.advance(5)
        let shortened = try grant(await store.apply(.renew,
            request: LeaseRequest(clusterID: "bot", nodeID: "a", term: first.term), leaseDuration: 10))
        XCTAssertEqual(shortened.expiresInSeconds, 25)
        clock.advance(20)
        let settled = try grant(await store.apply(.renew,
            request: LeaseRequest(clusterID: "bot", nodeID: "a", term: first.term), leaseDuration: 10))
        XCTAssertEqual(settled.expiresInSeconds, 10)
        clock.advance(10)
        let successor = try grant(await store.apply(.acquire,
            request: LeaseRequest(clusterID: "bot", nodeID: "b", term: 0), leaseDuration: 10))
        XCTAssertGreaterThan(successor.term, first.term)
    }

    func testDamagedStoredDurationFailsClosedOnRestart() async throws {
        for invalid in ["5", "301", "0", "-1"] {
            let url = try location()
            var store: LeaseStore? = try LeaseStore(databaseURL: url)
            _ = await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "a", term: 0))
            try await store!.executeStorageSQL("UPDATE leases SET duration=\(invalid)")
            store = nil
            XCTAssertThrowsError(try LeaseStore(databaseURL: url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
