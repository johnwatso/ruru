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

/// Durable display history for self-reported participant telemetry. These
/// records are informational only and never participate in lease decisions.
public struct ParticipantActivityRecord: Identifiable, Sendable {
    public let id: Int64
    public let clusterID: String
    public let nodeID: String
    public let nodeName: String
    public let time: Date
    public let kind: String
    public let detail: String

    public init(id: Int64, clusterID: String, nodeID: String, nodeName: String,
                time: Date, kind: String, detail: String) {
        self.id = id; self.clusterID = clusterID; self.nodeID = nodeID
        self.nodeName = nodeName; self.time = time; self.kind = kind; self.detail = detail
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
    public let participantActivity: [ParticipantActivityRecord]

    public init(recoverySeconds: Double, leases: [LeaseStatus], events: [WitnessEvent],
                participantActivity: [ParticipantActivityRecord] = []) {
        self.recoverySeconds = recoverySeconds; self.leases = leases; self.events = events
        self.participantActivity = participantActivity
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
        case .alreadyRunning: "Another Ruru process is using this ownership database."
        case .invalidConfiguration: "The listener address, port, cluster ID, or bearer token is invalid."
        case .stopped: "The listener was stopped before it became ready."
        case .listenerUnavailable: "The listener could not start. Check its port and network address."
        }
    }
}
