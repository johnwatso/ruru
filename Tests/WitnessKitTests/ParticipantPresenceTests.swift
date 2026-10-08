import Foundation
import XCTest
@testable import WitnessKit

final class ParticipantPresenceTests: XCTestCase {
    private let token = String(repeating: "test-only-", count: 4)
    private var services: [WitnessServiceCredential] {
        [.init(clusterID: "app", token: token), .init(clusterID: "other", token: String(repeating: "other-only-", count: 4))]
    }
    private func request(_ node: String = "backup", cluster: String = "app", token: String? = nil,
                         name: String? = "Backup Mac", version: Int = 1, webUIURL: String? = nil) throws -> HTTPRequest {
        .init(method: "POST", path: "/v1/participants/report", headers: ["authorization": "Bearer " + (token ?? self.token)],
              body: try JSONEncoder().encode(ParticipantReport(clusterID: cluster, nodeID: node, nodeName: name, role: .standby, version: version, webUIURL: webUIURL)))
    }

    func testWebsiteValidationFreshnessAndWithdrawal() async throws {
        let clock = TestClock(0)
        let presence = ParticipantPresence(clock: clock.now)
        try await presence.configureServices(services)
        let accepted = await presence.route(try request(webUIURL: "https://Failover.Example.com:443/"))
        XCTAssertEqual(accepted.status, 200)
        for value in ["http://example.com", "https://user:secret@example.com", "https://example.com?token=secret",
                      "https://example.com#secret", "https://example.com/login", "https://example.com)/[link]",
                      "https://example.com\n", String(repeating: "a", count: 257)] {
            let rejected = await presence.route(try request(webUIURL: value))
            XCTAssertEqual(rejected.status, 400, value)
        }
        var snapshot = await presence.snapshot()
        XCTAssertEqual(snapshot.first?.webUIURL, "https://failover.example.com")
        clock.advance(45)
        snapshot = await presence.snapshot()
        XCTAssertNil(snapshot.first?.webUIURL, "Stale reports must not advertise a current website")
        _ = await presence.route(try request(webUIURL: "https://new.example.com"))
        snapshot = await presence.snapshot()
        XCTAssertEqual(snapshot.first?.webUIURL, "https://new.example.com")
        _ = await presence.route(try request())
        snapshot = await presence.snapshot()
        XCTAssertNil(snapshot.first?.webUIURL, "Omitting the website withdraws the prior address")
    }

    func testAuthenticationValidationAndServiceIsolation() async throws {
        let presence = ParticipantPresence()
        try await presence.configureServices(services)
        for (request, status) in [
            (try request(token: "wrong"), 401), (try request(cluster: "other"), 403),
            (try request(version: 2), 409), (try request(""), 400),
            (try request(name: "invalid\nname"), 400), (try request(String(repeating: "x", count: 129)), 400)
        ] {
            let reply = await presence.route(request)
            XCTAssertEqual(reply.status, status)
        }
        let empty = await presence.snapshot()
        XCTAssertTrue(empty.isEmpty)
        let accepted = await presence.route(try request())
        XCTAssertEqual(accepted.status, 200)
        let snapshot = await presence.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.first?.role, .standby)
        XCTAssertEqual(snapshot.first?.nodeName, "Backup Mac")
        let oversized = await presence.route(.init(method: "POST", path: "/v1/participants/report",
            headers: ["authorization": "Bearer " + token], body: Data(repeating: 32, count: 4097)))
        XCTAssertEqual(oversized.status, 400)
    }

    func testFreshStaleExpiredAndRestartWithoutDurableOwnership() async throws {
        let clock = TestClock(0)
        let presence = ParticipantPresence(clock: clock.now)
        try await presence.configureServices(services)
        _ = await presence.route(try request())
        clock.advance(44)
        var snapshot = await presence.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.first).fresh)
        clock.advance(1)
        snapshot = await presence.snapshot()
        XCTAssertFalse(try XCTUnwrap(snapshot.first).fresh)
        XCTAssertEqual(snapshot.first?.ageSeconds, 45)
        _ = await presence.route(try request(name: "Renamed Backup"))
        snapshot = await presence.snapshot()
        XCTAssertTrue(try XCTUnwrap(snapshot.first).fresh)
        XCTAssertEqual(snapshot.first?.nodeName, "Renamed Backup")
        clock.advance(600)
        snapshot = await presence.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        let restarted = ParticipantPresence(clock: clock.now)
        try await restarted.configureServices(services)
        let empty = await restarted.snapshot()
        XCTAssertTrue(empty.isEmpty)
    }

    func testBoundsRefreshAndCredentialRevocation() async throws {
        let presence = ParticipantPresence()
        try await presence.configureServices(services)
        for index in 0..<ParticipantPresence.maxNodesPerService {
            let reply = await presence.route(try request("node-\(index)"))
            XCTAssertEqual(reply.status, 200)
        }
        let full = await presence.route(try request("overflow"))
        XCTAssertEqual(full.status, 429)
        let refreshed = await presence.route(try request("node-0"))
        XCTAssertEqual(refreshed.status, 200)
        try await presence.configureServices(services)
        let retained = await presence.snapshot()
        XCTAssertEqual(retained.count, ParticipantPresence.maxNodesPerService)
        try await presence.configureServices([.init(clusterID: "app", token: String(repeating: "new-only-", count: 4))])
        let cleared = await presence.snapshot()
        XCTAssertTrue(cleared.isEmpty)
        let revoked = await presence.route(try request())
        XCTAssertEqual(revoked.status, 401)
        try await presence.configureServices([])
        let removed = await presence.route(try request(token: String(repeating: "new-only-", count: 4)))
        XCTAssertEqual(removed.status, 401)
    }
}
