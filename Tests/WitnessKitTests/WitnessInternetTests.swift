import Foundation
import XCTest
@testable import WitnessKit

final class WitnessInternetTests: XCTestCase {
    private let tunnelID = "86d3b00a-84d7-4b0b-a006-d59fce271d62"
    private let hostname = "witness.example.com"

    private func session(existingDNS: [[String: Any]] = [], existingTunnel: Bool = false,
                         failurePath: String? = nil) -> URLSession {
        let id = tunnelID
        let hostname = hostname
        MockCloudflare.install { request in
            let path = request.url!.path
            let body = MockCloudflare.body(request)
            if path == failurePath { return (200, ["success": false, "errors": [["message": "Permission denied"]]]) }
            let result: Any
            switch (request.httpMethod ?? "GET", path) {
            case (_, "/client/v4/user/tokens/verify"): result = ["status": "active"]
            case (_, "/client/v4/zones"):
                result = [["id": "zone", "name": "example.com", "account": ["id": "account"]]]
            case ("GET", "/client/v4/zones/zone/dns_records"): result = existingDNS
            case ("POST", "/client/v4/zones/zone/dns_records"):
                // Current DNS API replies need not contain the old zone_id field.
                result = ["id": "dns", "type": "CNAME", "name": hostname, "content": "\(id).cfargotunnel.com"]
            case ("GET", "/client/v4/accounts/account/cfd_tunnel"):
                let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value ?? ""
                result = existingTunnel ? [["id": id, "name": name]] : []
            case ("POST", "/client/v4/accounts/account/cfd_tunnel"):
                result = ["id": id, "name": body["name"] as? String ?? "", "token": "test-connector-secret"]
            case (_, "/client/v4/accounts/account/cfd_tunnel/\(id)/token"): result = "test-connector-secret"
            case (_, "/client/v4/accounts/account/cfd_tunnel/\(id)/configurations"): result = [:] as [String: String]
            default: throw NSError(domain: "UnexpectedCloudflareRequest", code: 1)
            }
            return (200, ["success": true, "result": result, "errors": []])
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockCloudflare.self]
        let session = URLSession(configuration: config)
        addTeardownBlock { session.invalidateAndCancel() }
        return session
    }

    func testCreatesIndependentTunnelLoopbackRouteAndProxiedDNS() async throws {
        let session = session()
        let settings = WitnessTunnelSettings()
        let checkpoints = Checkpoints()
        let result = try await WitnessInternetSetup(session: session).provision(apiToken: "Bearer test-api-secret",
            hostname: "https://witness.example.com/", settings: settings, port: 38990,
            checkpoint: { await checkpoints.append($0) })
        XCTAssertTrue(result.settings.enabled)
        XCTAssertEqual(result.settings.tunnelID, tunnelID)
        XCTAssertEqual(result.connectorToken, "test-connector-secret")
        let saved = await checkpoints.values
        XCTAssertEqual(saved.count, 1)
        XCTAssertFalse(saved[0].settings.enabled)
        let requests = MockCloudflare.requests
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-api-secret" })
        let created = try XCTUnwrap(requests.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("cfd_tunnel") })
        XCTAssertEqual(MockCloudflare.body(created)["name"] as? String, settings.name)
        XCTAssertTrue(settings.name.hasPrefix("ruru-"))
        let configured = try XCTUnwrap(requests.first { $0.httpMethod == "PUT" })
        let config = try XCTUnwrap(MockCloudflare.body(configured)["config"] as? [String: Any])
        let ingress = try XCTUnwrap(config["ingress"] as? [[String: Any]])
        XCTAssertEqual(ingress.count, 2)
        XCTAssertEqual(ingress[0]["hostname"] as? String, hostname)
        XCTAssertEqual(ingress[0]["service"] as? String, "http://127.0.0.1:38990")
        XCTAssertEqual(ingress[1]["service"] as? String, "http_status:404")
        let dns = try XCTUnwrap(requests.first { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("dns_records") })
        XCTAssertEqual(MockCloudflare.body(dns)["proxied"] as? Bool, true)
        XCTAssertEqual(MockCloudflare.body(dns)["content"] as? String, "\(tunnelID).cfargotunnel.com")
        let encoded = String(decoding: try JSONEncoder().encode(result.settings), as: UTF8.self)
        XCTAssertFalse(encoded.contains("test-api-secret"))
        XCTAssertFalse(encoded.contains("test-connector-secret"))
    }

    func testConflictingDNSIsRejectedBeforeAnyCloudflareWrite() async throws {
        for record in [["id": "other", "type": "A", "name": hostname, "content": "192.0.2.1"],
                       ["id": "other", "type": "CNAME", "name": hostname, "content": "bot.cfargotunnel.com"]] {
            let session = session(existingDNS: [record])
            do {
                _ = try await WitnessInternetSetup(session: session).provision(apiToken: "test", hostname: hostname,
                    settings: WitnessTunnelSettings(), port: 38990)
                XCTFail("Conflicting DNS was accepted")
            } catch WitnessInternetSetup.SetupError.hostnameInUse { }
            XCTAssertFalse(MockCloudflare.requests.contains { ["POST", "PUT", "DELETE"].contains($0.httpMethod ?? "") })
        }
    }

    func testCheckpointFailureCannotPublishRouteOrDNS() async throws {
        let session = session()
        do {
            _ = try await WitnessInternetSetup(session: session).provision(apiToken: "test", hostname: hostname,
                settings: WitnessTunnelSettings(), port: 38990,
                checkpoint: { _ in throw NSError(domain: "storage", code: 1) })
            XCTFail("Failed checkpoint was ignored")
        } catch { XCTAssertEqual((error as NSError).domain, "storage") }
        XCTAssertFalse(MockCloudflare.requests.contains { $0.httpMethod == "PUT" || ($0.httpMethod == "POST" && $0.url!.path.hasSuffix("dns_records")) })
    }

    func testReconnectReusesOnlyThisWitnessTunnelAndDNS() async throws {
        let session = session(existingDNS: [["id": "dns", "type": "CNAME", "name": hostname, "content": "\(tunnelID).cfargotunnel.com"]], existingTunnel: true)
        var settings = WitnessTunnelSettings()
        settings.hostname = hostname; settings.tunnelID = tunnelID; settings.accountID = "account"
        let result = try await WitnessInternetSetup(session: session).provision(apiToken: "test", hostname: hostname,
            settings: settings, port: 38990)
        XCTAssertEqual(result.settings.instanceID, settings.instanceID)
        XCTAssertEqual(result.settings.tunnelID, tunnelID)
        XCTAssertTrue(result.settings.enabled)
        XCTAssertFalse(MockCloudflare.requests.contains { $0.httpMethod == "POST" || $0.httpMethod == "DELETE" })
    }

    func testCloudflareSuccessFalsePreventsPublishingEvenWithHTTP200() async throws {
        let session = session(failurePath: "/client/v4/accounts/account/cfd_tunnel/\(tunnelID)/configurations")
        do {
            _ = try await WitnessInternetSetup(session: session).provision(apiToken: "test", hostname: hostname,
                settings: WitnessTunnelSettings(), port: 38990)
            XCTFail("Permission denial ignored")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Permission denied")) }
        XCTAssertFalse(MockCloudflare.requests.contains { $0.httpMethod == "POST" && $0.url!.path.hasSuffix("dns_records") })
    }

    func testInvalidHostnamesAndHeaderInjectionNeverReachAPI() async throws {
        let session = session()
        for hostname in ["localhost", "127.0.0.1", "https://user@example.com", "witness.example.com/path", "http://witness.example.com",
                         "witness.example.com:443", "witness..example.com", "-witness.example.com", "witness.example.com?x=1"] {
            XCTAssertNil(WitnessInternetSetup.normalizedHostname(hostname))
            do {
                _ = try await WitnessInternetSetup(session: session).provision(apiToken: "test", hostname: hostname,
                    settings: WitnessTunnelSettings(), port: 38990)
                XCTFail("Invalid host accepted")
            } catch { }
        }
        do {
            _ = try await WitnessInternetSetup(session: session).provision(apiToken: "token\r\nmalicious", hostname: self.hostname,
                settings: WitnessTunnelSettings(), port: 38990)
            XCTFail("Header injection accepted")
        } catch { }
        XCTAssertTrue(MockCloudflare.requests.isEmpty)
    }

    func testZonesOnLaterPagesAreDetected() async throws {
        let session = session()
        MockCloudflare.install { request in
            let page = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            let zones: [[String: String]] = page == "2" ? [["id": "wanted", "name": "example.co.nz"]]
                : (0..<50).map { ["id": "\($0)", "name": "zone\($0).com"] }
            return (200, ["success": true, "result": zones])
        }
        let zones = try await CloudflareDNSProvider(apiToken: "test", session: session).listZones()
        XCTAssertEqual(zones.count, 51)
        XCTAssertEqual(zones.last?.name, "example.co.nz")
        XCTAssertEqual(MockCloudflare.requests.count, 2)
    }

    func testHealthWithCacheBustingQueryStillReportsOnlyReadiness() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try LeaseStore(databaseURL: directory.appendingPathComponent("leases.duckdb"))
        let router = try WitnessRouter(store: store, clusterID: "test", token: String(repeating: "x", count: 40))
        let response = await router.route(HTTPRequest(method: "GET", path: "/health?probe=random", headers: [:], body: Data()))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(String(decoding: response.body, as: UTF8.self), #"{"ready":true}"#)
    }
}

private actor Checkpoints {
    var values: [ProvisionedWitnessTunnel] = []
    func append(_ result: ProvisionedWitnessTunnel) { values.append(result) }
}

private final class MockCloudflare: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var callback: ((URLRequest) throws -> (Int, [String: Any]))?
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    static func install(_ handler: @escaping (URLRequest) throws -> (Int, [String: Any])) {
        lock.withLock { callback = handler; captured = [] }
    }
    static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                guard count > 0 else { break }
                data.append(contentsOf: bytes.prefix(count))
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            // Preserve bodies after URLSession turns them into one-shot streams.
            var capturedRequest = request
            let body = Self.body(request)
            if !body.isEmpty { capturedRequest.httpBody = try JSONSerialization.data(withJSONObject: body) }
            let handler = Self.lock.withLock { Self.captured.append(capturedRequest); return Self.callback }
            let (status, json) = try XCTUnwrap(handler)(capturedRequest)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: json))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
