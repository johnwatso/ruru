import Darwin
import Foundation
import XCTest
@testable import WitnessKit

final class CoordinationTests: XCTestCase {
    private let token = String(repeating: "catalogue-test-", count: 4)
    private let otherToken = String(repeating: "other-test-", count: 4)
    private let policy = CoordinationPolicy(enabled: true, allowedOrigins: ["https://media.example.com"])

    private func credentials(_ enabled: Bool = true) -> [WitnessServiceCredential] {
        [.init(clusterID: "app", token: token, coordinationPolicy: enabled ? policy : .init()),
         .init(clusterID: "other", token: otherToken, coordinationPolicy: policy)]
    }
    private func resource(_ id: String = "one", namespace: String = "recordings", url: String = "https://media.example.com/item") -> CoordinationResource {
        .init(namespace: namespace, resourceID: id, title: "Resource " + id, url: url)
    }
    private func request<T: Encodable>(_ payload: T, route: String = "report", credential: String? = nil) throws -> HTTPRequest {
        HTTPRequest(method: "POST", path: "/v1/coordination/" + route,
            headers: ["authorization": "Bearer " + (credential ?? token)], body: try JSONEncoder().encode(payload))
    }
    private func page(_ catalogue: CoordinationCatalogue, cluster: String = "app", offset: Int = 0, revision: String? = nil) async throws -> CoordinationCataloguePage {
        let reply = await catalogue.route(try request(CoordinationCatalogueRequest(clusterID: cluster, offset: offset, revision: revision),
            route: "catalogue", credential: cluster == "app" ? token : otherToken))
        XCTAssertEqual(reply.status, 200)
        return try JSONDecoder().decode(CoordinationCataloguePage.self, from: reply.body)
    }
    private func store(clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) throws -> LeaseStore {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruCoordinationTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return try LeaseStore(databaseURL: folder.appendingPathComponent("leases.duckdb"), clock: clock)
    }

    func testScopedAuthenticationOptInAndVersionDiscovery() async throws {
        let catalogue = try CoordinationCatalogue(services: credentials(false))
        let disabled = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()])))
        XCTAssertEqual(disabled.status, 403)
        let discovery = await catalogue.route(try request(CoordinationScopeRequest(clusterID: "app"), route: "capabilities"))
        let capabilities = try JSONDecoder().decode(CoordinationCapabilities.self, from: discovery.body)
        XCTAssertFalse(capabilities.enabled)
        XCTAssertTrue(capabilities.capabilities.isEmpty)
        let wrongToken = await catalogue.route(try request(CoordinationScopeRequest(clusterID: "app"), route: "capabilities", credential: "bad"))
        XCTAssertEqual(wrongToken.status, 401)
        let crossService = await catalogue.route(try request(CoordinationReport(clusterID: "other", nodeID: "a", resources: [resource()])))
        XCTAssertEqual(crossService.status, 403)
        let unsupported = await catalogue.route(try request(CoordinationScopeRequest(clusterID: "app", version: 2), route: "capabilities"))
        XCTAssertEqual(unsupported.status, 409)
        let unknown = await catalogue.route(try request(CoordinationScopeRequest(clusterID: "app"), route: "delete"))
        XCTAssertEqual(unknown.status, 404)
        let oversized = await catalogue.route(HTTPRequest(method: "POST", path: "/v1/coordination/report",
            headers: ["authorization": "Bearer " + token], body: Data(repeating: 32, count: 4097)))
        XCTAssertEqual(oversized.status, 400)
        let snapshot = await catalogue.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
    }

    func testRecordingsAndArtifactsHaveIndependentIdentitiesAndMultipleLocations() async throws {
        let catalogue = try CoordinationCatalogue(services: credentials())
        for node in ["a", "b"] {
            let accepted = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: node,
                nodeName: "Server " + node, resources: [resource("same"), resource("same", namespace: "artifacts")])))
            XCTAssertEqual(accepted.status, 200)
        }
        let other = await catalogue.route(try request(CoordinationReport(clusterID: "other", nodeID: "a", resources: [resource("same")]), credential: otherToken))
        XCTAssertEqual(other.status, 200)
        let app = try await page(catalogue)
        XCTAssertEqual(app.locations.count, 4)
        XCTAssertEqual(Set(app.locations.map(\.id)).count, 4)
        let otherPage = try await page(catalogue, cluster: "other")
        XCTAssertEqual(otherPage.locations.count, 1)
        let removed = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a",
            removed: [.init(namespace: "recordings", resourceID: "same")])))
        XCTAssertEqual(removed.status, 200)
        let updated = try await page(catalogue)
        XCTAssertEqual(updated.locations.count, 3)
        XCTAssertTrue(updated.locations.contains { $0.nodeID == "b" && $0.resource.namespace == "recordings" })
    }

    func testMonotonicFreshnessEmptyHeartbeatCannotReviveResourcesAndRestartStartsEmpty() async throws {
        let clock = TestClock()
        let catalogue = try CoordinationCatalogue(services: credentials(), clock: clock.now)
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()])))
        clock.advance(90)
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a")))
        let stale = try await page(catalogue)
        XCTAssertFalse(try XCTUnwrap(stale.locations.first).fresh)
        XCTAssertEqual(stale.locations.first?.ageSeconds, 90)
        clock.advance(510)
        let expired = try await page(catalogue)
        XCTAssertTrue(expired.locations.isEmpty)
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()])))
        let reannounced = try await page(catalogue)
        XCTAssertTrue(try XCTUnwrap(reannounced.locations.first).fresh)
        let restarted = try CoordinationCatalogue(services: credentials(), clock: clock.now)
        let empty = try await page(restarted)
        XCTAssertTrue(empty.locations.isEmpty)
        XCTAssertNotEqual(empty.revision, reannounced.revision)
    }

    func testURLValidationAndInvalidBatchesAreAtomic() async throws {
        XCTAssertEqual(CoordinationPolicy.normalizedOrigin("https://MEDIA.example.com:443/"), "https://media.example.com")
        for url in ["http://media.example.com/item", "https://evil.example.com/item", "https://media.example.com.evil/item",
                    "https://user:secret@media.example.com/item", "https://media.example.com/item?token=secret",
                    "https://media.example.com/item#secret", "https://media.example.com:8443/item", "https://media.example.com\\@evil.example.com/item"] {
            let catalogue = try CoordinationCatalogue(services: credentials())
            let reply = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a",
                resources: [resource(), resource("invalid", url: url)])))
            XCTAssertEqual(reply.status, 400, url)
            let snapshot = await catalogue.snapshot()
            XCTAssertTrue(snapshot.isEmpty)
        }
        let catalogue = try CoordinationCatalogue(services: credentials())
        for resources in [[resource(), resource()], (0..<9).map { resource(String($0)) }, [resource("bad\nID")]] {
            let reply = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: resources)))
            XCTAssertEqual(reply.status, 400)
        }
        let overlap = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()],
            removed: [resource().key])))
        XCTAssertEqual(overlap.status, 400)
    }

    func testPaginationDetectsChangesWithinServiceAndRejectsInvalidOffsets() async throws {
        let catalogue = try CoordinationCatalogue(services: credentials())
        for batch in 0..<3 {
            _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a",
                resources: (0..<8).map { resource(String(batch * 8 + $0)) })))
        }
        let first = try await page(catalogue)
        XCTAssertEqual(first.locations.count, 20)
        XCTAssertEqual(first.nextOffset, 20)
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "other", nodeID: "a", resources: [resource()]), credential: otherToken))
        let last = try await page(catalogue, offset: 20, revision: first.revision)
        XCTAssertEqual(last.locations.count, 4)
        XCTAssertNil(last.nextOffset)
        XCTAssertEqual(Set((first.locations + last.locations).map(\.id)).count, 24)
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource("new")])))
        let changed = await catalogue.route(try request(CoordinationCatalogueRequest(clusterID: "app", offset: 20, revision: first.revision), route: "catalogue"))
        XCTAssertEqual(changed.status, 409)
        for offset in [-1, 1, 520] {
            let denied = await catalogue.route(try request(CoordinationCatalogueRequest(clusterID: "app", offset: offset), route: "catalogue"))
            XCTAssertEqual(denied.status, 400)
        }
        let noRevision = await catalogue.route(try request(CoordinationCatalogueRequest(clusterID: "app", offset: 20), route: "catalogue"))
        XCTAssertEqual(noRevision.status, 400)
    }

    func testCapacityRejectsWholeBatchAndExpiredEntriesReleaseSpace() async throws {
        let clock = TestClock()
        let catalogue = try CoordinationCatalogue(services: credentials(), clock: clock.now)
        for batch in 0..<16 {
            let reply = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a",
                resources: (0..<8).map { resource(String(batch * 8 + $0)) })))
            XCTAssertEqual(reply.status, 200)
        }
        let full = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource("overflow")])))
        XCTAssertEqual(full.status, 429)
        var snapshot = await catalogue.snapshot()
        XCTAssertEqual(snapshot.count, 128)
        clock.advance(600)
        let recovered = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource("overflow")])))
        XCTAssertEqual(recovered.status, 200)
        snapshot = await catalogue.snapshot()
        XCTAssertEqual(snapshot.count, 1)
        for node in 0..<15 {
            _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: String(node))))
        }
        let nodeOverflow = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "seventeenth")))
        XCTAssertEqual(nodeOverflow.status, 429)
    }

    func testPolicyChangesRemovalAndTokenRotationRevokeObservations() async throws {
        let catalogue = try CoordinationCatalogue(services: credentials())
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()])))
        let narrow = WitnessServiceCredential(clusterID: "app", token: token, coordinationPolicy: .init(enabled: true))
        try await catalogue.configureServices([narrow])
        var snapshot = await catalogue.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        try await catalogue.configureServices(credentials())
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()])))
        try await catalogue.configureServices(credentials(false))
        snapshot = await catalogue.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        try await catalogue.configureServices(credentials())
        _ = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()])))
        try await catalogue.configureServices([.init(clusterID: "app", token: otherToken, coordinationPolicy: policy)])
        let old = await catalogue.route(try request(CoordinationScopeRequest(clusterID: "app"), route: "capabilities"))
        XCTAssertEqual(old.status, 401)
        snapshot = await catalogue.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        try await catalogue.configureServices([])
        let removed = await catalogue.route(try request(CoordinationScopeRequest(clusterID: "app"), route: "capabilities", credential: otherToken))
        XCTAssertEqual(removed.status, 401)
    }

    func testServiceAndGlobalCapacityCannotBeExceeded() async throws {
        let access = (0..<5).map { index in
            WitnessServiceCredential(clusterID: "group-\(index)", token: String(repeating: "token-\(index)-", count: 5), coordinationPolicy: policy)
        }
        let catalogue = try CoordinationCatalogue(services: access)
        for service in access.prefix(4) {
            for node in 0..<4 {
                for batch in 0..<16 {
                    let report = CoordinationReport(clusterID: service.clusterID, nodeID: "node-\(node)",
                        resources: (0..<8).map { resource(String(batch * 8 + $0)) })
                    let reply = await catalogue.route(try request(report, credential: service.token))
                    XCTAssertEqual(reply.status, 200)
                }
            }
            let overflow = await catalogue.route(try request(CoordinationReport(clusterID: service.clusterID,
                nodeID: "extra-node", resources: [resource("overflow")]), credential: service.token))
            XCTAssertEqual(overflow.status, 429)
        }
        let globalOverflow = await catalogue.route(try request(CoordinationReport(clusterID: access[4].clusterID,
            nodeID: "node", resources: [resource()]), credential: access[4].token))
        XCTAssertEqual(globalOverflow.status, 429)
        var snapshot = await catalogue.snapshot()
        XCTAssertEqual(snapshot.count, 2048)
        _ = await catalogue.route(try request(CoordinationReport(clusterID: access[0].clusterID, nodeID: "node-0",
            removed: [.init(namespace: "recordings", resourceID: "0")]), credential: access[0].token))
        let recovered = await catalogue.route(try request(CoordinationReport(clusterID: access[4].clusterID,
            nodeID: "node", resources: [resource()]), credential: access[4].token))
        XCTAssertEqual(recovered.status, 200)
        snapshot = await catalogue.snapshot()
        XCTAssertEqual(snapshot.count, 2048)
    }

    func testReportingDuringRecoveryDoesNotAllocateOwnershipAndLegacyLeaseStillWorks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruCatalogueRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: folder) }
        let clock = TestClock(0)
        let url = folder.appendingPathComponent("leases.duckdb")
        var previous: LeaseStore? = try LeaseStore(databaseURL: url, clock: clock.now)
        _ = await previous!.apply(.acquire, request: .init(clusterID: "app", nodeID: "owner", term: 0))
        previous = nil
        let database = try LeaseStore(databaseURL: url, clock: clock.now)
        let router = try WitnessRouter(store: database, services: credentials())
        let report = await router.route(try request(CoordinationReport(clusterID: "app", nodeID: "standby", resources: [resource()])))
        XCTAssertEqual(report.status, 200)
        let snapshot = try await database.snapshot()
        XCTAssertEqual(snapshot.recoverySeconds, 30)
        XCTAssertEqual(snapshot.events.count, 1)
        XCTAssertEqual(snapshot.leases.first?.term, 1)
        let health = await router.route(HTTPRequest(method: "GET", path: "/health", headers: [:], body: Data()))
        XCTAssertEqual(health.status, 503)
        clock.advance(30)
        let lease = await router.route(HTTPRequest(method: "POST", path: "/v1/lease/acquire", headers: ["authorization": "Bearer " + token],
            body: Data(#"{"clusterID":"app","nodeID":"owner","term":1}"#.utf8)))
        XCTAssertEqual(lease.status, 200)
        let grant = try JSONDecoder().decode(LeaseGrant.self, from: lease.body)
        XCTAssertEqual(grant.term, 2)
        XCTAssertEqual(grant.ownerNodeID, "owner")
    }

    func testCatalogueLoadAndLiveDisablePreserveLeaseRenewal() async throws {
        let database = try store()
        let server = try WitnessHTTPServer(store: database, services: credentials())
        let port = try await server.start(port: 0)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let authorization = token
            @Sendable func send(_ path: String, _ body: Data) async throws -> (Data, Int) {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
                request.httpMethod = "POST"
                request.httpBody = body
                request.setValue("Bearer " + authorization, forHTTPHeaderField: "Authorization")
                let (data, response) = try await session.data(for: request)
                return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            let acquired = try await send("/v1/lease/acquire", JSONEncoder().encode(LeaseRequest(clusterID: "app", nodeID: "owner", term: 0)))
            let grant = try JSONDecoder().decode(LeaseGrant.self, from: acquired.0)
            let reportData = try JSONEncoder().encode(CoordinationReport(clusterID: "app", nodeID: "standby", resources: [resource()]))
            let renewData = try JSONEncoder().encode(LeaseRequest(clusterID: "app", nodeID: "owner", term: grant.term))
            try await withThrowingTaskGroup(of: (Int, Bool).self) { group in
                for _ in 0..<40 { group.addTask { (try await send("/v1/coordination/report", reportData).1, false) } }
                for _ in 0..<10 { group.addTask { (try await send("/v1/lease/renew", renewData).1, true) } }
                for try await (status, renewal) in group {
                    if renewal { XCTAssertEqual(status, 200) }
                    else { XCTAssertTrue([200, 429].contains(status)) }
                }
            }
            try await server.configureServices(credentials(false))
            let disabled = try await send("/v1/coordination/report", reportData)
            XCTAssertEqual(disabled.1, 403)
            let renewed = try await send("/v1/lease/renew", renewData)
            XCTAssertEqual(renewed.1, 200)
            let snapshot = try await database.snapshot()
            XCTAssertEqual(snapshot.leases.first?.term, grant.term)
            XCTAssertEqual(snapshot.leases.first?.ownerNodeID, "owner")
            XCTAssertEqual(snapshot.events.count, 1)
            await server.stop()
        } catch { await server.stop(); throw error }
    }
    func testSlowCatalogueConnectionsLeaveRoomForLeaseRequests() async throws {
        let server = try WitnessHTTPServer(store: store(), services: credentials())
        let port = try await server.start(port: 0)
        var sockets: [Int32] = []
        defer { for descriptor in sockets { Darwin.close(descriptor) } }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            for _ in 0..<4 {
                let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw POSIXError(.EIO) }
                sockets.append(descriptor)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_port = port.bigEndian
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                let connected = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
                XCTAssertEqual(connected, 0)
                // Valid headers, deliberately unfinished body. Read timeout remains bounded.
                let header = Data("POST /v1/coordination/report HTTP/1.1\r\nContent-Length: 20\r\n\r\n".utf8)
                let written = header.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
                XCTAssertEqual(written, header.count)
            }
            var metadata = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/coordination/report")!)
            metadata.httpMethod = "POST"
            metadata.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            metadata.httpBody = try JSONEncoder().encode(CoordinationReport(clusterID: "app", nodeID: "a", resources: [resource()]))
            var status = 0
            for _ in 0..<20 {
                let (_, response) = try await session.data(for: metadata)
                status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 429 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertEqual(status, 429)
            var lease = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/lease/acquire")!)
            lease.httpMethod = "POST"
            lease.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
            lease.httpBody = try JSONEncoder().encode(LeaseRequest(clusterID: "app", nodeID: "owner", term: 0))
            let (_, response) = try await session.data(for: lease)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

}

extension CoordinationTests {
    func testEnrollmentRequiresScopedAuthenticationAndNeverEnablesReportingItself() async throws {
        let catalogue = try CoordinationCatalogue(services: credentials(false))
        let proposal = CoordinationEnrollmentRequest(clusterID: "app", nodeID: "backup", nodeName: "Backup", origin: "https://backup.example.com")
        let invalidToken = await catalogue.route(try request(proposal, route: "enrollment", credential: "bad"))
        XCTAssertEqual(invalidToken.status, 401)
        var wrongScope = proposal
        wrongScope.clusterID = "other"
        let crossScope = await catalogue.route(try request(wrongScope, route: "enrollment"))
        XCTAssertEqual(crossScope.status, 403)
        for origin in ["http://backup.example.com", "https://backup.example.com/path", "https://user:secret@backup.example.com", "https://backup.example.com?token=secret"] {
            var invalid = proposal
            invalid.origin = origin
            let result = await catalogue.route(try request(invalid, route: "enrollment"))
            XCTAssertEqual(result.status, 400)
        }
        var unsupported = proposal
        unsupported.version = 2
        let version = await catalogue.route(try request(unsupported, route: "enrollment"))
        XCTAssertEqual(version.status, 409)
        let accepted = await catalogue.route(try request(proposal, route: "enrollment"))
        XCTAssertEqual(accepted.status, 200)
        XCTAssertEqual(try JSONDecoder().decode(CoordinationEnrollmentReply.self, from: accepted.body).status, "pending")
        let initial = await catalogue.pendingEnrollments()
        _ = await catalogue.route(try request(proposal, route: "enrollment"))
        let repeated = await catalogue.pendingEnrollments()
        XCTAssertEqual(initial.map(\.id), repeated.map(\.id))
        let denied = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "backup",
            resources: [resource(url: proposal.origin + "/library")])))
        XCTAssertEqual(denied.status, 403, "A proposal must not modify operator policy")
        let capabilities = await catalogue.route(try request(CoordinationScopeRequest(clusterID: "app"), route: "capabilities"))
        let decoded = try JSONDecoder().decode(CoordinationCapabilities.self, from: capabilities.body)
        XCTAssertFalse(decoded.enabled)
        XCTAssertTrue(decoded.enrollmentSupported)
    }

    func testOperatorApprovalAdmitsOnlyApprovedOriginAndWithdrawalRemovesPendingRequest() async throws {
        let catalogue = try CoordinationCatalogue(services: credentials(false))
        var proposal = CoordinationEnrollmentRequest(clusterID: "app", nodeID: "backup", origin: "https://backup.example.com")
        _ = await catalogue.route(try request(proposal, route: "enrollment"))
        try await catalogue.configureServices([.init(clusterID: "app", token: token,
            coordinationPolicy: .init(enabled: true, allowedOrigins: [proposal.origin]))])
        let pending = await catalogue.pendingEnrollments()
        XCTAssertTrue(pending.isEmpty)
        let approved = await catalogue.route(try request(proposal, route: "enrollment"))
        XCTAssertEqual(try JSONDecoder().decode(CoordinationEnrollmentReply.self, from: approved.body).status, "approved")
        let report = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "backup",
            resources: [resource(url: proposal.origin + "/library")])))
        XCTAssertEqual(report.status, 200)
        let elsewhere = await catalogue.route(try request(CoordinationReport(clusterID: "app", nodeID: "backup",
            resources: [resource(url: "https://elsewhere.example.com/library")])))
        XCTAssertEqual(elsewhere.status, 400)
        proposal.origin = "https://new.example.com"
        _ = await catalogue.route(try request(proposal, route: "enrollment"))
        proposal.withdraw = true
        let withdrawn = await catalogue.route(try request(proposal, route: "enrollment"))
        XCTAssertEqual(try JSONDecoder().decode(CoordinationEnrollmentReply.self, from: withdrawn.body).status, "withdrawn")
        let after = await catalogue.pendingEnrollments()
        XCTAssertTrue(after.isEmpty)
        let published = await catalogue.snapshot()
        XCTAssertEqual(published.count, 1, "Withdrawing a proposal must not delete a different live resource")
    }

    func testEnrollmentExpiryRejectionCapacityAndCredentialRevocation() async throws {
        let clock = TestClock()
        let catalogue = try CoordinationCatalogue(services: credentials(false), clock: clock.now)
        let proposal = CoordinationEnrollmentRequest(clusterID: "app", nodeID: "backup", origin: "https://backup.example.com")
        _ = await catalogue.route(try request(proposal, route: "enrollment"))
        let pending = await catalogue.pendingEnrollments()
        await catalogue.rejectEnrollment(id: try XCTUnwrap(pending.first).id)
        let rejected = await catalogue.route(try request(proposal, route: "enrollment"))
        XCTAssertEqual(try JSONDecoder().decode(CoordinationEnrollmentReply.self, from: rejected.body).status, "rejected")
        for index in 1..<8 {
            let next = CoordinationEnrollmentRequest(clusterID: "app", nodeID: "node-\(index)", origin: "https://backup.example.com")
            let result = await catalogue.route(try request(next, route: "enrollment"))
            XCTAssertEqual(result.status, 200)
        }
        let overflow = await catalogue.route(try request(CoordinationEnrollmentRequest(clusterID: "app", nodeID: "overflow",
            origin: "https://backup.example.com"), route: "enrollment"))
        XCTAssertEqual(overflow.status, 429, "Rejected tombstones also count against capacity")
        clock.advance(600)
        let expired = await catalogue.pendingEnrollments()
        XCTAssertTrue(expired.isEmpty)
        let retry = await catalogue.route(try request(proposal, route: "enrollment"))
        XCTAssertEqual(try JSONDecoder().decode(CoordinationEnrollmentReply.self, from: retry.body).status, "pending")
        try await catalogue.configureServices([.init(clusterID: "app", token: otherToken)])
        let revoked = await catalogue.pendingEnrollments()
        XCTAssertTrue(revoked.isEmpty)
        let old = await catalogue.route(try request(proposal, route: "enrollment"))
        XCTAssertEqual(old.status, 401)
        _ = await catalogue.route(try request(proposal, route: "enrollment", credential: otherToken))
        try await catalogue.configureServices([])
        let removed = await catalogue.pendingEnrollments()
        XCTAssertTrue(removed.isEmpty)
    }

    func testGlobalEnrollmentCapacityAndFloodLeavesLeaseAuthorityUsable() async throws {
        let services = (0..<9).map { WitnessServiceCredential(clusterID: "service-\($0)", token: String(repeating: "test-token-\($0)-", count: 4)) }
        let catalogue = try CoordinationCatalogue(services: services)
        for service in services.prefix(8) {
            for index in 0..<8 {
                let reply = await catalogue.route(try request(CoordinationEnrollmentRequest(clusterID: service.clusterID,
                    nodeID: "node-\(index)", origin: "https://node.example.com"), route: "enrollment", credential: service.token))
                XCTAssertEqual(reply.status, 200)
            }
        }
        let overflow = await catalogue.route(try request(CoordinationEnrollmentRequest(clusterID: services[8].clusterID,
            nodeID: "node", origin: "https://node.example.com"), route: "enrollment", credential: services[8].token))
        XCTAssertEqual(overflow.status, 429)
        let router = try WitnessRouter(store: store(), services: services, catalogue: catalogue)
        let grant = await router.route(HTTPRequest(method: "POST", path: "/v1/lease/acquire",
            headers: ["authorization": "Bearer " + services[8].token],
            body: try JSONEncoder().encode(LeaseRequest(clusterID: services[8].clusterID, nodeID: "owner", term: 0))))
        XCTAssertEqual(grant.status, 200)
    }
}
