import Foundation
import CryptoKit

/// A participant's own description, never authority to execute work.
public enum ParticipantRole: String, Codable, Sendable {
    case active, standby, worker, unknown
}

/// A participant's self-reported power source. This is display telemetry only.
public enum ParticipantPowerSource: String, Codable, Sendable {
    case ac, ups, battery, unknown
}

/// A reported, display-only website. No credentials, paths or probes.
public enum ParticipantWebUI {
    public static func normalizedURL(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 256,
              let origin = CoordinationPolicy.normalizedOrigin(value),
              let host = URL(string: origin)?.host,
              host.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || [45, 46, 58, 91, 93].contains($0) }) else { return nil }
        return origin
    }
}

public struct ParticipantReport: Codable, Sendable {
    public let version: Int
    public let clusterID: String
    public let nodeID: String
    public let nodeName: String?
    public let role: ParticipantRole
    public let webUIURL: String?
    public let powerSource: ParticipantPowerSource?
    public let externalPower: Bool?
    public let batteryPercent: Int?
    public let batteryTimeRemaining: Int?
    public let sessionEnding: Bool?

    public init(clusterID: String, nodeID: String, nodeName: String? = nil,
                role: ParticipantRole = .unknown, version: Int = 1, webUIURL: String? = nil,
                powerSource: ParticipantPowerSource? = nil, externalPower: Bool? = nil,
                batteryPercent: Int? = nil, batteryTimeRemaining: Int? = nil,
                sessionEnding: Bool? = nil) {
        self.version = version
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.role = role
        self.webUIURL = webUIURL
        self.powerSource = powerSource
        self.externalPower = externalPower
        self.batteryPercent = batteryPercent
        self.batteryTimeRemaining = batteryTimeRemaining
        self.sessionEnding = sessionEnding
    }
}

public struct ParticipantObservation: Sendable {
    public let clusterID: String
    public let nodeID: String
    public let nodeName: String?
    public let role: ParticipantRole
    public let ageSeconds: Double
    public let fresh: Bool
    public let webUIURL: String?
    public let powerSource: ParticipantPowerSource?
    public let externalPower: Bool?
    public let batteryPercent: Int?
    public let batteryTimeRemaining: Int?
    public let sessionEnding: Bool?

    public init(clusterID: String, nodeID: String, nodeName: String?, role: ParticipantRole,
                ageSeconds: Double, fresh: Bool, webUIURL: String? = nil,
                powerSource: ParticipantPowerSource? = nil, externalPower: Bool? = nil,
                batteryPercent: Int? = nil, batteryTimeRemaining: Int? = nil,
                sessionEnding: Bool? = nil) {
        self.clusterID = clusterID; self.nodeID = nodeID; self.nodeName = nodeName
        self.role = role; self.ageSeconds = ageSeconds; self.fresh = fresh
        self.webUIURL = webUIURL
        self.powerSource = powerSource; self.externalPower = externalPower
        self.batteryPercent = batteryPercent; self.batteryTimeRemaining = batteryTimeRemaining
        self.sessionEnding = sessionEnding
    }
}

/// Bounded ephemeral contact reports, isolated from durable leases and their clock.
/// A service token authenticates the group, not the claimed individual node ID.
public actor ParticipantPresence {
    public static let freshSeconds: Double = 45
    public static let retentionSeconds: Double = 600
    public static let maxNodesPerService = 32
    private var authorization = WitnessAuthorization()
    private var tokens: [String: Data] = [:]
    private struct Entry { let report: ParticipantReport; let at: Double }
    private var entries: [String: [String: Entry]] = [:]
    private let clock: @Sendable () -> Double

    public init(clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    init(services: [WitnessServiceCredential]) throws {
        self.clock = { ProcessInfo.processInfo.systemUptime }
        authorization = try WitnessAuthorization(services: services)
        tokens = Dictionary(uniqueKeysWithValues: services.map { ($0.clusterID, Data(SHA256.hash(data: Data($0.token.utf8)))) })
    }

    public func configureServices(_ services: [WitnessServiceCredential]) throws {
        let updated = try WitnessAuthorization(services: services)
        let newTokens = Dictionary(uniqueKeysWithValues: services.map { ($0.clusterID, Data(SHA256.hash(data: Data($0.token.utf8)))) })
        // Removal or credential replacement revokes prior observations too.
        entries = entries.filter { newTokens[$0.key] != nil && newTokens[$0.key] == tokens[$0.key] }
        tokens = newTokens
        authorization = updated
    }

    func route(_ request: HTTPRequest) -> LeaseReply {
        guard request.method == "POST", request.path == "/v1/participants/report" else {
            return .error("not_found", status: 404)
        }
        guard let cluster = authorization.cluster(for: request.headers["authorization"]) else {
            return .error("unauthorized", status: 401)
        }
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
              let report = try? JSONDecoder().decode(ParticipantReport.self, from: request.body),
              WitnessPrimaryPreference.validNodeID(report.nodeID),
              report.nodeName == nil || WitnessNodeName.normalized(report.nodeName) != nil,
              report.webUIURL == nil || ParticipantWebUI.normalizedURL(report.webUIURL) != nil else {
            return .error("invalid_request", status: 400)
        }
        // Reject impossible readings rather than turning them into false warnings.
        guard report.batteryPercent.map({ (0...100).contains($0) }) ?? true,
              report.batteryTimeRemaining.map({ (0...604_800).contains($0) }) ?? true else {
            return .error("invalid_request", status: 400)
        }
        guard report.clusterID == cluster else { return .error("forbidden_cluster", status: 403) }
        guard report.version == 1 else { return .error("unsupported_version", status: 409) }
        let now = clock()
        prune(at: now)
        guard entries[cluster]?[report.nodeID] != nil || (entries[cluster]?.count ?? 0) < Self.maxNodesPerService else {
            return .error("participant_limit", status: 429)
        }
        entries[cluster, default: [:]][report.nodeID] = Entry(report: report, at: now)
        return LeaseReply(status: 200, body: Data(#"{"version":1,"accepted":true,"freshSeconds":45,"reportAfterSeconds":15}"#.utf8))
    }

    public func snapshot() -> [ParticipantObservation] {
        let now = clock()
        prune(at: now)
        return entries.values.flatMap { $0.values }.map {
            let age = max(0, now - $0.at)
            return ParticipantObservation(clusterID: $0.report.clusterID, nodeID: $0.report.nodeID,
                nodeName: WitnessNodeName.normalized($0.report.nodeName), role: $0.report.role,
                ageSeconds: age, fresh: age < Self.freshSeconds,
                webUIURL: age < Self.freshSeconds ? ParticipantWebUI.normalizedURL($0.report.webUIURL) : nil,
                powerSource: $0.report.powerSource, externalPower: $0.report.externalPower,
                batteryPercent: $0.report.batteryPercent,
                batteryTimeRemaining: $0.report.batteryTimeRemaining,
                sessionEnding: $0.report.sessionEnding)
        }.sorted { ($0.clusterID, $0.nodeID) < ($1.clusterID, $1.nodeID) }
    }

    private func prune(at now: Double) {
        for cluster in Array(entries.keys) {
            entries[cluster] = entries[cluster]?.filter { max(0, now - $0.value.at) < Self.retentionSeconds }
            if entries[cluster]?.isEmpty == true { entries[cluster] = nil }
        }
    }
}
