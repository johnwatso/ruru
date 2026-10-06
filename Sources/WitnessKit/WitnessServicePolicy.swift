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
