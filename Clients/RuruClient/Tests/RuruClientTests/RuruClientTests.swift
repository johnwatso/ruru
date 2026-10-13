import Foundation
import XCTest
@testable import RuruClient

/// Replies with canned responses, recording each request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [(status: Int, body: String)] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
            recorded.httpBody = data
        }
        Self.requests.append(recorded)
        let reply = Self.replies.isEmpty ? (500, "{}") : Self.replies.removeFirst()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class RuruClientTests: XCTestCase {
    private func client(node: String = "home") -> RuruLeaseClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.requests = []
        return RuruLeaseClient(configuration: .init(endpoint: URL(string: "https://ruru.example.com")!, clusterID: "bot",
                                                    nodeID: node, nodeName: "Home Mac", token: "secret-token"),
                               session: URLSession(configuration: configuration))
    }

    func testAcquireSendsTheProtocolRequestAndReturnsAFencedLease() async throws {
        StubProtocol.replies = [(200, #"{"ownerNodeID":"home","term":7,"expiresInSeconds":30}"#)]
        let lease = try await client().acquire()
        XCTAssertEqual(lease.term, 7)
        XCTAssertTrue(lease.isValid)
        XCTAssertLessThanOrEqual(lease.deadline, ContinuousClock.now + .seconds(30))
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/lease/acquire")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["clusterID"] as? String, "bot")
        XCTAssertEqual(body["nodeID"] as? String, "home")
        XCTAssertEqual(body["nodeName"] as? String, "Home Mac")
    }

    func testErrorsMapToActionableCases() async {
        let cases: [(Int, String, RuruError)] = [
            (409, #"{"error":"ownership_held"}"#, .ownershipHeld),
            (409, #"{"error":"ownership_expired_or_changed"}"#, .ownershipLost),
            (503, #"{"error":"authority_recovering"}"#, .recovering),
            (401, #"{"error":"unauthorized"}"#, .unauthorized),
            (403, #"{"error":"forbidden_cluster"}"#, .forbidden("forbidden_cluster")),
            (503, #"{"error":"authority_unavailable"}"#, .server(status: 503, code: "authority_unavailable"))
        ]
        for (status, body, expected) in cases {
            StubProtocol.replies = [(status, body)]
            do { _ = try await client().acquire(); XCTFail("Expected \(expected)") }
            catch { XCTAssertEqual(error as? RuruError, expected) }
        }
    }

    func testAGrantNamingAnotherOwnerIsNeverOwnership() async {
        StubProtocol.replies = [(200, #"{"ownerNodeID":"backup","term":9,"expiresInSeconds":30}"#)]
        do { _ = try await client().acquire(); XCTFail() }
        catch { XCTAssertEqual(error as? RuruError, .ownershipHeld) }
    }

    func testMinimumTermReleasesAnInsufficientGrant() async throws {
        StubProtocol.replies = [
            (200, #"{"ownerNodeID":"home","term":7,"expiresInSeconds":30}"#),
            (200, #"{"released":true}"#)
        ]

        do { _ = try await client().acquire(minimumTerm: 8); XCTFail("Accepted an insufficient term") }
        catch { XCTAssertEqual(error as? RuruError, .ownershipLost) }

        XCTAssertEqual(StubProtocol.requests.map(\.url?.path), ["/v1/lease/acquire", "/v1/lease/release"])
        let release = try XCTUnwrap(StubProtocol.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: release.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["term"] as? Int, 7)
    }

    func testMinimumTermAcceptsAMatchingGrant() async throws {
        StubProtocol.replies = [(200, #"{"ownerNodeID":"home","term":8,"expiresInSeconds":30}"#)]

        let lease = try await client().acquire(minimumTerm: 8)

        XCTAssertEqual(lease.term, 8)
        XCTAssertEqual(StubProtocol.requests.map(\.url?.path), ["/v1/lease/acquire"])
    }

    func testDescribeReportsCapabilities() async throws {
        StubProtocol.replies = [(200, #"{"version":1,"authority":"Ruru","clusterID":"bot","leaseSeconds":60,"recoverySeconds":0,"capabilities":{"lease":{"version":1,"enabled":true},"coordination":{"version":1,"enabled":false}},"lease":null}"#)]
        let description = try await client().describe()
        XCTAssertEqual(description.leaseSeconds, 60)
        XCTAssertTrue(description.supports("lease"))
        XCTAssertFalse(description.supports("coordination"))
        XCTAssertFalse(description.supports("lease", version: 2))
        XCTAssertEqual(StubProtocol.requests.first?.httpMethod, "GET")
    }

    func testOperationalStatusUsesSeparateBoundedReportRoute() async throws {
        StubProtocol.replies = [(200, #"{"version":1,"accepted":true,"freshSeconds":45,"reportAfterSeconds":15}"#)]
        try await client().reportOperationalStatus(state: .degraded, components: [
            .init(namespace: "example", id: "sync", state: .degraded, reasonCode: "peer_unreachable")
        ])
        let request = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/operational-status/report")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        XCTAssertEqual(body["state"] as? String, "degraded")
    }
}
