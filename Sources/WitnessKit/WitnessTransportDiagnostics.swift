import Foundation

/// A bounded, read-only view of the three hops required for managed Internet
/// Access. It is operational telemetry only: none of these observations grant,
/// renew, release, or otherwise influence a lease.
public struct WitnessTransportDiagnostics: Sendable, Equatable {
    public enum Health: String, Sendable, Equatable {
        /// The endpoint returned Ruru's normal ready response.
        case ready
        /// The endpoint was reachable but Ruru is in restart recovery.
        case recovering
        /// The endpoint could not be reached or did not return Ruru health JSON.
        case unavailable
        /// This hop has not been configured, so no request was attempted.
        case notConfigured
    }

    public struct Hop: Sendable, Equatable {
        public let health: Health
        /// A short, credential-free explanation suitable for an operator UI.
        public let detail: String
        public let checkedAt: Date?

        public init(health: Health, detail: String, checkedAt: Date?) {
            self.health = health
            self.detail = detail
            self.checkedAt = checkedAt
        }
    }

    public struct Connector: Sendable, Equatable {
        public let state: WitnessInternetStatus.State
        public let retryAttempts: Int
        public let retryExhausted: Bool
        public let lastPublicHealthSuccess: Date?
        public let consecutivePublicHealthFailures: Int

        public init(state: WitnessInternetStatus.State, retryAttempts: Int,
                    retryExhausted: Bool, lastPublicHealthSuccess: Date?,
                    consecutivePublicHealthFailures: Int) {
            self.state = state
            self.retryAttempts = retryAttempts
            self.retryExhausted = retryExhausted
            self.lastPublicHealthSuccess = lastPublicHealthSuccess
            self.consecutivePublicHealthFailures = consecutivePublicHealthFailures
        }
    }

    public let localListener: Hop
    public let connector: Connector
    public let publicHealth: Hop

    public init(localListener: Hop, connector: Connector, publicHealth: Hop) {
        self.localListener = localListener
        self.connector = connector
        self.publicHealth = publicHealth
    }
}

/// Performs the local-listener and public-health parts of an explicit
/// Internet Access check. Requests are GET-only, cache-bypassing, and bounded;
/// callers supply connector telemetry separately because probing cannot infer a
/// process's state.
public actor WitnessTransportProbe {
    private let session: URLSession
    private let now: @Sendable () -> Date

    public init(session: URLSession = .shared, now: @escaping @Sendable () -> Date = Date.init) {
        self.session = session
        self.now = now
    }

    public func inspect(localEndpoint: URL?, publicEndpoint: URL?,
                        connector: WitnessTransportDiagnostics.Connector) async -> WitnessTransportDiagnostics {
        async let local = check(endpoint: localEndpoint)
        async let remote = check(endpoint: publicEndpoint)
        return await WitnessTransportDiagnostics(localListener: local, connector: connector, publicHealth: remote)
    }

    private func check(endpoint: URL?) async -> WitnessTransportDiagnostics.Hop {
        guard let endpoint else {
            return .init(health: .notConfigured, detail: "Not configured", checkedAt: nil)
        }
        let checkedAt = now()
        var components = URLComponents(url: endpoint.appendingPathComponent("health"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "probe", value: UUID().uuidString)]
        guard let url = components?.url else {
            return .init(health: .unavailable, detail: "Invalid health address", checkedAt: checkedAt)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            guard body?["ready"] is Bool else {
                return .init(health: .unavailable, detail: "Unexpected health response", checkedAt: checkedAt)
            }
            switch status {
            case 200:
                return .init(health: .ready, detail: "Ready", checkedAt: checkedAt)
            case 503:
                return .init(health: .recovering, detail: "Ruru is recovering", checkedAt: checkedAt)
            default:
                return .init(health: .unavailable, detail: "Health check returned HTTP \(status)", checkedAt: checkedAt)
            }
        } catch {
            return .init(health: .unavailable, detail: "Health check could not connect", checkedAt: checkedAt)
        }
    }
}
