import Foundation
import XCTest
@testable import WitnessKit

final class WitnessHTTPTests: XCTestCase {
    func testPolicyDuringRestartQuarantineDoesNotGrantPermission() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruPolicyQuarantine-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("leases.duckdb")
        let clock = TestClock(0)
        var previous: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        _ = await previous!.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "old-owner", term: 9))
        previous = nil
        let restarted = try LeaseStore(databaseURL: url, clock: clock.now)
        let router = try WitnessRouter(store: restarted, services: [WitnessServiceCredential(clusterID: "bot", token: token,
            primaryPreference: .init(preferredPrimaryNodeID: "new-primary", revision: 1))])
        let policy = await router.route(HTTPRequest(method: "POST", path: "/v1/service/policy",
            headers: ["authorization": "Bearer " + token], body: try JSONEncoder().encode(["clusterID": "bot"])))
        XCTAssertEqual(policy.status, 200)
        let denied = await router.route(try request(token: token))
        XCTAssertEqual(denied.status, 503)
        let snapshot = try await restarted.snapshot()
        XCTAssertEqual(snapshot.recoverySeconds, 30)
        XCTAssertEqual(snapshot.leases.first?.remainingSeconds, 0)
        XCTAssertEqual(snapshot.leases.first?.term, 10)
        XCTAssertEqual(snapshot.events.count, 1)
    }

    func testServicePolicyRequiresScopedCredentialsAndDoesNotAllocateLeases() async throws {
        let database = try store()
        let workerToken = String(repeating: "worker-secret-", count: 4)
        let router = try WitnessRouter(store: database, services: [
            WitnessServiceCredential(clusterID: "bot", token: token,
                primaryPreference: .init(preferredPrimaryNodeID: "preferred-a", revision: 4)),
            WitnessServiceCredential(clusterID: "worker", token: workerToken)
        ])
        func policyRequest(_ cluster: String, credential: String?) -> HTTPRequest {
            HTTPRequest(method: "POST", path: "/v1/service/policy",
                headers: credential.map { ["authorization": "Bearer " + $0] } ?? [:],
                body: try! JSONEncoder().encode(["clusterID": cluster]))
        }
        for credential in [nil, "incorrect"] {
            let denied = await router.route(policyRequest("bot", credential: credential))
            XCTAssertEqual(denied.status, 401)
        }
        let crossService = await router.route(policyRequest("bot", credential: workerToken))
        XCTAssertEqual(crossService.status, 403)
        let unknown = await router.route(policyRequest("missing", credential: token))
        XCTAssertEqual(unknown.status, 403)
        let accepted = await router.route(policyRequest("bot", credential: token))
        XCTAssertEqual(accepted.status, 200)
        let policy = try JSONDecoder().decode(WitnessServicePolicy.self, from: accepted.body)
        XCTAssertEqual(policy.version, 1)
        XCTAssertEqual(policy.clusterID, "bot")
        XCTAssertEqual(policy.preferredPrimaryNodeID, "preferred-a")
        XCTAssertEqual(policy.preferenceRevision, 4)
        XCTAssertNil(accepted.body.range(of: Data(token.utf8)))
        let emptyPolicy = await router.route(policyRequest("worker", credential: workerToken))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyPolicy.body) as? [String: Any])
        XCTAssertTrue(object["preferredPrimaryNodeID"] is NSNull)
        let snapshot = try await database.snapshot()
        XCTAssertTrue(snapshot.leases.isEmpty)
        XCTAssertTrue(snapshot.events.isEmpty)
        let malformed = await router.route(HTTPRequest(method: "POST", path: "/v1/service/policy",
            headers: ["authorization": "Bearer " + token], body: Data(#"{"clusterID":true}"#.utf8)))
        XCTAssertEqual(malformed.status, 400)
        let health = await router.route(HTTPRequest(method: "GET", path: "/health", headers: [:], body: Data()))
        XCTAssertEqual(String(decoding: health.body, as: UTF8.self), #"{"ready":true}"#)
    }

    func testLivePreferenceChangeAndClearDoNotTransferOwnershipOrBlockFailover() async throws {
        let database = try store()
        let server = try WitnessHTTPServer(store: database, services: [
            WitnessServiceCredential(clusterID: "bot", token: token,
                primaryPreference: .init(preferredPrimaryNodeID: "offline-primary", revision: 1))
        ])
        let port = try await server.start(port: 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            func send(path: String, body: Data) async throws -> (Data, Int) {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
                request.httpMethod = "POST"
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.httpBody = body
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let acquired = try await send(path: "/v1/lease/acquire",
                body: JSONEncoder().encode(LeaseRequest(clusterID: "bot", nodeID: "failover", term: 0)))
            XCTAssertEqual(acquired.1, 200)
            let grant = try JSONDecoder().decode(LeaseGrant.self, from: acquired.0)
            try await server.configureServices([WitnessServiceCredential(clusterID: "bot", token: token,
                primaryPreference: .init(preferredPrimaryNodeID: "new-primary", revision: 2))])
            let fetched = try await send(path: "/v1/service/policy", body: JSONEncoder().encode(["clusterID": "bot"]))
            let changed = try JSONDecoder().decode(WitnessServicePolicy.self, from: fetched.0)
            XCTAssertEqual(changed.preferredPrimaryNodeID, "new-primary")
            XCTAssertEqual(changed.preferenceRevision, 2)
            do {
                try await server.configureServices([WitnessServiceCredential(clusterID: "bot", token: token,
                    primaryPreference: .init(preferredPrimaryNodeID: "node", revision: -1))])
                XCTFail("Invalid preference was accepted")
            } catch { }
            let retained = try await send(path: "/v1/service/policy", body: JSONEncoder().encode(["clusterID": "bot"]))
            XCTAssertEqual(try JSONDecoder().decode(WitnessServicePolicy.self, from: retained.0), changed)
            let competing = try await send(path: "/v1/lease/acquire",
                body: JSONEncoder().encode(LeaseRequest(clusterID: "bot", nodeID: "new-primary", term: 0)))
            XCTAssertEqual(competing.1, 409)
            let renewed = try await send(path: "/v1/lease/renew",
                body: JSONEncoder().encode(LeaseRequest(clusterID: "bot", nodeID: "failover", term: grant.term)))
            XCTAssertEqual(renewed.1, 200)
            try await server.configureServices([WitnessServiceCredential(clusterID: "bot", token: token,
                primaryPreference: .init(revision: 3))])
            let cleared = try await send(path: "/v1/service/policy", body: JSONEncoder().encode(["clusterID": "bot"]))
            let value = try JSONDecoder().decode(WitnessServicePolicy.self, from: cleared.0)
            XCTAssertNil(value.preferredPrimaryNodeID)
            XCTAssertEqual(value.preferenceRevision, 3)
            let snapshot = try await database.snapshot()
            XCTAssertEqual(snapshot.leases.first?.ownerNodeID, "failover")
            XCTAssertEqual(snapshot.leases.first?.term, grant.term)
            XCTAssertEqual(snapshot.events.count, 1)
            try await server.configureServices([])
            let removed = try await send(path: "/v1/service/policy", body: JSONEncoder().encode(["clusterID": "bot"]))
            XCTAssertEqual(removed.1, 401)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

    private let token = String(repeating: "test-authority-", count: 4)

    private func store(clock: (@Sendable () -> Double)? = nil) throws -> LeaseStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruHTTPTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try LeaseStore(databaseURL: folder.appendingPathComponent("leases.duckdb"), clock: clock)
    }

    private func request(token: String? = nil, cluster: String = "bot", path: String = "/v1/lease/acquire") throws -> HTTPRequest {
        let headers = token.map { ["authorization": "Bearer " + $0] } ?? [:]
        return HTTPRequest(method: "POST", path: path, headers: headers,
                           body: try JSONEncoder().encode(LeaseRequest(clusterID: cluster, nodeID: "primary", term: 0)))
    }

    func testServiceDescriptionIsScopedToTheCallersServiceAndReportsLiveState() async throws {
        let clock = TestClock(0)
        let other = String(repeating: "other-authority-", count: 4)
        let router = try WitnessRouter(store: store(clock: clock.now), services: [
            WitnessServiceCredential(clusterID: "bot", token: token, leaseSeconds: 60),
            WitnessServiceCredential(clusterID: "media", token: other,
                                     coordinationPolicy: .init(enabled: true, allowedOrigins: ["https://media.example.com"]))
        ])
        let describe = { (token: String?) in
            HTTPRequest(method: "GET", path: "/v1/service", headers: token.map { ["authorization": "Bearer " + $0] } ?? [:], body: Data())
        }
        let unauthorized = await router.route(describe(nil))
        XCTAssertEqual(unauthorized.status, 401)
        let empty = await router.route(describe(token))
        XCTAssertEqual(empty.status, 200)
        var description = try JSONDecoder().decode(WitnessServiceDescription.self, from: empty.body)
        XCTAssertEqual(description.clusterID, "bot")
        XCTAssertEqual(description.leaseSeconds, 60)
        XCTAssertNil(description.lease)
        XCTAssertEqual(description.capabilities["lease"]?.version, 1)
        XCTAssertEqual(description.capabilities["coordination"]?.enabled, false)
        let grant = await router.route(try request(token: token))
        XCTAssertEqual(try JSONDecoder().decode(LeaseGrant.self, from: grant.body).expiresInSeconds, 60)
        clock.advance(10)
        description = try JSONDecoder().decode(WitnessServiceDescription.self, from: await router.route(describe(token)).body)
        XCTAssertEqual(description.lease?.ownerNodeID, "primary")
        XCTAssertEqual(description.lease?.remainingSeconds, 50)
        let media = try JSONDecoder().decode(WitnessServiceDescription.self, from: await router.route(describe(other)).body)
        XCTAssertEqual(media.clusterID, "media")
        XCTAssertEqual(media.capabilities["coordination"]?.enabled, true)
        XCTAssertNil(media.lease)
        XCTAssertNil(empty.body.range(of: Data(token.utf8)))
    }

    func testLeaseRoutesRequireBearerCredential() async throws {
        let router = try WitnessRouter(store: store(), clusterID: "bot", token: token)
        let missing = await router.route(try request())
        let wrong = await router.route(try request(token: "wrong-credential"))
        let accepted = await router.route(try request(token: token))
        XCTAssertEqual(missing.status, 401)
        XCTAssertEqual(wrong.status, 401)
        XCTAssertEqual(accepted.status, 200)
        XCTAssertNil(accepted.body.range(of: Data(token.utf8)))
    }

    func testUnknownClusterCannotAllocateAnotherAuthority() async throws {
        let database = try store()
        let router = try WitnessRouter(store: database, clusterID: "bot", token: token)
        let reply = await router.route(try request(token: token, cluster: "unconfigured"))
        XCTAssertEqual(reply.status, 403)
        let state = try await database.snapshot()
        XCTAssertTrue(state.leases.isEmpty)
    }

    func testHealthDoesNotExposeOwnerOrCredential() async throws {
        let database = try store()
        _ = await database.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "private-node", term: 8))
        let router = try WitnessRouter(store: database, clusterID: "bot", token: token)
        let reply = await router.route(HTTPRequest(method: "GET", path: "/health", headers: [:], body: Data()))
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(String(decoding: reply.body, as: UTF8.self), #"{"ready":true}"#)
    }

    func testMalformedAndBooleanTermsAreRejected() async throws {
        let router = try WitnessRouter(store: store(), clusterID: "bot", token: token)
        for body in [#"{"clusterID":"bot","nodeID":"primary","term":true}"#, "{"] {
            let reply = await router.route(HTTPRequest(method: "POST", path: "/v1/lease/acquire",
                                                      headers: ["authorization": "Bearer " + token], body: Data(body.utf8)))
            XCTAssertEqual(reply.status, 400)
        }
    }

    func testShortCredentialCannotStartRouter() throws {
        XCTAssertThrowsError(try WitnessRouter(store: store(), clusterID: "bot", token: "short"))
    }

    func testServicesHaveIndependentTermsAndRejectCrossServiceCredentials() async throws {
        let database = try store()
        let workerToken = String(repeating: "worker-secret-", count: 4)
        let router = try WitnessRouter(store: database, services: [
            WitnessServiceCredential(clusterID: "bot", token: token),
            WitnessServiceCredential(clusterID: "worker", token: workerToken)
        ])
        let bot = await router.route(HTTPRequest(method: "POST", path: "/v1/lease/acquire",
            headers: ["authorization": "Bearer " + token],
            body: try JSONEncoder().encode(LeaseRequest(clusterID: "bot", nodeID: "primary", term: 42))))
        let worker = await router.route(try request(token: workerToken, cluster: "worker"))
        XCTAssertEqual(bot.status, 200)
        XCTAssertEqual(worker.status, 200)
        for action in ["acquire", "renew", "release"] {
            let denied = await router.route(try request(token: workerToken, cluster: "bot", path: "/v1/lease/" + action))
            XCTAssertEqual(denied.status, 403)
        }
        for index in 0..<4 {
            let payload = LeaseRequest(clusterID: "worker", nodeID: "contender-\(index)", term: 0)
            let denied = await router.route(HTTPRequest(method: "POST", path: "/v1/lease/acquire",
                headers: ["authorization": "Bearer " + workerToken], body: try JSONEncoder().encode(payload)))
            XCTAssertEqual(denied.status, 409)
        }
        let snapshot = try await database.snapshot()
        XCTAssertEqual(snapshot.leases.count, 2)
        XCTAssertEqual(Set(snapshot.events.map(\.clusterID)), ["bot", "worker"])
        XCTAssertTrue(snapshot.leases.allSatisfy { $0.ownerNodeID == "primary" })
        XCTAssertEqual(snapshot.leases.first { $0.clusterID == "bot" }?.term, 43)
        XCTAssertEqual(snapshot.leases.first { $0.clusterID == "worker" }?.term, 1)
    }

    func testDuplicateServiceIDsOrCredentialsCannotStartAuthority() throws {
        let database = try store()
        XCTAssertThrowsError(try WitnessRouter(store: database, services: [
            WitnessServiceCredential(clusterID: "bot", token: token),
            WitnessServiceCredential(clusterID: "bot", token: String(repeating: "z", count: 40))
        ]))
        XCTAssertThrowsError(try WitnessRouter(store: database, services: [
            WitnessServiceCredential(clusterID: "bot", token: token),
            WitnessServiceCredential(clusterID: "worker", token: token)
        ]))
    }

    func testEmptyCatalogServesHealthButRejectsAllLeaseRequests() async throws {
        let router = try WitnessRouter(store: store(), services: [])
        let health = await router.route(HTTPRequest(method: "GET", path: "/health", headers: [:], body: Data()))
        XCTAssertEqual(health.status, 200)
        for action in ["acquire", "renew", "release"] {
            let denied = await router.route(try request(token: token, cluster: "bot", path: "/v1/lease/" + action))
            XCTAssertEqual(denied.status, 401)
        }
    }

    func testLiveRemovalRevokesAllActionsPreservesOtherServiceAndRetainsFencingOnReadd() async throws {
        let clock = TestClock(0)
        let database = try store(clock: clock.now)
        let workerToken = String(repeating: "worker-secret-", count: 4)
        let replacementToken = String(repeating: "replacement-secret-", count: 3)
        let botAccess = WitnessServiceCredential(clusterID: "bot", token: token)
        let server = try WitnessHTTPServer(store: database, services: [botAccess, WitnessServiceCredential(clusterID: "worker", token: workerToken)])
        let port = try await server.start(port: 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            func send(cluster: String, token: String, action: String = "acquire", node: String = "server", term: Int64 = 0) async throws -> (Data, Int) {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/lease/\(action)")!)
                request.httpMethod = "POST"
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder().encode(LeaseRequest(clusterID: cluster, nodeID: node, term: term))
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let bot = try await send(cluster: "bot", token: token)
            let worker = try await send(cluster: "worker", token: workerToken)
            let botGrant = try JSONDecoder().decode(LeaseGrant.self, from: bot.0)
            let workerGrant = try JSONDecoder().decode(LeaseGrant.self, from: worker.0)
            try await server.configureServices([botAccess])
            for action in ["acquire", "renew", "release"] {
                let denied = try await send(cluster: "worker", token: workerToken, action: action, term: workerGrant.term)
                XCTAssertEqual(denied.1, 401)
            }
            let renewed = try await send(cluster: "bot", token: token, action: "renew", term: botGrant.term)
            XCTAssertEqual(renewed.1, 200)
            let preserved = try await database.snapshot()
            XCTAssertEqual(preserved.leases.first { $0.clusterID == "worker" }?.term, workerGrant.term)
            XCTAssertEqual(preserved.events.count, 2)
            try await server.configureServices([botAccess, WitnessServiceCredential(clusterID: "worker", token: replacementToken)])
            let overlapping = try await send(cluster: "worker", token: replacementToken, node: "replacement")
            XCTAssertEqual(overlapping.1, 409)
            let oldToken = try await send(cluster: "worker", token: workerToken)
            XCTAssertEqual(oldToken.1, 401)
            clock.advance(31)
            let next = try await send(cluster: "worker", token: replacementToken, node: "replacement")
            XCTAssertEqual(next.1, 200)
            XCTAssertEqual(try JSONDecoder().decode(LeaseGrant.self, from: next.0).term, workerGrant.term + 1)
            try await server.configureServices([])
            let empty = try await send(cluster: "bot", token: token, action: "renew", term: botGrant.term)
            XCTAssertEqual(empty.1, 401)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

    func testLiveServiceAdditionPreservesExistingLeaseAndListener() async throws {
        let database = try store()
        let server = try WitnessHTTPServer(store: database, clusterID: "bot", token: token)
        let port = try await server.start(port: 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            func send(cluster: String, token: String, action: String = "acquire", term: Int64 = 0) async throws -> (Data, Int) {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/lease/\(action)")!)
                request.httpMethod = "POST"
                request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                request.httpBody = try JSONEncoder().encode(LeaseRequest(clusterID: cluster, nodeID: "server", term: term))
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let first = try await send(cluster: "bot", token: token)
            let grant = try JSONDecoder().decode(LeaseGrant.self, from: first.0)
            let workerToken = String(repeating: "worker-secret-", count: 4)
            try await server.configureServices([
                WitnessServiceCredential(clusterID: "bot", token: token),
                WitnessServiceCredential(clusterID: "worker", token: workerToken)
            ])
            let worker = try await send(cluster: "worker", token: workerToken)
            XCTAssertEqual(worker.1, 200)
            let renewed = try await send(cluster: "bot", token: token, action: "renew", term: grant.term)
            XCTAssertEqual(renewed.1, 200)
            XCTAssertEqual(try JSONDecoder().decode(LeaseGrant.self, from: renewed.0).term, grant.term)
            do {
                try await server.configureServices([WitnessServiceCredential(clusterID: "bot", token: "short")])
                XCTFail("Invalid registry accepted")
            } catch { }
            let unchanged = try await send(cluster: "bot", token: token, action: "renew", term: grant.term)
            XCTAssertEqual(unchanged.1, 200)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

    func testParserWaitsForCompleteBody() {
        let partial = Data("POST /v1/lease/acquire HTTP/1.1\r\nContent-Length: 2\r\n\r\n{".utf8)
        if case .incomplete = HTTPParser.parse(partial) { } else { XCTFail("Expected incomplete body") }
        if case .request(let parsed) = HTTPParser.parse(partial + Data("}".utf8)) {
            XCTAssertEqual(parsed.body, Data("{}".utf8))
        } else { XCTFail("Expected a complete request") }
    }

    func testParserRejectsAmbiguousLengthsChunkingAndOversizedBody() {
        let headers = ["Content-Length: 2\r\nContent-Length: 1", "Transfer-Encoding: chunked",
                       "Content-Length: 4097", "Content-Length: -1"]
        for header in headers {
            let bytes = Data("POST /v1/lease/acquire HTTP/1.1\r\n\(header)\r\n\r\n{}".utf8)
            if case .reject = HTTPParser.parse(bytes) { } else { XCTFail("Unsafe request accepted: \(header)") }
        }
    }

    func testParserRejectsOversizedHeadersAndPipelinedBytes() {
        if case .reject(431) = HTTPParser.parse(Data(repeating: 65, count: 8193)) { }
        else { XCTFail("Oversized header accepted") }
        let pipelined = Data("GET /health HTTP/1.1\r\n\r\nGET /health HTTP/1.1\r\n\r\n".utf8)
        if case .reject(400) = HTTPParser.parse(pipelined) { } else { XCTFail("Pipelined request accepted") }
    }

    func testLiveListenerMatchesSwiftBotLeaseProtocol() async throws {
        let database = try store()
        let server = try WitnessHTTPServer(store: database, clusterID: "bot", token: token)
        let port = try await server.start(port: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            func send(_ action: String, node: String, term: Int64, authorized: Bool = true) async throws -> (Data, Int) {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/lease/\(action)")!)
                request.httpMethod = "POST"
                if authorized { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(LeaseRequest(clusterID: "bot", nodeID: node, term: term))
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let denied = try await send("acquire", node: "primary", term: 0, authorized: false)
            XCTAssertEqual(denied.1, 401)
            let acquired = try await send("acquire", node: "primary", term: 0)
            XCTAssertEqual(acquired.1, 200)
            let grant = try JSONDecoder().decode(LeaseGrant.self, from: acquired.0)
            XCTAssertEqual(grant.ownerNodeID, "primary")
            let competing = try await send("acquire", node: "backup", term: 0)
            XCTAssertEqual(competing.1, 409)
            let renewed = try await send("renew", node: "primary", term: grant.term)
            XCTAssertEqual(renewed.1, 200)
            let released = try await send("release", node: "primary", term: grant.term)
            XCTAssertEqual(released.1, 200)
            let next = try await send("acquire", node: "backup", term: 0)
            XCTAssertGreaterThan(try JSONDecoder().decode(LeaseGrant.self, from: next.0).term, grant.term)
            await server.stop()
        } catch {
            await server.stop()
            throw error
        }
    }
}
