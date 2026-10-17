import Foundation
import XCTest
@testable import WitnessKit

final class NodeTokenTests: XCTestCase {
    private let shared = String(repeating: "shared-service-", count: 4)
    private let alpha = String(repeating: "alpha-node-tok-", count: 4)
    private let beta = String(repeating: "beta-node-token-", count: 4)

    private func router(nodes: [WitnessNodeToken]) throws -> WitnessRouter {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruNodeTokens-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = try LeaseStore(databaseURL: folder.appendingPathComponent("leases.duckdb"))
        return try WitnessRouter(store: store, services: [WitnessServiceCredential(clusterID: "bot", token: shared, nodeTokens: nodes)])
    }

    private func lease(_ token: String, node: String, action: String = "acquire") throws -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v1/lease/\(action)", headers: ["authorization": "Bearer " + token],
                    body: try JSONEncoder().encode(LeaseRequest(clusterID: "bot", nodeID: node, term: 0)))
    }

    func testNodeTokenActsOnlyAsItsOwnNode() async throws {
        let router = try router(nodes: [.init(nodeID: "alpha", token: alpha), .init(nodeID: "beta", token: beta)])
        let own = await router.route(try lease(alpha, node: "alpha"))
        XCTAssertEqual(own.status, 200)
        let impersonation = await router.route(try lease(beta, node: "alpha", action: "renew"))
        XCTAssertEqual(impersonation.status, 403)
        let release = await router.route(try lease(beta, node: "alpha", action: "release"))
        XCTAssertEqual(release.status, 403)
    }

    func testRevokedNodeTokenStopsWorkingWhileOthersAndLegacyTokenContinue() async throws {
        let before = try router(nodes: [.init(nodeID: "alpha", token: alpha), .init(nodeID: "beta", token: beta)])
        let accepted = await before.route(try lease(beta, node: "beta"))
        XCTAssertEqual(accepted.status, 200)
        let after = try router(nodes: [.init(nodeID: "alpha", token: alpha)])
        let revoked = await after.route(try lease(beta, node: "beta"))
        XCTAssertEqual(revoked.status, 401)
        let legacy = await after.route(try lease(shared, node: "any-node"))
        XCTAssertEqual(legacy.status, 200)
    }

    func testNodeTokensMustBeUniqueStrongAndBoundedAndNeverReuseServiceToken() throws {
        XCTAssertThrowsError(try WitnessAuthorization(services: [WitnessServiceCredential(clusterID: "bot", token: shared,
            nodeTokens: [.init(nodeID: "a", token: shared)])]))
        XCTAssertThrowsError(try WitnessAuthorization(services: [WitnessServiceCredential(clusterID: "bot", token: shared,
            nodeTokens: [.init(nodeID: "a", token: "short")])]))
        XCTAssertThrowsError(try WitnessAuthorization(services: [WitnessServiceCredential(clusterID: "bot", token: shared,
            nodeTokens: [.init(nodeID: "a", token: alpha), .init(nodeID: "a", token: beta)])]))
    }

    func testNodeTokenCannotReportForAnotherNode() async throws {
        let router = try router(nodes: [.init(nodeID: "alpha", token: alpha)])
        let body = try JSONSerialization.data(withJSONObject: ["version": 1, "clusterID": "bot", "nodeID": "beta", "role": "standby"])
        let reply = await router.route(HTTPRequest(method: "POST", path: "/v1/participants/report",
                                                   headers: ["authorization": "Bearer " + alpha], body: body))
        XCTAssertEqual(reply.status, 403)
    }
}
