import Foundation
import XCTest
@testable import WitnessKit

final class BackupTests: XCTestCase {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruBackupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func term(_ reply: LeaseReply, file: StaticString = #filePath, line: UInt = #line) throws -> Int64 {
        XCTAssertEqual(reply.status, 200, file: file, line: line)
        return try JSONDecoder().decode(LeaseGrant.self, from: reply.body).term
    }

    func testRestoreRaisesTermsAboveBackupAndLiveDatabaseThenQuarantines() async throws {
        let url = try folder().appendingPathComponent("leases.duckdb"), clock = TestClock(0)
        var store: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        let actual1 = try term(await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 0, nodeName: "Home Mac")))
        XCTAssertEqual(actual1, 1)
        let actual2 = try term(await store!.apply(.acquire, request: LeaseRequest(clusterID: "worker", nodeID: "build", term: 50)))
        XCTAssertEqual(actual2, 51)
        let backup = try await store!.makeSnapshot()
        XCTAssertEqual(backup.highestTerm, 51)
        // Ownership moves on after the backup was taken.
        clock.advance(31)
        let actual3 = try term(await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "backup", term: 1)))
        XCTAssertEqual(actual3, 2)
        let known = try await store!.checkpointedTerms()
        store = nil

        let result = try LeaseRestore.restore(databaseURL: url, snapshot: try LeaseSnapshot.decode(backup.encoded()), knownTerms: known)
        XCTAssertEqual(result.terms["bot"], 2 + LeaseRestore.termMargin)
        XCTAssertEqual(result.terms["worker"], 51 + LeaseRestore.termMargin)
        let archive = try XCTUnwrap(result.archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.appendingPathComponent("leases.duckdb").path))

        let restored = try LeaseStore(databaseURL: url, clock: clock.now)
        let blocked = await restored.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 0))
        XCTAssertEqual(blocked.status, 503)
        let quarantined = try await restored.snapshot()
        XCTAssertTrue(quarantined.leases.allSatisfy { $0.ownerNodeID.isEmpty && $0.remainingSeconds == 0 })
        XCTAssertEqual(quarantined.events.count, backup.events.count)
        clock.advance(31)
        let actual4 = try term(await restored.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 0)))
        XCTAssertEqual(actual4, 3 + LeaseRestore.termMargin)
        let names = try await restored.snapshot().events.compactMap(\.nodeName)
        XCTAssertTrue(names.contains("Home Mac"))
    }

    func testRestoreReadsAnExistingDatabaseWhenNoLiveTermsAreSupplied() async throws {
        let url = try folder().appendingPathComponent("leases.duckdb"), clock = TestClock(0)
        var store: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        _ = await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 9))
        let backup = try await store!.makeSnapshot()
        clock.advance(31)
        _ = await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "backup", term: 19))
        store = nil
        let result = try LeaseRestore.restore(databaseURL: url, snapshot: backup)
        XCTAssertEqual(result.terms["bot"], 20 + LeaseRestore.termMargin)
    }

    func testRestoreIsRefusedWhileTheAuthorityIsOpen() async throws {
        let url = try folder().appendingPathComponent("leases.duckdb")
        let store = try LeaseStore(databaseURL: url, clock: TestClock(0).now)
        _ = await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 0))
        let backup = try await store.makeSnapshot()
        XCTAssertThrowsError(try LeaseRestore.restore(databaseURL: url, snapshot: backup)) { error in
            XCTAssertEqual(error as? LeaseRestoreError, .authorityInUse)
        }
        let actual5 = try await store.snapshot().leases.first?.term
        XCTAssertEqual(actual5, 1)
    }

    func testRestoreRebuildsAMissingDatabaseAsAQuarantinedAuthority() async throws {
        let source = try folder().appendingPathComponent("leases.duckdb"), clock = TestClock(0)
        var original: LeaseStore? = try LeaseStore(databaseURL: source, clock: clock.now)
        _ = await original!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 41))
        let backup = try await original!.makeSnapshot()
        original = nil
        let url = try folder().appendingPathComponent("Authority/leases.duckdb")
        let result = try LeaseRestore.restore(databaseURL: url, snapshot: backup)
        XCTAssertNil(result.archive)
        let restored = try LeaseStore(databaseURL: url, clock: clock.now)
        let actual6 = await restored.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 0)).status
        XCTAssertEqual(actual6, 503)
        clock.advance(31)
        let actual7 = try term(await restored.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 0)))
        XCTAssertEqual(actual7, 43 + LeaseRestore.termMargin)
    }

    func testDamagedOrForeignSnapshotsChangeNothing() async throws {
        let url = try folder().appendingPathComponent("leases.duckdb")
        var store: LeaseStore? = try LeaseStore(databaseURL: url, clock: TestClock(0).now)
        _ = await store!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "home", term: 0))
        let json = String(decoding: try await store!.makeSnapshot().encoded(), as: UTF8.self)
        store = nil
        let overflowing = json.replacingOccurrences(of: "\"term\" : 1", with: "\"term\" : \(Int64(1) << 62)")
        XCTAssertNotEqual(overflowing, json)
        XCTAssertThrowsError(try LeaseSnapshot.decode(Data(overflowing.utf8)))
        let foreign = json.replacingOccurrences(of: LeaseSnapshot.currentFormat, with: "com.example.other")
        XCTAssertThrowsError(try LeaseSnapshot.decode(Data(foreign.utf8)))
        let reopened = try LeaseStore(databaseURL: url, clock: TestClock(0).now)
        let actual8 = try await reopened.snapshot().leases.first?.term
        XCTAssertEqual(actual8, 1)
    }

    func testBackupFilesExcludeTunnelIdentityAndKeepThisMacsTunnelOnImport() throws {
        var exported = WitnessConfiguration()
        exported.tunnel.enabled = true
        exported.tunnel.hostname = "old.ruruapp.dev"
        exported.tunnel.tunnelID = "00000000-0000-4000-8000-000000000001"
        exported.tunnel.accountID = "account"
        exported.publicEndpoint = "https://old.ruruapp.dev"
        exported.additionalServices = [GuardedService(name: "Worker", clusterID: "worker")]
        let backup = RuruBackup(configuration: exported, leases: nil)
        XCTAssertFalse(backup.configuration.tunnel.isConfigured)
        XCTAssertEqual(backup.configuration.publicEndpoint, "")
        let text = String(decoding: try backup.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("old.ruruapp.dev"))
        XCTAssertFalse(text.contains("00000000-0000-4000-8000-000000000001"))

        let read = try RuruBackup.read(backup.encoded())
        var current = WitnessConfiguration()
        current.tunnel.enabled = true
        current.tunnel.hostname = "new.ruruapp.dev"
        current.tunnel.tunnelID = "00000000-0000-4000-8000-000000000002"
        current.tunnel.accountID = "new-account"
        current.publicEndpoint = "https://new.ruruapp.dev"
        let imported = try RuruBackup.importedConfiguration(try XCTUnwrap(read.configuration), current: current)
        XCTAssertEqual(imported.tunnel, current.tunnel)
        XCTAssertEqual(imported.publicEndpoint, "https://new.ruruapp.dev")
        XCTAssertEqual(imported.guardedServices.map(\.clusterID), exported.guardedServices.map(\.clusterID))
    }

    func testBareSnapshotsAreReadAndRotatedToTheNewest() async throws {
        let directory = try folder()
        let store = try LeaseStore(databaseURL: directory.appendingPathComponent("db/leases.duckdb"), clock: TestClock(0).now)
        let snapshot = try await store.makeSnapshot()
        let read = try RuruBackup.read(snapshot.encoded())
        XCTAssertNil(read.configuration)
        XCTAssertEqual(read.leases?.leases, snapshot.leases)
        let snapshots = directory.appendingPathComponent("Snapshots")
        for day in 0..<(WitnessStorage.snapshotsKept + 3) {
            let dated = LeaseSnapshot(createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(day) * 86_400),
                                      leases: [], events: [], nodeNames: [])
            try WitnessStorage.writeSnapshot(dated, in: snapshots)
        }
        let kept = WitnessStorage.snapshotFiles(in: snapshots)
        XCTAssertEqual(kept.count, WitnessStorage.snapshotsKept)
        XCTAssertEqual(try LeaseSnapshot.decode(Data(contentsOf: kept.last!)).createdAt,
                       Date(timeIntervalSince1970: 1_800_000_000 + Double(WitnessStorage.snapshotsKept + 2) * 86_400))
    }

    func testMissingDatabaseAfterCreationFailsClosed() throws {
        let directory = try folder()
        XCTAssertNoThrow(try WitnessStorage.checkAuthorityPresent(in: directory))
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Authority"), withIntermediateDirectories: true)
        try WitnessStorage.recordAuthorityCreated(in: directory)
        let excluded = try directory.appendingPathComponent("Authority").resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(excluded.isExcludedFromBackup, true)
        XCTAssertThrowsError(try WitnessStorage.checkAuthorityPresent(in: directory))
        try Data().write(to: directory.appendingPathComponent("Authority/leases.duckdb.initialized"))
        XCTAssertNoThrow(try WitnessStorage.checkAuthorityPresent(in: directory))
    }
}
