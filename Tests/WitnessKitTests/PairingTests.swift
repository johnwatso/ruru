import Foundation
import RuruClient
import XCTest
@testable import WitnessKit

final class PairingTests: XCTestCase {
    private let credential = PairingDesk.Credential(clusterID: "bot", token: String(repeating: "pair-token-", count: 4), leaseSeconds: 30)

    func testCodesAreReadableSingleUseAndForgiving() async throws {
        let desk = PairingDesk(clock: TestClock(0).now)
        let code = try await desk.createCode(for: "bot")
        XCTAssertTrue(code.code.range(of: #"^[2-9A-HJKMNP-TV-Z]{4}-[2-9A-HJKMNP-TV-Z]{4}$"#, options: .regularExpression) != nil, code.code)
        let typed = code.code.lowercased().replacingOccurrences(of: "-", with: " ")
        guard case .accepted(let id) = await desk.claim(code: typed, nodeID: "studio", nodeName: "Studio Mac") else {
            return XCTFail("Code should be accepted")
        }
        let reused = await desk.claim(code: code.code, nodeID: "other", nodeName: nil)
        XCTAssertEqual(reused, .invalid)
        let requests = await desk.pendingRequests()
        XCTAssertEqual(requests.map(\.id), [id])
        XCTAssertEqual(requests.first?.nodeName, "Studio Mac")
        let codes = await desk.activeCodes()
        XCTAssertTrue(codes.isEmpty)
    }

    func testNothingIsReleasedUntilApprovalAndOnlyOnce() async throws {
        let desk = PairingDesk(clock: TestClock(0).now)
        let code = try await desk.createCode(for: "bot")
        guard case .accepted(let id) = await desk.claim(code: code.code, nodeID: "studio", nodeName: nil) else { return XCTFail() }
        let pending = await desk.status(of: id)
        XCTAssertEqual(pending, .pending)
        let wrongService = PairingDesk.Credential(clusterID: "other", token: credential.token, leaseSeconds: 30)
        do { try await desk.approve(id, with: wrongService); XCTFail("Approved for another service") } catch {}
        try await desk.approve(id, with: credential)
        let approved = await desk.status(of: id)
        XCTAssertEqual(approved, .approved(credential))
        let again = await desk.status(of: id)
        XCTAssertEqual(again, .expired)
    }

    func testRejectionExpiryAndRevocation() async throws {
        let clock = TestClock(0)
        let desk = PairingDesk(clock: clock.now)
        let first = try await desk.createCode(for: "bot")
        guard case .accepted(let rejected) = await desk.claim(code: first.code, nodeID: "a", nodeName: nil) else { return XCTFail() }
        await desk.reject(rejected)
        let rejectedStatus = await desk.status(of: rejected)
        XCTAssertEqual(rejectedStatus, .rejected)

        let stale = try await desk.createCode(for: "bot")
        clock.advance(PairingDesk.codeLifetime + 1)
        let expiredCode = await desk.claim(code: stale.code, nodeID: "a", nodeName: nil)
        XCTAssertEqual(expiredCode, .invalid)

        let waiting = try await desk.createCode(for: "bot")
        guard case .accepted(let unanswered) = await desk.claim(code: waiting.code, nodeID: "a", nodeName: nil) else { return XCTFail() }
        clock.advance(PairingDesk.requestLifetime + 1)
        let expiredRequest = await desk.status(of: unanswered)
        XCTAssertEqual(expiredRequest, .expired)

        let removed = try await desk.createCode(for: "bot")
        let kept = try await desk.createCode(for: "media")
        await desk.revoke(clusterID: "bot")
        let removedClaim = await desk.claim(code: removed.code, nodeID: "a", nodeName: nil)
        XCTAssertEqual(removedClaim, .invalid)
        guard case .accepted = await desk.claim(code: kept.code, nodeID: "a", nodeName: nil) else { return XCTFail() }
    }

    func testGuessingIsThrottledAndCodesAreBounded() async throws {
        let clock = TestClock(0)
        let desk = PairingDesk(clock: clock.now)
        let real = try await desk.createCode(for: "bot")
        for _ in 0..<PairingDesk.maxFailuresPerMinute {
            let guess = await desk.claim(code: "2222-2222", nodeID: "x", nodeName: nil)
            XCTAssertEqual(guess, .invalid)
        }
        let blocked = await desk.claim(code: real.code, nodeID: "x", nodeName: nil)
        XCTAssertEqual(blocked, .throttled)
        clock.advance(61)
        guard case .accepted = await desk.claim(code: real.code, nodeID: "x", nodeName: nil) else { return XCTFail() }
        for _ in 0..<PairingDesk.maxCodes { _ = try await desk.createCode(for: "bot") }
        do { _ = try await desk.createCode(for: "bot"); XCTFail("Unbounded codes") } catch {}
    }

    func testRuruClientPairsWithTheRealServerAndCanThenLease() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruPairing-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let store = try LeaseStore(databaseURL: folder.appendingPathComponent("leases.duckdb"))
        let server = try WitnessHTTPServer(store: store, services: [
            WitnessServiceCredential(clusterID: "bot", token: credential.token, leaseSeconds: 20)
        ])
        let port = try await server.start(port: 0)
        defer { Task { await server.stop() } }
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        let desk = server.pairing

        let code = try await desk.createCode(for: "bot")
        let pairing = Task {
            try await RuruPairing.pair(endpoint: endpoint, code: code.code, nodeID: "studio", nodeName: "Studio Mac",
                                       timeout: .seconds(20), session: URLSession(configuration: .ephemeral))
        }
        var request: PairingDesk.Request?
        for _ in 0..<100 where request == nil {
            request = await desk.pendingRequests().first
            if request == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let pending = try XCTUnwrap(request)
        XCTAssertEqual(pending.nodeName, "Studio Mac")
        try await desk.approve(pending.id, with: .init(clusterID: "bot", token: credential.token, leaseSeconds: 20))
        let configuration = try await pairing.value
        XCTAssertEqual(configuration.clusterID, "bot")
        XCTAssertEqual(configuration.token, credential.token)

        let lease = try await RuruLeaseClient(configuration: configuration, session: URLSession(configuration: .ephemeral)).acquire()
        XCTAssertEqual(lease.duration, .seconds(20))

        do {
            _ = try await RuruPairing.pair(endpoint: endpoint, code: "2222-2222", nodeID: "x", session: URLSession(configuration: .ephemeral))
            XCTFail("Accepted a made-up code")
        } catch { XCTAssertEqual(error as? RuruPairing.Failure, .invalidCode) }
    }
}
