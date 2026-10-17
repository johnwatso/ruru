import Foundation
import RuruClient
import XCTest
@testable import WitnessKit

/// Credential rotation and the pull flow, through the published client against the real server.
final class CredentialRotationTests: XCTestCase {
    private let oldToken = String(repeating: "old-token-", count: 4)
    private let newToken = String(repeating: "new-token-", count: 4)

    private func server(_ services: [WitnessServiceCredential],
                        rotator: WitnessCredentialRotator? = nil) async throws -> (WitnessHTTPServer, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruRotation-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = try LeaseStore(databaseURL: folder.appendingPathComponent("leases.duckdb"))
        let server = try WitnessHTTPServer(store: store, services: services, credentialRotator: rotator)
        let port = try await server.start(port: 0)
        addTeardownBlock { await server.stop() }
        return (server, URL(string: "http://127.0.0.1:\(port)")!)
    }

    private func client(_ endpoint: URL, token: String, node: String = "home") -> RuruLeaseClient {
        RuruLeaseClient(configuration: .init(endpoint: endpoint, clusterID: "bot", nodeID: node, token: token),
                        session: URLSession(configuration: .ephemeral))
    }

    func testWithoutAnApplicationRotatorTheRouteDoesNotExist() async throws {
        let (_, endpoint) = try await server([WitnessServiceCredential(clusterID: "bot", token: oldToken)])
        let description = try await client(endpoint, token: oldToken).describe()
        XCTAssertEqual(description.credentialRotation, false)
        XCTAssertFalse(description.isCredentialRotationPending)
        do { _ = try await client(endpoint, token: oldToken).rotateCredential(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .server(status: 404, code: "not_found")) }
    }

    func testPairedServerReceivesTheIssuedTokenAndLostResponsesCanRetry() async throws {
        let issued = newToken
        let (server, endpoint) = try await server(
            [WitnessServiceCredential(clusterID: "bot", token: String(repeating: "shared-tok-", count: 4),
                                      nodeTokens: [WitnessNodeToken(nodeID: "home", token: oldToken)])],
            rotator: { cluster, node, usedPrevious in
                XCTAssertEqual(cluster, "bot")
                return node == "home" ? .issued(token: issued, previousValidSeconds: usedPrevious ? 120 : 900) : .notPending
            })
        let before = client(endpoint, token: oldToken)
        let described = try await before.describe()
        XCTAssertEqual(described.credentialRotation, true)
        XCTAssertFalse(described.isCredentialRotationPending)
        let rotated = try await before.rotateCredential()
        XCTAssertEqual(rotated.token, newToken)
        XCTAssertEqual(rotated.previousValidSeconds, 900)

        // The app admits the new token and keeps the old for a grace period.
        try await server.configureServices([WitnessServiceCredential(
            clusterID: "bot", token: String(repeating: "shared-tok-", count: 4),
            nodeTokens: [WitnessNodeToken(nodeID: "home", token: newToken, previousToken: oldToken,
                                          previousExpires: .now.addingTimeInterval(900))])])
        let stale = try await client(endpoint, token: oldToken).describe()
        XCTAssertTrue(stale.isCredentialRotationPending, "A replaced token is told to collect the current one")
        let current = try await client(endpoint, token: newToken).describe()
        XCTAssertFalse(current.isCredentialRotationPending)
        let collected = try await client(endpoint, token: oldToken).collectPendingCredential()
        XCTAssertEqual(collected?.token, newToken)
        let nothing = try await client(endpoint, token: newToken).collectPendingCredential()
        XCTAssertNil(nothing)

        // Grace over: the old token is rejected.
        try await server.configureServices([WitnessServiceCredential(
            clusterID: "bot", token: String(repeating: "shared-tok-", count: 4),
            nodeTokens: [WitnessNodeToken(nodeID: "home", token: newToken)])])
        do { _ = try await client(endpoint, token: oldToken).describe(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .unauthorized) }
    }

    func testSharedTokenHolderOnlyCollectsAnOperatorRotation() async throws {
        let issued = newToken
        let (server, endpoint) = try await server(
            [WitnessServiceCredential(clusterID: "bot", token: oldToken)],
            rotator: { _, node, usedPrevious in
                XCTAssertNil(node)
                return usedPrevious ? .issued(token: issued, previousValidSeconds: 60) : .notPending
            })
        do { _ = try await client(endpoint, token: oldToken).rotateCredential(); XCTFail("No rotation was pending") }
        catch { XCTAssertEqual(error as? RuruError, .server(status: 409, code: "no_rotation_pending")) }

        try await server.configureServices([WitnessServiceCredential(clusterID: "bot", token: newToken, previousToken: oldToken)])
        let pending = try await client(endpoint, token: oldToken).describe()
        XCTAssertTrue(pending.isCredentialRotationPending)
        let collected = try await client(endpoint, token: oldToken).rotateCredential()
        XCTAssertEqual(collected.token, newToken)
        // The new token works and cannot be used to mint another.
        _ = try await client(endpoint, token: newToken).describe()
        do { _ = try await client(endpoint, token: newToken).rotateCredential(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .server(status: 409, code: "no_rotation_pending")) }
    }

    func testRotationOutcomesMapToStatuses() async throws {
        for (outcome, status, code) in [(WitnessRotationOutcome.throttled, 429, "rotation_throttled"),
                                        (.failed, 503, "authority_unavailable")] {
            let (_, endpoint) = try await server([WitnessServiceCredential(clusterID: "bot", token: oldToken)],
                                                 rotator: { _, _, _ in outcome })
            do { _ = try await client(endpoint, token: oldToken).rotateCredential(); XCTFail() }
            catch { XCTAssertEqual(error as? RuruError, .server(status: status, code: code)) }
        }
    }

    func testRotationRejectsAnotherClusterAndABadToken() async throws {
        let (_, endpoint) = try await server([WitnessServiceCredential(clusterID: "bot", token: oldToken)],
                                             rotator: { _, _, _ in .issued(token: String(repeating: "x", count: 40), previousValidSeconds: 1) })
        let other = RuruLeaseClient(configuration: .init(endpoint: endpoint, clusterID: "other", nodeID: "home", token: oldToken),
                                    session: URLSession(configuration: .ephemeral))
        do { _ = try await other.rotateCredential(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .forbidden("forbidden_cluster")) }
        do { _ = try await client(endpoint, token: String(repeating: "bad-token-", count: 4)).rotateCredential(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .unauthorized) }
    }

    func testAPreviousTokenMayNotDuplicateAnyCurrentToken() async throws {
        let (server, _) = try await server([WitnessServiceCredential(clusterID: "bot", token: oldToken)])
        do {
            try await server.configureServices([WitnessServiceCredential(clusterID: "bot", token: oldToken, previousToken: oldToken)])
            XCTFail("Duplicate tokens would make identity ambiguous")
        } catch { XCTAssertTrue(error is WitnessError) }
    }
}
