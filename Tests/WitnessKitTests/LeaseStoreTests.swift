import Foundation
import XCTest
@testable import WitnessKit

final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: Double
    init(_ time: Double = 1000) { self.time = time }
    func now() -> Double { lock.withLock { time } }
    func advance(_ seconds: Double) { lock.withLock { time += seconds } }
    func reset(_ value: Double) { lock.withLock { time = value } }
}

final class LeaseStoreTests: XCTestCase {
    private func location() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMeshWitnessTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("leases.duckdb")
    }

    private func request(_ node: String = "primary", term: Int64 = 0) -> LeaseRequest {
        LeaseRequest(clusterID: "bot", nodeID: node, term: term)
    }

    private func grant(_ reply: LeaseReply) throws -> LeaseGrant {
        XCTAssertEqual(reply.status, 200)
        return try JSONDecoder().decode(LeaseGrant.self, from: reply.body)
    }

    func testLegacyRequestsAndOptionalNamesKeepNodeIDAsLeaseIdentity() async throws {
        let old = try JSONDecoder().decode(LeaseRequest.self, from: Data(#"{"clusterID":"bot","nodeID":"primary-id","term":0}"#.utf8))
        XCTAssertNil(old.nodeName)
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let original = try grant(await store.apply(.acquire, request: old))
        clock.advance(5)
        let renamed = try grant(await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary-id", term: 0, nodeName: " Office Mac ")))
        XCTAssertEqual(renamed.ownerNodeID, original.ownerNodeID)
        XCTAssertEqual(renamed.term, original.term)
        XCTAssertEqual(renamed.expiresInSeconds, 25)
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.leases.first?.ownerNodeName, "Office Mac")
        XCTAssertEqual(snapshot.events.first?.nodeName, "Office Mac")
        let conflicting = await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "backup-id", term: 0, nodeName: "Office Mac"))
        XCTAssertEqual(conflicting.status, 409)
        let finalState = try await store.snapshot()
        XCTAssertEqual(finalState.leases.first?.ownerNodeID, "primary-id")
    }

    func testFailedAndInvalidNameUpdatesDoNotReplaceAcceptedNames() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let original = try grant(await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 0, nodeName: "Primary Mac")))
        let denied = await store.apply(.renew, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: original.term + 1, nodeName: "Wrong name"))
        XCTAssertEqual(denied.status, 409)
        for name in ["", "two\nlines", String(repeating: "x", count: 257)] {
            let accepted = await store.apply(.renew, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: original.term, nodeName: name))
            XCTAssertEqual(accepted.status, 200)
            let state = try await store.snapshot()
            XCTAssertEqual(state.leases.first?.ownerNodeName, "Primary Mac")
        }
        clock.advance(31)
        let expired = await store.apply(.renew, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: original.term, nodeName: "Expired name"))
        XCTAssertEqual(expired.status, 409)
        let state = try await store.snapshot()
        XCTAssertEqual(state.leases.first?.ownerNodeName, "Primary Mac")
    }

    func testNamesSurviveRestartWithoutRevivingOwnership() async throws {
        let url = try location()
        let clock = TestClock()
        var store: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        _ = await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 7, nodeName: "Home Mac"))
        store = nil
        clock.reset(0)
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        let state = try await restarted.snapshot()
        XCTAssertEqual(state.leases.first?.ownerNodeName, "Home Mac")
        XCTAssertEqual(state.events.first?.nodeName, "Home Mac")
        XCTAssertEqual(state.leases.first?.remainingSeconds, 0)
        XCTAssertEqual(state.recoverySeconds, 30)
    }

    func testMissingMetadataTableFailsClosedOnRestart() async throws {
        let url = try location()
        let clock = TestClock()
        var old: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        let original = try grant(await old!.apply(.acquire, request: request(term: 11)))
        _ = await old!.apply(.release, request: request(term: original.term))
        old = nil
        var damaged: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        try await damaged!.executeStorageSQL("DROP TABLE node_names")
        damaged = nil
        XCTAssertThrowsError(try LeaseStore(databaseURL: url, clock: clock.now))
    }

    func testOnlyOneConcurrentOwnerIsGranted() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let statuses = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for index in 0..<16 {
                group.addTask { await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "node-\(index)", term: 0)).status }
            }
            var values: [Int] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(statuses.filter { $0 == 200 }.count, 1)
        XCTAssertEqual(statuses.filter { $0 == 409 }.count, 15)
    }

    func testAcquireRetryDoesNotExtendLeaseOrChangeTerm() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let first = try grant(await store.apply(.acquire, request: request(term: 7)))
        clock.advance(5)
        let retry = try grant(await store.apply(.acquire, request: request(term: 7)))
        XCTAssertEqual(first.term, retry.term)
        XCTAssertEqual(retry.expiresInSeconds, 25)
        let other = await store.apply(.acquire, request: request("backup", term: 1000))
        XCTAssertEqual(other.status, 409)
    }

    func testRenewRequiresLiveMatchingOwnerAndTerm() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let first = try grant(await store.apply(.acquire, request: request()))
        let wrongOwner = await store.apply(.renew, request: request("backup", term: first.term))
        let wrongTerm = await store.apply(.renew, request: request(term: first.term - 1))
        XCTAssertEqual(wrongOwner.status, 409)
        XCTAssertEqual(wrongTerm.status, 409)
        clock.advance(20)
        let renewed = try grant(await store.apply(.renew, request: request(term: first.term)))
        XCTAssertEqual(renewed.expiresInSeconds, 30)
        clock.advance(30)
        let expired = await store.apply(.renew, request: request(term: first.term))
        XCTAssertEqual(expired.status, 409)
    }

    func testExpiryAllowsNewTermAndFencesFormerOwner() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let first = try grant(await store.apply(.acquire, request: request()))
        clock.advance(30)
        let second = try grant(await store.apply(.acquire, request: request("backup")))
        XCTAssertGreaterThan(second.term, first.term)
        let oldRenew = await store.apply(.renew, request: request(term: first.term))
        let oldRelease = await store.apply(.release, request: request(term: first.term))
        XCTAssertEqual(oldRenew.status, 409)
        XCTAssertEqual(oldRelease.status, 409)
    }

    func testReleasePreservesTermForNextOwner() async throws {
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: location(), clock: clock.now)
        let first = try grant(await store.apply(.acquire, request: request(term: 9)))
        let released = await store.apply(.release, request: request(term: first.term))
        XCTAssertEqual(released.status, 200)
        let second = try grant(await store.apply(.acquire, request: request("backup")))
        XCTAssertGreaterThan(second.term, first.term)
        let events = try await store.snapshot().events
        XCTAssertEqual(events.map(\.action), ["Acquired", "Released", "Acquired"])
    }

    func testRestartWithResetClockWaitsFullLeaseAndRetainsTerm() async throws {
        let url = try location()
        let clock = TestClock()
        var previous: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        let first = try grant(await previous!.apply(.acquire, request: request(term: 8)))
        previous = nil
        clock.reset(0)
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        let refused = await restarted.apply(.acquire, request: request("backup"))
        XCTAssertEqual(refused.status, 503)
        clock.advance(29)
        let stillRefused = await restarted.apply(.renew, request: request(term: first.term))
        XCTAssertEqual(stillRefused.status, 503)
        clock.advance(1)
        let staleRenewal = await restarted.apply(.renew, request: request(term: first.term))
        XCTAssertEqual(staleRenewal.status, 409)
        let second = try grant(await restarted.apply(.acquire, request: request("backup")))
        XCTAssertGreaterThan(second.term, first.term)
    }

    func testRepeatedRestartDuringQuarantineCannotSkipWaiting() async throws {
        let url = try location()
        let clock = TestClock()
        var store: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        _ = await store!.apply(.acquire, request: request())
        store = nil
        clock.reset(0)
        store = try LeaseStore(databaseURL: url, clock: clock.now)
        clock.advance(5)
        store = nil
        let third = try LeaseStore(databaseURL: url, clock: clock.now)
        clock.advance(25)
        let refused = await third.apply(.acquire, request: request("backup"))
        XCTAssertEqual(refused.status, 503)
        clock.advance(5)
        let accepted = await third.apply(.acquire, request: request("backup"))
        XCTAssertEqual(accepted.status, 200)
    }

    func testSecondProcessCannotOpenSameDatabase() async throws {
        let url = try location()
        let first = try LeaseStore(databaseURL: url)
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
        let reply = await first.apply(.acquire, request: request())
        XCTAssertEqual(reply.status, 200)
    }

    func testFailedGrantTransactionCannotReviveLeaseFromEarlierProcess() async throws {
        let url = try location()
        let clock = TestClock()
        var first: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        let original = try grant(await first!.apply(.acquire, request: request()))
        first = nil
        clock.reset(0)
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        clock.advance(30)
        // Force a failure after writing the next lease but before commit.
        try await restarted.executeStorageSQL("DROP TABLE events")
        let refused = await restarted.apply(.acquire, request: request("backup"))
        XCTAssertEqual(refused.status, 503)
        let staleRenewal = await restarted.apply(.renew, request: request(term: original.term))
        XCTAssertEqual(staleRenewal.status, 409)
    }

    func testTermExhaustionFailsClosedWithoutOverflowOrUnrenewableGrant() async throws {
        let store = try LeaseStore(databaseURL: location())
        let refused = await store.apply(.acquire, request: request(term: (1 << 62) - 1))
        XCTAssertEqual(refused.status, 503)
        let state = try await store.snapshot()
        XCTAssertTrue(state.leases.isEmpty)
    }

    func testInvalidIDsAndTermsAreRejected() async throws {
        let store = try LeaseStore(databaseURL: location())
        for request in [LeaseRequest(clusterID: "", nodeID: "primary", term: 0),
                        LeaseRequest(clusterID: "bot", nodeID: "", term: 0),
                        LeaseRequest(clusterID: "bot", nodeID: "primary", term: -1),
                        LeaseRequest(clusterID: "bot", nodeID: "primary", term: 1 << 62)] {
            let reply = await store.apply(.acquire, request: request)
            XCTAssertEqual(reply.status, 400)
        }
    }

    func testCorruptDatabaseIsPreservedAndRefusesStartup() throws {
        let url = try location()
        let damaged = Data("damaged durable ownership state".utf8)
        try damaged.write(to: url)
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
        XCTAssertEqual(try Data(contentsOf: url), damaged)
    }

    func testRemovedDatabaseFailsClosedRatherThanCreatingFreshAuthority() async throws {
        let url = try location()
        let store = try LeaseStore(databaseURL: url)
        _ = await store.apply(.acquire, request: request())
        try FileManager.default.removeItem(at: url)
        let reply = await store.apply(.acquire, request: request("backup"))
        XCTAssertEqual(reply.status, 503)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testDamagedTermCannotBeOverwrittenByLowerOwnership() async throws {
        let url = try location()
        let clock = TestClock()
        let store = try LeaseStore(databaseURL: url, clock: clock.now)
        _ = try grant(await store.apply(.acquire, request: request(term: 8)))
        try await store.executeStorageSQL("UPDATE leases SET term=-1")
        clock.advance(30)
        let refused = await store.apply(.acquire, request: request("backup"))
        XCTAssertEqual(refused.status, 503)
        do { _ = try await store.snapshot(); XCTFail("Damaged ownership must not report a healthy snapshot") }
        catch { }
    }

    func testMissingDatabaseAfterRestartCannotInitializeFreshAuthority() async throws {
        let url = try location()
        var original: LeaseStore? = try LeaseStore(databaseURL: url)
        _ = await original!.apply(.acquire, request: request())
        original = nil
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
