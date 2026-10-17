import CryptoKit
import Foundation

/// A bounded, application-neutral readiness state. It is diagnostic data only;
/// it never grants, renews, releases, or otherwise influences a lease.
public enum OperationalState: String, Codable, Sendable {
    case ready, synchronizing, outdated, degraded, unknown
}

/// One application-defined check, identified by a small stable namespace and ID.
/// `reasonCode` is deliberately a bounded machine code rather than free text.
public struct OperationalComponent: Codable, Sendable, Equatable {
    public let namespace: String
    public let id: String
    public let state: OperationalState
    public let reasonCode: String?

    public init(namespace: String, id: String, state: OperationalState, reasonCode: String? = nil) {
        self.namespace = namespace
        self.id = id
        self.state = state
        self.reasonCode = reasonCode
    }
}

/// A node's report of its non-authoritative operating condition.
public struct OperationalStatusReport: Codable, Sendable {
    public let version: Int
    public let clusterID: String
    public let nodeID: String
    public let nodeName: String?
    public let state: OperationalState
    public let components: [OperationalComponent]

    public init(clusterID: String, nodeID: String, nodeName: String? = nil,
                state: OperationalState, components: [OperationalComponent], version: Int = 1) {
        self.version = version
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.state = state
        self.components = components
    }
}

public struct OperationalStatusObservation: Sendable, Equatable {
    public let clusterID: String
    public let nodeID: String
    public let nodeName: String?
    public let state: OperationalState
    public let components: [OperationalComponent]
    public let ageSeconds: Double
    public let fresh: Bool
}

/// Bounded, in-memory operational observations. They expire after restart or
/// credential replacement, just like presence reports, and deliberately have
/// no dependency on the durable lease store or its transaction path.
public actor OperationalStatusRegistry {
    public static let freshSeconds: Double = 45
    public static let retentionSeconds: Double = 600
    public static let maxNodesPerService = 32
    public static let maxComponents = 16
    private var authorization = WitnessAuthorization()
    private var tokens: [String: Data] = [:]
    private struct Entry { let report: OperationalStatusReport; let at: Double }
    private var entries: [String: [String: Entry]] = [:]
    private let clock: @Sendable () -> Double

    public init(clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    init(services: [WitnessServiceCredential]) throws {
        self.clock = { ProcessInfo.processInfo.systemUptime }
        authorization = try WitnessAuthorization(services: services)
        tokens = Self.tokenHashes(services)
    }

    public func configureServices(_ services: [WitnessServiceCredential]) throws {
        let updated = try WitnessAuthorization(services: services)
        let newTokens = Self.tokenHashes(services)
        entries = entries.filter { newTokens[$0.key] != nil && newTokens[$0.key] == tokens[$0.key] }
        tokens = newTokens
        authorization = updated
    }

    func route(_ request: HTTPRequest) -> LeaseReply {
        guard request.method == "POST", request.path == "/v1/operational-status/report" else {
            return .error("not_found", status: 404)
        }
        guard let identity = authorization.identity(for: request.headers["authorization"]) else {
            return .error("unauthorized", status: 401)
        }
        let cluster = identity.clusterID
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
              let report = try? JSONDecoder().decode(OperationalStatusReport.self, from: request.body),
              report.version == 1, report.clusterID == cluster,
              WitnessPrimaryPreference.validNodeID(report.nodeID),
              report.nodeName == nil || WitnessNodeName.normalized(report.nodeName) != nil,
              identity.permits(nodeID: report.nodeID),
              report.components.count <= Self.maxComponents,
              isValid(report.components) else {
            return .error("invalid_request", status: 400)
        }
        let now = clock()
        prune(at: now)
        guard entries[cluster]?[report.nodeID] != nil || (entries[cluster]?.count ?? 0) < Self.maxNodesPerService else {
            return .error("participant_limit", status: 429)
        }
        entries[cluster, default: [:]][report.nodeID] = Entry(report: report, at: now)
        return LeaseReply(status: 200, body: Data(#"{"version":1,"accepted":true,"freshSeconds":45,"reportAfterSeconds":15}"#.utf8))
    }

    public func snapshot() -> [OperationalStatusObservation] {
        let now = clock()
        prune(at: now)
        return entries.values.flatMap { $0.values }.map {
            let age = max(0, now - $0.at)
            return OperationalStatusObservation(clusterID: $0.report.clusterID, nodeID: $0.report.nodeID,
                nodeName: WitnessNodeName.normalized($0.report.nodeName), state: $0.report.state,
                components: $0.report.components, ageSeconds: age, fresh: age < Self.freshSeconds)
        }.sorted { ($0.clusterID, $0.nodeID) < ($1.clusterID, $1.nodeID) }
    }

    private static func tokenHashes(_ services: [WitnessServiceCredential]) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: services.map { ($0.clusterID, Data(SHA256.hash(data: Data($0.token.utf8)))) })
    }

    private func isValid(_ components: [OperationalComponent]) -> Bool {
        var seen = Set<String>()
        return components.allSatisfy { component in
            let key = component.namespace + "\u{0}" + component.id
            return seen.insert(key).inserted && Self.validCode(component.namespace, limit: 48) &&
                Self.validCode(component.id, limit: 64) &&
                (component.reasonCode == nil || Self.validCode(component.reasonCode!, limit: 64))
        }
    }

    private static func validCode(_ value: String, limit: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= limit && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private func prune(at now: Double) {
        for cluster in Array(entries.keys) {
            entries[cluster] = entries[cluster]?.filter { max(0, now - $0.value.at) < Self.retentionSeconds }
            if entries[cluster]?.isEmpty == true { entries[cluster] = nil }
        }
    }
}
