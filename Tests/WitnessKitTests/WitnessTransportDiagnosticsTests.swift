import Foundation
import XCTest
@testable import WitnessKit

final class WitnessTransportDiagnosticsTests: XCTestCase {
    private func probe() -> WitnessTransportProbe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportProbeProtocol.self]
        return WitnessTransportProbe(
            session: URLSession(configuration: configuration),
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private var connector: WitnessTransportDiagnostics.Connector {
        .init(state: .enabled, retryAttempts: 0, retryExhausted: false,
              lastPublicHealthSuccess: Date(timeIntervalSince1970: 1_699_999_940),
              consecutivePublicHealthFailures: 0)
    }

    func testInspectionKeepsReadyAndRecoveringDistinct() async {
        TransportProbeProtocol.replies = [
            "local.ruru.test": (200, #"{"ready":true}"#),
            "public.ruru.test": (503, #"{"ready":false}"#)
        ]

        let result = await probe().inspect(
            localEndpoint: URL(string: "http://local.ruru.test:38990")!,
            publicEndpoint: URL(string: "https://public.ruru.test")!,
            connector: connector
        )

        XCTAssertEqual(result.localListener.health, .ready)
        XCTAssertEqual(result.publicHealth.health, .recovering)
        XCTAssertEqual(result.connector.state, .enabled)
        XCTAssertEqual(result.publicHealth.checkedAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testInspectionDoesNotTreatMalformedOrMissingEndpointsAsReady() async {
        TransportProbeProtocol.replies = ["local.ruru.test": (200, "not-json")]
        let result = await probe().inspect(
            localEndpoint: URL(string: "http://local.ruru.test:38990")!,
            publicEndpoint: nil,
            connector: connector
        )

        XCTAssertEqual(result.localListener.health, .unavailable)
        XCTAssertEqual(result.publicHealth.health, .notConfigured)
        XCTAssertEqual(result.publicHealth.checkedAt, nil)
    }
}

private final class TransportProbeProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String: (Int, String)] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = Self.replies[request.url?.host ?? ""] ?? (500, "{}")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil
        )!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
