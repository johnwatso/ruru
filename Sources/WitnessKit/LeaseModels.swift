import Foundation

public enum LeaseAction: String, Codable, Sendable {
    case acquire, renew, release
}

public struct LeaseRequest: Codable, Sendable {
    public let clusterID: String
    public let nodeID: String
    public let term: Int64
    public let nodeName: String?

    public init(clusterID: String, nodeID: String, term: Int64, nodeName: String? = nil) {
        self.clusterID = clusterID
        self.nodeID = nodeID
        self.term = term
        self.nodeName = nodeName
    }
}

public struct LeaseGrant: Codable, Equatable, Sendable {
    public let ownerNodeID: String
    public let term: Int64
    public let expiresInSeconds: Double
}

public struct LeaseReply: Sendable {
    public let status: Int
    public let body: Data

    static func grant(_ grant: LeaseGrant) throws -> Self {
        Self(status: 200, body: try JSONEncoder().encode(grant))
    }

    static func error(_ name: String, status: Int) -> Self {
        Self(status: status, body: (try? JSONEncoder().encode(["error": name])) ?? Data())
    }

    static let released = Self(status: 200, body: Data(#"{"released":true}"#.utf8))
}

public struct LeaseStatus: Identifiable, Sendable {
    public var id: String { clusterID }
    public let clusterID: String
    public let ownerNodeID: String
    public let term: Int64
    public let remainingSeconds: Double
    public let ownerNodeName: String?

    public init(clusterID: String, ownerNodeID: String, term: Int64, remainingSeconds: Double, ownerNodeName: String? = nil) {
        self.clusterID = clusterID; self.ownerNodeID = ownerNodeID; self.term = term
        self.remainingSeconds = remainingSeconds; self.ownerNodeName = ownerNodeName
    }
}

public struct WitnessEvent: Identifiable, Sendable {
    public let clusterID: String
    public let id: Int64
    public let time: Date
    public let action: String
    public let nodeID: String
    public let term: Int64
    public let nodeName: String?

    public init(clusterID: String, id: Int64, time: Date, action: String, nodeID: String, term: Int64, nodeName: String? = nil) {
        self.clusterID = clusterID; self.id = id; self.time = time; self.action = action
        self.nodeID = nodeID; self.term = term; self.nodeName = nodeName
    }
}

/// Cosmetic metadata only. Ownership always uses the unchanged node ID and term.
public enum WitnessNodeName {
    public static func normalized(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, name.utf8.count <= 256,
              name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return name
    }
}

public struct WitnessSnapshot: Sendable {
    public let recoverySeconds: Double
    public let leases: [LeaseStatus]
    public let events: [WitnessEvent]

    public init(recoverySeconds: Double, leases: [LeaseStatus], events: [WitnessEvent]) {
        self.recoverySeconds = recoverySeconds; self.leases = leases; self.events = events
    }
}

enum WitnessError: LocalizedError {
    case database(String)
    case alreadyRunning
    case invalidConfiguration
    case stopped
    case listenerUnavailable

    var errorDescription: String? {
        switch self {
        case .database(let message): "Ownership database: \(message)"
        case .alreadyRunning: "Another witness process is using this ownership database."
        case .invalidConfiguration: "The listener address, port, cluster ID, or bearer token is invalid."
        case .stopped: "The listener was stopped before it became ready."
        case .listenerUnavailable: "The listener could not start. Check its port and network address."
        }
    }
}
