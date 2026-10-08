import Foundation
import RuruClient
import XCTest
@testable import WitnessKit

/// Runs the published RuruClient against the real server: the behaviour every
/// client must handle. See Documentation/INTEGRATIONS.md for the checklist.
final class ClientConformanceTests: XCTestCase {
    private let token = String(repeating: "conformance-", count: 4)

    private func authority(leaseSeconds: Double = 10, clock: (@Sendable () -> Double)? = nil,
                           url: URL? = nil) async throws -> (WitnessHTTPServer, URL, URL) {
        let database: URL
        if let url { database = url } else {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruConformance-\(UUID().uuidString)")
            addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
            database = folder.appendingPathComponent("leases.duckdb")
        }
        let store = try LeaseStore(databaseURL: database, clock: clock)
        let server = try WitnessHTTPServer(store: store, services: [
            WitnessServiceCredential(clusterID: "bot", token: token, leaseSeconds: leaseSeconds)
        ])
        let port = try await server.start(port: 0)
        return (server, URL(string: "http://127.0.0.1:\(port)")!, database)
    }

    private func client(_ endpoint: URL, node: String, token: String? = nil) -> RuruLeaseClient {
        RuruLeaseClient(configuration: .init(endpoint: endpoint, clusterID: "bot", nodeID: node,
                                             nodeName: node.capitalized + " Mac", token: token ?? self.token),
                        session: URLSession(configuration: .ephemeral))
    }

    func testOneOwnerAtATimeWithRisingFencingTerms() async throws {
        let (server, endpoint, _) = try await authority(leaseSeconds: 20)
        defer { Task { await server.stop() } }
        let home = client(endpoint, node: "home"), backup = client(endpoint, node: "backup")
        let first = try await home.acquire()
        XCTAssertEqual(first.duration, .seconds(20))
        do { _ = try await backup.acquire(); XCTFail("Two owners") } catch { XCTAssertEqual(error as? RuruError, .ownershipHeld) }
        let renewed = try await home.renew(first)
        XCTAssertEqual(renewed.term, first.term)
        try await home.release(renewed)
        do { _ = try await home.renew(renewed); XCTFail("Renewed a released lease") }
        catch { XCTAssertEqual(error as? RuruError, .ownershipLost) }
        let second = try await backup.acquire()
        XCTAssertGreaterThan(second.term, first.term)
        let description = try await backup.describe()
        XCTAssertEqual(description.lease?.ownerNodeID, "backup")
        XCTAssertTrue(description.supports("lease"))
        do { _ = try await client(endpoint, node: "x", token: String(repeating: "wrong-token-", count: 4)).acquire(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .unauthorized) }
    }

    func testStandbyPresenceIsVisibleWithoutChangingOwnerOrTerm() async throws {
        let (server, endpoint, _) = try await authority(leaseSeconds: 30)
        defer { Task { await server.stop() } }
        let primary = client(endpoint, node: "home"), backup = client(endpoint, node: "backup")
        let lease = try await primary.acquire()
        let discovery = try await backup.describe()
        XCTAssertTrue(discovery.supports("participantPresence"))
        try await primary.reportPresence(role: .active)
        try await backup.reportPresence(role: .standby, webUIURL: URL(string: "https://failover.example.com"))
        let participants = await server.participants.snapshot()
        XCTAssertEqual(Set(participants.map(\.nodeID)), ["home", "backup"])
        XCTAssertEqual(participants.first { $0.nodeID == "backup" }?.role, .standby)
        XCTAssertEqual(participants.first { $0.nodeID == "backup" }?.webUIURL, "https://failover.example.com")
        XCTAssertNil(participants.first { $0.nodeID == "home" }?.webUIURL)
        let unchanged = try await backup.describe()
        XCTAssertEqual(unchanged.lease?.ownerNodeID, "home")
        XCTAssertEqual(unchanged.lease?.term, lease.term)
        let renewed = try await primary.renew(lease)
        XCTAssertEqual(renewed.term, lease.term)
        try await server.configureServices([])
        let cleared = await server.participants.snapshot()
        XCTAssertTrue(cleared.isEmpty)
        do { try await backup.reportPresence(role: .standby); XCTFail("Removed service reported") }
        catch { XCTAssertEqual(error as? RuruError, .unauthorized) }
    }

    func testMaintainHandsOverWhenTheOwnerStops() async throws {
        let (server, endpoint, _) = try await authority()
        defer { Task { await server.stop() } }
        let states = StateLog()
        let homeClient = client(endpoint, node: "home"), backupClient = client(endpoint, node: "backup")
        let home = Task { await homeClient.maintain(retryInterval: .milliseconds(100)) { await states.add("home", $0) } }
        try await states.wait { $0.contains { $0.0 == "home" && $0.1.isOwner } }
        let backup = Task { await backupClient.maintain(retryInterval: .milliseconds(100)) { await states.add("backup", $0) } }
        try await states.wait { $0.contains { $0.0 == "backup" && $0.1 == .standby } }
        home.cancel()
        await home.value
        try await states.wait { $0.contains { $0.0 == "backup" && $0.1.isOwner } }
        backup.cancel()
        await backup.value
        let terms = await states.entries.compactMap { entry -> Int64? in
            if case .owner(let lease) = entry.1 { return lease.term } else { return nil }
        }
        XCTAssertEqual(terms, terms.sorted())
    }

    func testRestartQuarantineIsReportedAsRecovering() async throws {
        let clock = TestClock(0)
        var first: (WitnessHTTPServer, URL, URL)? = try await authority(clock: clock.now)
        let database = first!.2
        _ = try await client(first!.1, node: "home").acquire()
        await first!.0.stop()
        first = nil
        let (server, endpoint, _) = try await authority(clock: clock.now, url: database)
        defer { Task { await server.stop() } }
        do { _ = try await client(endpoint, node: "backup").acquire(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .recovering) }
        clock.advance(11)
        let lease = try await client(endpoint, node: "backup").acquire()
        XCTAssertEqual(lease.term, 2)
    }
}

private actor StateLog {
    private(set) var entries: [(String, RuruLeaseState)] = []
    func add(_ node: String, _ state: RuruLeaseState) { entries.append((node, state)) }
    func wait(timeout: Duration = .seconds(5), until condition: @Sendable ([(String, RuruLeaseState)]) -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(entries) {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out; states: \(entries.map { "\($0.0)=\($0.1)" })")
                throw POSIXError(.ETIMEDOUT)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private extension RuruLeaseState {
    var isOwner: Bool { if case .owner = self { true } else { false } }
}
