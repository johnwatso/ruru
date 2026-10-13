import Foundation

/// Operator intent only. A preference is never permission to perform work.
public struct WitnessPrimaryPreference: Codable, Equatable, Sendable {
    public var preferredPrimaryNodeID: String?
    public var revision: Int64

    public init(preferredPrimaryNodeID: String? = nil, revision: Int64 = 0) {
        self.preferredPrimaryNodeID = preferredPrimaryNodeID
        self.revision = revision
    }

    public var isValid: Bool {
        revision >= 0 && preferredPrimaryNodeID.map(Self.validNodeID) != false
    }

    public static func validNodeID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 128 &&
        value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public struct WitnessServicePolicy: Codable, Equatable, Sendable {
    public let version: Int
    public let clusterID: String
    public let preferredPrimaryNodeID: String?
    public let preferenceRevision: Int64

    public init(clusterID: String, preference: WitnessPrimaryPreference) {
        version = 1
        self.clusterID = clusterID
        preferredPrimaryNodeID = preference.preferredPrimaryNodeID
        preferenceRevision = preference.revision
    }

    private enum CodingKeys: String, CodingKey {
        case version, clusterID, preferredPrimaryNodeID, preferenceRevision
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(clusterID, forKey: .clusterID)
        // Clearing is explicit on the wire; do not leave a stale client value.
        try values.encode(preferredPrimaryNodeID, forKey: .preferredPrimaryNodeID)
        try values.encode(preferenceRevision, forKey: .preferenceRevision)
    }
}

struct WitnessServicePolicyRequest: Decodable {
    let clusterID: String
}

/// `GET /v1/service`: what the calling token's service supports, and its state.
/// Clients feature-detect from `capabilities` instead of assuming a version.
public struct WitnessServiceDescription: Codable, Equatable, Sendable {
    public struct Capability: Codable, Equatable, Sendable {
        public let version: Int
        public let enabled: Bool
    }
    public struct Lease: Codable, Equatable, Sendable {
        public let ownerNodeID: String?
        public let term: Int64
        public let remainingSeconds: Double
    }

    public let version: Int
    public let authority: String
    public let clusterID: String
    public let leaseSeconds: Double
    public let recoverySeconds: Double
    public let capabilities: [String: Capability]
    public let lease: Lease?

    init(service: WitnessServiceCredential, lease: LeaseStatus?, recoverySeconds: Double) {
        version = 1
        authority = "Ruru"
        clusterID = service.clusterID
        leaseSeconds = service.leaseSeconds
        self.recoverySeconds = recoverySeconds
        capabilities = [
            "lease": .init(version: 1, enabled: true),
            "primaryPreference": .init(version: 1, enabled: true),
            "participantPresence": .init(version: 1, enabled: true),
            "operationalStatus": .init(version: 1, enabled: true),
            "coordination": .init(version: 1, enabled: service.coordinationPolicy.enabled)
        ]
        self.lease = lease.map {
            Lease(ownerNodeID: $0.ownerNodeID.isEmpty ? nil : $0.ownerNodeID, term: $0.term, remainingSeconds: $0.remainingSeconds)
        }
    }
}
