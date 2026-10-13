import Foundation
import XCTest
@testable import WitnessKit

final class OperationalStatusTests: XCTestCase {
    private let token = String(repeating: "status-only-", count: 4)

    private func request(cluster: String = "app", token: String? = nil, node: String = "backup",
                         state: OperationalState = .ready, components: [OperationalComponent] = []) throws -> HTTPRequest {
        let report = OperationalStatusReport(clusterID: cluster, nodeID: node, nodeName: "Backup Mac", state: state,
                                             components: components)
        return .init(method: "POST", path: "/v1/operational-status/report",
                     headers: ["authorization": "Bearer " + (token ?? self.token)],
                     body: try JSONEncoder().encode(report))
    }

    func testReportsAreBoundedAuthenticatedAndExpireWithoutAuthorityState() async throws {
        let clock = TestClock(0)
        let status = OperationalStatusRegistry(clock: clock.now)
        try await status.configureServices([.init(clusterID: "app", token: token)])
        let components = [OperationalComponent(namespace: "swiftbot", id: "sync", state: .degraded,
                                               reasonCode: "peer_unreachable")]
        let accepted = await status.route(try request(state: .degraded, components: components))
        XCTAssertEqual(accepted.status, 200)
        let snapshot = await status.snapshot()
        XCTAssertEqual(snapshot.first?.state, .degraded)
        XCTAssertEqual(snapshot.first?.components, components)
        XCTAssertTrue(snapshot.first?.fresh ?? false)
        let invalid = await status.route(try request(components: [.init(namespace: "bad value", id: "sync", state: .ready)]))
        let unauthorized = await status.route(try request(token: "wrong"))
        let wrongCluster = await status.route(try request(cluster: "other"))
        XCTAssertEqual(invalid.status, 400)
        XCTAssertEqual(unauthorized.status, 401)
        XCTAssertEqual(wrongCluster.status, 400)
        clock.advance(45)
        let stale = await status.snapshot()
        XCTAssertFalse(stale.first?.fresh ?? true)
        clock.advance(600)
        let expired = await status.snapshot()
        XCTAssertTrue(expired.isEmpty)
    }

    func testReportLimitAndCredentialRotationClearObservations() async throws {
        let status = OperationalStatusRegistry()
        try await status.configureServices([.init(clusterID: "app", token: token)])
        for index in 0..<OperationalStatusRegistry.maxNodesPerService {
            let reply = await status.route(try request(node: "node-\(index)"))
            XCTAssertEqual(reply.status, 200)
        }
        let overflow = await status.route(try request(node: "overflow"))
        XCTAssertEqual(overflow.status, 429)
        try await status.configureServices([.init(clusterID: "app", token: String(repeating: "new-token-", count: 4))])
        let cleared = await status.snapshot()
        XCTAssertTrue(cleared.isEmpty)
    }
}
