import Foundation
import RuruClient
import XCTest

final class RuruClientSafetyTests: XCTestCase {
    private func client(_ handler: @escaping @Sendable (Int, URLRequest) -> LeaseSafetyProtocol.Reply) -> RuruLeaseClient {
        LeaseSafetyProtocol.configure(handler)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LeaseSafetyProtocol.self]
        let session = URLSession(configuration: configuration)
        addTeardownBlock { session.invalidateAndCancel() }
        return RuruLeaseClient(configuration: .init(endpoint: URL(string: "https://ruru.example.com")!,
            clusterID: "bot", nodeID: "home", token: "test-only-token"), session: session)
    }

    private static func grant(seconds: Double = 30, term: Int64 = 7) -> String {
        "{\"ownerNodeID\":\"home\",\"term\":\(term),\"expiresInSeconds\":\(seconds)}"
    }

    func testStalledRenewalStopsAtLocalDeadline() async throws {
        let owner = expectation(description: "owner")
        let stopped = expectation(description: "stopped before the transport timeout")
        let client = client { index, _ in
            index == 0 ? .response(Self.grant(seconds: 0.6)) : .stalled
        }
        let wasOwner = SafetyOwnershipLog()
        let task = Task {
            await client.maintain { state in
                if case .owner(let lease) = state {
                    XCTAssertTrue(lease.isValid)
                    await wasOwner.set()
                    owner.fulfill()
                } else if await wasOwner.take() { stopped.fulfill() }
            }
        }
        await fulfillment(of: [owner, stopped], timeout: 2)
        task.cancel()
        await task.value
    }

    func testCancellationStopsAndDrainsBeforeRelease() async throws {
        let owner = expectation(description: "owner")
        let stopped = expectation(description: "stop callback completed")
        let client = client { _, request in
            .response(request.url?.path.hasSuffix("release") == true ? "{\"released\":true}" : Self.grant())
        }
        let task = Task {
            await client.maintain { state in
                if case .owner = state { owner.fulfill() }
                if state == .standby {
                    XCTAssertFalse(Task.isCancelled)
                    XCTAssertFalse(LeaseSafetyProtocol.paths.contains("/v1/lease/release"))
                    try? await Task.sleep(for: .milliseconds(50))
                    XCTAssertFalse(LeaseSafetyProtocol.paths.contains("/v1/lease/release"))
                    stopped.fulfill()
                }
            }
        }
        await fulfillment(of: [owner], timeout: 2)
        task.cancel()
        await task.value
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(LeaseSafetyProtocol.paths.last, "/v1/lease/release")
    }

    func testDelayedGrantIsRejectedAfterItsDeadline() async {
        let client = client { _, _ in .response(Self.grant(seconds: 0.1), delay: 0.2) }
        do { _ = try await client.acquire(); XCTFail("Accepted expired permission") }
        catch { XCTAssertEqual(error as? RuruError, .ownershipLost) }
    }

    func testCancellationDuringStalledRenewalStillReleasesAfterStopping() async throws {
        let renewing = expectation(description: "renewal is blocked")
        let stopped = expectation(description: "stop callback")
        let client = client { _, request in
            switch request.url!.lastPathComponent {
            case "acquire": return .response(Self.grant(seconds: 1.2))
            case "renew": renewing.fulfill(); return .stalled
            default: return .response("{\"released\":true}")
            }
        }
        let task = Task {
            await client.maintain { state in
                if state == .standby {
                    XCTAssertFalse(LeaseSafetyProtocol.paths.contains("/v1/lease/release"))
                    stopped.fulfill()
                }
            }
        }
        await fulfillment(of: [renewing], timeout: 2)
        task.cancel()
        await task.value
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(LeaseSafetyProtocol.paths.last, "/v1/lease/release")
    }

    func testMalformedGrantBoundsDoNotCrashOrGrantOwnership() async {
        for (seconds, term) in [(1e100, Int64(1)), (301, 1), (0, 1), (30, 0), (30, -1), (30, 1 << 62)] {
            let client = client { _, _ in .response(Self.grant(seconds: seconds, term: term)) }
            do { _ = try await client.acquire(); XCTFail("Accepted an invalid grant") }
            catch { XCTAssertEqual(error as? RuruError, .server(status: 200, code: "invalid_response")) }
        }
    }

    func testRenewalCannotSubstituteADifferentTerm() async throws {
        let client = client { index, _ in .response(Self.grant(term: index == 0 ? 7 : 8)) }
        let lease = try await client.acquire()
        do { _ = try await client.renew(lease); XCTFail("Accepted a different ownership epoch") }
        catch { XCTAssertEqual(error as? RuruError, .ownershipLost) }
    }

    func testDeadlineIncludesAStoppingMargin() async throws {
        let client = client { _, _ in .response(Self.grant()) }
        let began = ContinuousClock.now
        let lease = try await client.acquire()
        XCTAssertEqual(lease.duration, .seconds(30))
        XCTAssertLessThanOrEqual(lease.deadline, ContinuousClock.now + .seconds(28))
        XCTAssertGreaterThanOrEqual(lease.deadline, began + .seconds(28))
    }
}

private actor SafetyOwnershipLog {
    private var owning = false
    func set() { owning = true }
    func take() -> Bool {
        let previous = owning
        owning = false
        return previous
    }
}

/// Isolated transport faults: no production listener, storage or credentials.
private final class LeaseSafetyProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(String, delay: Double = 0)
        case stalled
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Int, URLRequest) -> Reply)?
    nonisolated(unsafe) private static var recordedPaths: [String] = []
    private let stateLock = NSLock()
    private var stopped = false

    static var paths: [String] { lock.withLock { recordedPaths } }
    static func configure(_ handler: @escaping @Sendable (Int, URLRequest) -> Reply) {
        lock.withLock { Self.handler = handler; recordedPaths = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Reply = Self.lock.withLock {
            let index = Self.recordedPaths.count
            Self.recordedPaths.append(request.url!.path)
            return Self.handler!(index, request)
        }
        guard case .response(let body, let delay) = reply else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            stateLock.withLock {
                guard !stopped else { return }
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                    httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() { stateLock.withLock { stopped = true } }
}
