import Foundation

/// Operator intent, independent of lease ownership. No endpoints are probed.
public struct CoordinationPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var allowedOrigins: [String]

    public init(enabled: Bool = false, allowedOrigins: [String] = []) {
        self.enabled = enabled
        self.allowedOrigins = allowedOrigins
    }

    public var isValid: Bool {
        allowedOrigins.count <= 8 && Set(allowedOrigins).count == allowedOrigins.count &&
        allowedOrigins.allSatisfy { $0.utf8.count <= 256 && Self.normalizedOrigin($0) == $0 }
    }

    public static func normalizedOrigin(_ value: String) -> String? {
        guard let components = safeComponents(value), components.path.isEmpty || components.path == "/" else { return nil }
        return origin(components)
    }

    func permits(_ value: String) -> Bool {
        guard value.utf8.count <= 512, let components = Self.safeComponents(value),
              let origin = Self.origin(components) else { return false }
        return allowedOrigins.contains(origin)
    }

    private static func safeComponents(_ value: String) -> URLComponents? {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 > 32 && $0 < 127 && $0 != 92 }),
              let components = URLComponents(string: value), components.scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) != false,
              components.url != nil else { return nil }
        return components
    }

    private static func origin(_ components: URLComponents) -> String? {
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = components.host?.lowercased()
        origin.port = components.port == 443 ? nil : components.port
        return origin.string
    }
}

public struct CoordinationScopeRequest: Codable, Sendable {
    public var version: Int
    public var clusterID: String
    public init(clusterID: String, version: Int = 1) { self.clusterID = clusterID; self.version = version }
}

/// A proposal for operator approval, never permission to publish a location.
public struct CoordinationEnrollmentRequest: Codable, Sendable {
    public var version: Int
    public var clusterID: String
    public var nodeID: String
    public var nodeName: String?
    public var origin: String
    public var withdraw: Bool
    public init(clusterID: String, nodeID: String, nodeName: String? = nil, origin: String,
                withdraw: Bool = false, version: Int = 1) {
        self.version = version; self.clusterID = clusterID; self.nodeID = nodeID
        self.nodeName = nodeName; self.origin = origin; self.withdraw = withdraw
    }
}

public struct CoordinationEnrollment: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let clusterID: String
    public let nodeID: String
    public let nodeName: String?
    public let origin: String
    public let ageSeconds: Double
    public init(id: UUID, clusterID: String, nodeID: String, nodeName: String?, origin: String, ageSeconds: Double) {
        self.id = id; self.clusterID = clusterID; self.nodeID = nodeID
        self.nodeName = nodeName; self.origin = origin; self.ageSeconds = ageSeconds
    }
}

public struct CoordinationEnrollmentReply: Codable, Sendable {
    public let version: Int
    public let clusterID: String
    public let status: String
}

/// An application-neutral logical resource. The reporting node supplies one location.
public struct CoordinationResource: Codable, Equatable, Sendable {
    public var namespace: String
    public var resourceID: String
    public var title: String
    public var url: String
    public init(namespace: String, resourceID: String, title: String, url: String) {
        self.namespace = namespace; self.resourceID = resourceID; self.title = title; self.url = url
    }
    var key: CoordinationResourceKey { .init(namespace: namespace, resourceID: resourceID) }
    func isValid(policy: CoordinationPolicy) -> Bool {
        CoordinationResourceKey.valid(namespace, bytes: 64) && CoordinationResourceKey.valid(resourceID, bytes: 128) &&
        WitnessNodeName.normalized(title) == title && title.utf8.count <= 128 && policy.permits(url)
    }
}

public struct CoordinationResourceKey: Codable, Hashable, Sendable {
    public var namespace: String
    public var resourceID: String
    public init(namespace: String, resourceID: String) { self.namespace = namespace; self.resourceID = resourceID }
    var isValid: Bool { Self.valid(namespace, bytes: 64) && Self.valid(resourceID, bytes: 128) }
    static func valid(_ value: String, bytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= bytes && value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        value.rangeOfCharacter(from: .controlCharacters) == nil
    }
}

public struct CoordinationReport: Codable, Sendable {
    public var version: Int
    public var clusterID: String
    public var nodeID: String
    public var nodeName: String?
    public var resources: [CoordinationResource]
    public var removed: [CoordinationResourceKey]
    public init(clusterID: String, nodeID: String, nodeName: String? = nil,
                resources: [CoordinationResource] = [], removed: [CoordinationResourceKey] = [], version: Int = 1) {
        self.version = version; self.clusterID = clusterID; self.nodeID = nodeID; self.nodeName = nodeName
        self.resources = resources; self.removed = removed
    }
}

public struct CoordinationCatalogueRequest: Codable, Sendable {
    public var version: Int
    public var clusterID: String
    public var offset: Int
    public var revision: String?
    public init(clusterID: String, offset: Int = 0, revision: String? = nil, version: Int = 1) {
        self.version = version; self.clusterID = clusterID; self.offset = offset; self.revision = revision
    }
}

public struct CoordinationLocation: Codable, Equatable, Sendable, Identifiable {
    public let clusterID: String
    public let nodeID: String
    public let nodeName: String?
    public let resource: CoordinationResource
    public let ageSeconds: Double
    public let fresh: Bool
    public init(clusterID: String, nodeID: String, nodeName: String? = nil, resource: CoordinationResource, ageSeconds: Double, fresh: Bool) {
        self.clusterID = clusterID; self.nodeID = nodeID; self.nodeName = nodeName
        self.resource = resource; self.ageSeconds = ageSeconds; self.fresh = fresh
    }
    // Structured identity avoids collisions between IDs containing separators.
    public var id: [String] { [clusterID, nodeID, resource.namespace, resource.resourceID] }
}

public struct CoordinationCataloguePage: Codable, Sendable {
    public let version: Int
    public let clusterID: String
    public let revision: String
    public let locations: [CoordinationLocation]
    public let nextOffset: Int?
}

public struct CoordinationCapabilities: Codable, Sendable {
    public let version: Int
    public let clusterID: String
    public let enabled: Bool
    public let capabilities: [String]
    public let allowedOrigins: [String]
    public let maxBatchSize: Int
    public let pageSize: Int
    public let freshForSeconds: Int
    public let retainedForSeconds: Int
    public let maxNodesPerService: Int
    public let maxLocationsPerNode: Int
    public let maxLocationsPerService: Int
    public let maxLocationsTotal: Int
    public let enrollmentSupported: Bool
}
