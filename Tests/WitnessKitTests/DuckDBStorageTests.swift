import Darwin
import Foundation
import XCTest
@testable import WitnessKit

final class DuckDBStorageTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuruDuckDBTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("leases.duckdb")
    }

    func testRestartQuarantinesEveryServiceAndPreservesIndependentTerms() async throws {
        let url = try location(), clock = TestClock(0)
        var original: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        for (cluster, term) in [("bot", Int64(10)), ("worker", Int64(50)), ("archive", Int64(90))] {
            let grant = await original!.apply(.acquire, request: LeaseRequest(clusterID: cluster, nodeID: "server", term: term))
            XCTAssertEqual(grant.status, 200)
        }
        original = nil
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        for cluster in ["bot", "worker", "archive", "new-service"] {
            let blocked = await restarted.apply(.acquire, request: LeaseRequest(clusterID: cluster, nodeID: "replacement", term: 0))
            XCTAssertEqual(blocked.status, 503)
        }
        clock.advance(31)
        for (cluster, expected) in [("bot", Int64(12)), ("worker", Int64(52)), ("archive", Int64(92))] {
            let granted = await restarted.apply(.acquire, request: LeaseRequest(clusterID: cluster, nodeID: "replacement", term: 0))
            XCTAssertEqual(try JSONDecoder().decode(LeaseGrant.self, from: granted.body).term, expected)
        }
    }

    func testExistingSQLiteIsPreservedAndNeverStartsAnEmptyAuthority() throws {
        let url = try location()
        let oldURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        let bytes = Data("existing authority must not be overwritten".utf8)
        try bytes.write(to: oldURL)
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
        XCTAssertEqual(try Data(contentsOf: oldURL), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testLegacyInitializationMarkerWithoutDatabaseCannotStartFresh() throws {
        let url = try location()
        let marker = url.deletingPathExtension().appendingPathExtension("sqlite.initialized")
        try Data("SwiftMeshWitness-authority-v1".utf8).write(to: marker)
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExplicitLegacyReplacementArchivesEveryFileAndInitializesFreshAuthority() async throws {
        let url = try location()
        let legacy = url.deletingPathExtension().appendingPathExtension("sqlite")
        let files = [legacy, URL(fileURLWithPath: legacy.path + "-wal"), URL(fileURLWithPath: legacy.path + "-shm"), legacy.appendingPathExtension("initialized")]
        for path in files { try Data(path.lastPathComponent.utf8).write(to: path) }
        var checkpointed = false
        let archive = try LegacyAuthorityReplacement.archiveAndReplace(databaseURL: url) { checkpointed = true }
        XCTAssertTrue(checkpointed)
        for path in files {
            XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent(path.lastPathComponent)), Data(path.lastPathComponent.utf8))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathExtension("initialized")), LeaseDatabaseSetup.retiredMarker)
        let fresh = try LeaseStore(databaseURL: url)
        let snapshot = try await fresh.snapshot()
        XCTAssertTrue(snapshot.leases.isEmpty)
        XCTAssertTrue(snapshot.events.isEmpty)
    }

    func testFailedReplacementCheckpointPreservesOriginalStorageAndMarker() throws {
        let url = try location()
        let legacy = url.deletingPathExtension().appendingPathExtension("sqlite")
        let marker = legacy.appendingPathExtension("initialized")
        let data = Data("old lease data".utf8), originalMarker = Data("old authority marker".utf8)
        try data.write(to: legacy)
        try originalMarker.write(to: marker)
        XCTAssertThrowsError(try LegacyAuthorityReplacement.archiveAndReplace(databaseURL: url) { throw WitnessError.invalidConfiguration })
        XCTAssertEqual(try Data(contentsOf: legacy), data)
        XCTAssertEqual(try Data(contentsOf: marker), originalMarker)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testReplacementCannotRunBesideAnOldAuthorityOrOverwriteDuckDB() throws {
        let url = try location()
        let legacy = url.deletingPathExtension().appendingPathExtension("sqlite")
        try Data("old authority".utf8).write(to: legacy)
        let oldLock = try DatabaseInstanceLock(url: legacy.appendingPathExtension("lock"))
        try withExtendedLifetime(oldLock) {
            var called = false
            XCTAssertThrowsError(try LegacyAuthorityReplacement.archiveAndReplace(databaseURL: url) { called = true })
            XCTAssertFalse(called)
        }
        let nativeURL = try location()
        let native: LeaseStore? = try LeaseStore(databaseURL: nativeURL)
        try withExtendedLifetime(native) {
            XCTAssertThrowsError(try LegacyAuthorityReplacement.archiveAndReplace(databaseURL: nativeURL) {})
        }
    }

    func testReplacementNeverAdoptsDamagedOrInterruptedDuckDBStorage() throws {
        for markerOnly in [false, true] {
            let url = try location()
            let legacy = url.deletingPathExtension().appendingPathExtension("sqlite")
            try Data("old authority".utf8).write(to: legacy)
            let path = markerOnly ? url.appendingPathExtension("initialized") : url
            let bytes = Data("damaged or incomplete".utf8)
            try bytes.write(to: path)
            XCTAssertThrowsError(try LegacyAuthorityReplacement.archiveAndReplace(databaseURL: url) {})
            XCTAssertEqual(try Data(contentsOf: path), bytes)
            XCTAssertEqual(try Data(contentsOf: legacy), Data("old authority".utf8))
        }
    }

    func testFreshAuthorityRetiresOlderBinaryAndKeepsItsLifetimeLock() async throws {
        let url = try location()
        let oldURL = url.deletingPathExtension().appendingPathExtension("sqlite")
        let store = try LeaseStore(databaseURL: url)
        let marker = try Data(contentsOf: oldURL.appendingPathExtension("initialized"))
        XCTAssertEqual(marker, LeaseDatabaseSetup.retiredMarker)
        XCTAssertNotEqual(marker, Data("SwiftMeshWitness-authority-v1".utf8))
        XCTAssertThrowsError(try DatabaseInstanceLock(url: oldURL.appendingPathExtension("lock")))
        let reply = await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 0))
        XCTAssertEqual(reply.status, 200)
    }

    func testInterruptedInitializationFailsClosed() throws {
        let url = try location()
        try LeaseDatabaseSetup.marker.write(to: url.appendingPathExtension("initialized"))
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMarkedCorruptDatabaseIsPreserved() throws {
        let url = try location()
        var store: LeaseStore? = try LeaseStore(databaseURL: url)
        XCTAssertNotNil(store)
        store = nil
        let bytes = Data("damaged DuckDB authority".utf8)
        try bytes.write(to: url)
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    func testFailureAfterLeaseAndAuditWritesRollsBackBoth() async throws {
        let url = try location(), clock = TestClock(0)
        let store = try LeaseStore(databaseURL: url, clock: clock.now)
        let initial = await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 11))
        let grant = try JSONDecoder().decode(LeaseGrant.self, from: initial.body)
        clock.advance(30)
        try await store.executeStorageSQL("DROP TABLE node_names")
        let refused = await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "backup", term: 0, nodeName: "Backup Mac"))
        XCTAssertEqual(refused.status, 503)
        try await store.executeStorageSQL("CREATE TABLE node_names (cluster VARCHAR NOT NULL, node VARCHAR NOT NULL, name VARCHAR NOT NULL, PRIMARY KEY (cluster, node))")
        let snapshot = try await store.snapshot()
        XCTAssertEqual(snapshot.leases.first?.term, grant.term)
        XCTAssertEqual(snapshot.leases.first?.ownerNodeID, "primary")
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.events.first?.nodeID, "primary")
    }

    func testMissingOlderBinarySafetyMarkerFailsClosed() async throws {
        let url = try location()
        var store: LeaseStore? = try LeaseStore(databaseURL: url)
        _ = await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 10))
        store = nil
        try FileManager.default.removeItem(at: url.deletingPathExtension().appendingPathExtension("sqlite.initialized"))
        XCTAssertThrowsError(try LeaseStore(databaseURL: url))
    }

    func testAcknowledgedGrantSurvivesAbruptProcessDeathAndQuarantines() async throws {
        let url = try location()
        let replyURL = url.deletingLastPathComponent().appendingPathComponent("grant.json")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let child = Process()
        child.executableURL = products.appendingPathComponent("WitnessStorageProbe")
        child.arguments = [url.path, replyURL.path]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !FileManager.default.fileExists(atPath: replyURL.path), child.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        let original = try JSONDecoder().decode(LeaseGrant.self, from: Data(contentsOf: replyURL))
        XCTAssertEqual(original.term, 13)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + ".wal"))
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let clock = TestClock(0)
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        let state = try await restarted.snapshot()
        XCTAssertEqual(state.recoverySeconds, 30)
        XCTAssertEqual(state.leases.first?.term, original.term)
        XCTAssertEqual(state.leases.first?.remainingSeconds, 0)
        XCTAssertEqual(state.leases.first?.ownerNodeName, "Primary Mac")
        let request = LeaseRequest(clusterID: "bot", nodeID: "primary", term: original.term)
        let duringRecovery = await restarted.apply(.renew, request: request)
        XCTAssertEqual(duringRecovery.status, 503)
        clock.advance(30)
        let expired = await restarted.apply(.renew, request: request)
        XCTAssertEqual(expired.status, 409)
        let acquired = await restarted.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "backup", term: 0))
        let next = try JSONDecoder().decode(LeaseGrant.self, from: acquired.body)
        XCTAssertEqual(next.term, original.term + 1)
    }

    func testMemorySoakProbeUsesAnIsolatedAuthorityAndExportsResourceSamples() async throws {
        let directory = try location().deletingLastPathComponent()
        let report = directory.appendingPathComponent("memory.json")
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let child = Process()
        child.executableURL = products.appendingPathComponent("WitnessStorageProbe")
        child.arguments = ["--memory-soak", report.path, "10"]
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { if child.isRunning { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while child.isRunning, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertFalse(child.isRunning, "The bounded storage probe must finish.")
        guard !child.isRunning else { return }
        XCTAssertEqual(child.terminationStatus, 0)
        struct Sample: Decodable { let iteration: Int; let resources: RuruDiagnostics.Resources }
        let samples = try JSONDecoder().decode([Sample].self, from: Data(contentsOf: report))
        XCTAssertEqual(samples.map(\.iteration), [0, 10])
        for sample in samples {
            XCTAssertGreaterThan(try XCTUnwrap(sample.resources.physicalFootprintBytes), 0)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["memory.json"])
    }
}
