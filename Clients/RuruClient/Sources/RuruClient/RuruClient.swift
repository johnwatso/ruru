import Foundation

/// Connection details for one Ruru service, as shown in Ruru's Connection Details.
public struct RuruConfiguration: Sendable {
    public var endpoint: URL
    public var clusterID: String
    /// Stable identity of this server. Never derive it from order or a display name.
    public var nodeID: String
    /// Optional readable name shown in Ruru's console.
    public var nodeName: String?
    /// The service's bearer token. Keep it in Keychain or another secret store.
    public var token: String

    public init(endpoint: URL, clusterID: String, nodeID: String, nodeName: String? = nil, token: String) {
        self.endpoint = endpoint
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.token = token
    }
}

/// A granted lease. `term` is a fencing token: send it with every side effect
/// and have downstream systems reject anything older than the newest term seen.
public struct RuruLease: Sendable, Equatable {
    public let term: Int64
    public let ownerNodeID: String
    /// Measured from when the request was *sent*, so it is never later than
    /// Ruru's own deadline. Stop work at this instant if a renewal hasn't landed.
    public let deadline: ContinuousClock.Instant
    public let duration: Duration

    public var isValid: Bool { ContinuousClock.now < deadline }
}

public enum RuruError: Error, Equatable, Sendable {
    /// Another server owns the lease.
    case ownershipHeld
    /// This server's lease expired or was replaced. Stop work immediately.
    case ownershipLost
    /// Ruru restarted and is waiting out earlier leases. Retry later.
    case recovering
    case unauthorized
    case forbidden(String)
    case invalidRequest
    case server(status: Int, code: String)
    case transport(String)
}

/// The service description returned by `GET /v1/service`.
public struct RuruServiceDescription: Decodable, Sendable, Equatable {
    public struct Capability: Decodable, Sendable, Equatable {
        public let version: Int
        public let enabled: Bool
    }
    public struct Lease: Decodable, Sendable, Equatable {
        public let ownerNodeID: String?
        public let term: Int64
        public let remainingSeconds: Double
    }
    public let version: Int
    public let clusterID: String
    public let leaseSeconds: Double
    public let recoverySeconds: Double
    public let capabilities: [String: Capability]
    public let lease: Lease?

    public func supports(_ capability: String, version: Int = 1) -> Bool {
        capabilities[capability].map { $0.enabled && $0.version >= version } ?? false
    }
}

/// What `maintain` reports as ownership changes.
public enum RuruLeaseState: Sendable, Equatable {
    /// This server owns the service. Do work, fenced with `lease.term`.
    case owner(RuruLease)
    /// Another server owns it, or nobody does yet. Do not do exclusive work.
    case standby
    /// Ruru can't be reached or is recovering. Do not do exclusive work.
    case unavailable(RuruError)
}

/// A client for Ruru's lease protocol (`/v1/lease/acquire|renew|release`).
public actor RuruLeaseClient {
    public let configuration: RuruConfiguration
    private let session: URLSession
    private var highestTerm: Int64 = 0

    public init(configuration: RuruConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.session = session
    }

    /// Requests ownership. Succeeds for the current owner too (same term).
    public func acquire() async throws -> RuruLease {
        try await lease(.acquire, term: highestTerm)
    }

    /// Extends `lease`. Throws `ownershipLost` if it expired or changed hands.
    public func renew(_ lease: RuruLease) async throws -> RuruLease {
        try await self.lease(.renew, term: lease.term)
    }

    /// Gives up ownership so another server can take over without waiting.
    public func release(_ lease: RuruLease) async throws {
        _ = try await send("/v1/lease/release", body: request(term: lease.term))
    }

    /// The service's capabilities, lease length and current state.
    public func describe() async throws -> RuruServiceDescription {
        let data = try await send("/v1/service", body: nil)
        do { return try JSONDecoder().decode(RuruServiceDescription.self, from: data) }
        catch { throw RuruError.server(status: 200, code: "invalid_response") }
    }

    /// Keeps ownership for as long as the calling task runs, reporting each
    /// change to `onChange`. Renews at a third of the lease; if renewals fail it
    /// reports `unavailable` no later than the local deadline. Cancelling the
    /// task releases the lease (best effort) and returns.
    public func maintain(retryInterval: Duration = .seconds(5),
                         onChange: @escaping @Sendable (RuruLeaseState) async -> Void) async {
        var state: RuruLeaseState?
        var current: RuruLease?
        func report(_ next: RuruLeaseState) async {
            guard next != state else { return }
            state = next
            await onChange(next)
        }
        while !Task.isCancelled {
            if let lease = current {
                let renewAt = lease.deadline - lease.duration * 2 / 3
                try? await Task.sleep(until: renewAt, clock: .continuous)
                if Task.isCancelled { break }
                do {
                    current = try await renew(lease)
                    await report(.owner(current!))
                } catch RuruError.ownershipLost {
                    current = nil
                    await report(.standby)
                } catch {
                    // Keep trying until the local deadline, then stop being owner.
                    var outcome = RuruLeaseState.unavailable(error as? RuruError ?? .transport("\(error)"))
                    retrying: while !Task.isCancelled, lease.isValid {
                        try? await Task.sleep(for: min(.seconds(1), lease.duration / 10))
                        do {
                            let renewed = try await renew(lease)
                            current = renewed
                            outcome = .owner(renewed)
                            break retrying
                        } catch RuruError.ownershipLost {
                            outcome = .standby
                            break retrying
                        } catch { continue }
                    }
                    if case .owner = outcome {} else { current = nil }
                    await report(outcome)
                }
            } else {
                do {
                    current = try await acquire()
                    await report(.owner(current!))
                    continue
                } catch RuruError.ownershipHeld {
                    await report(.standby)
                } catch {
                    await report(.unavailable(error as? RuruError ?? .transport("\(error)")))
                }
                try? await Task.sleep(for: Self.jittered(retryInterval))
            }
        }
        // URLSession aborts requests from a cancelled task, so release from a
        // fresh task; otherwise the next owner waits for the lease to expire.
        if let current, current.isValid {
            await Task { try? await self.release(current) }.value
        }
    }

    // MARK: Protocol

    private enum Action: String { case acquire, renew }

    private struct LeaseRequest: Encodable {
        let clusterID: String
        let nodeID: String
        let term: Int64
        let nodeName: String?
    }

    private struct LeaseGrant: Decodable {
        let ownerNodeID: String
        let term: Int64
        let expiresInSeconds: Double
    }

    private func request(term: Int64) throws -> Data {
        try JSONEncoder().encode(LeaseRequest(clusterID: configuration.clusterID, nodeID: configuration.nodeID,
                                              term: term, nodeName: configuration.nodeName))
    }

    private func lease(_ action: Action, term: Int64) async throws -> RuruLease {
        let sent = ContinuousClock.now
        let data = try await send("/v1/lease/" + action.rawValue, body: request(term: term))
        guard let grant = try? JSONDecoder().decode(LeaseGrant.self, from: data), grant.expiresInSeconds > 0 else {
            throw RuruError.server(status: 200, code: "invalid_response")
        }
        // A grant naming another owner is never ownership.
        guard grant.ownerNodeID == configuration.nodeID, grant.term >= highestTerm else { throw RuruError.ownershipHeld }
        highestTerm = grant.term
        let duration = Duration.milliseconds(Int64(grant.expiresInSeconds * 1000))
        return RuruLease(term: grant.term, ownerNodeID: grant.ownerNodeID, deadline: sent + duration, duration: duration)
    }

    private func send(_ path: String, body: Data?) async throws -> Data {
        var request = URLRequest(url: configuration.endpoint.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue("Bearer " + configuration.token, forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw RuruError.transport(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if (200..<300).contains(status) { return data }
        let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? ""
        switch (status, code) {
        case (409, "ownership_held"): throw RuruError.ownershipHeld
        case (409, _): throw RuruError.ownershipLost
        case (503, "authority_recovering"): throw RuruError.recovering
        case (401, _): throw RuruError.unauthorized
        case (403, _): throw RuruError.forbidden(code)
        case (400, _): throw RuruError.invalidRequest
        default: throw RuruError.server(status: status, code: code)
        }
    }

    private static func jittered(_ interval: Duration) -> Duration {
        interval * Double.random(in: 0.8...1.2)
    }
}
