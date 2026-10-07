import Darwin
import Foundation
import WitnessKit

/// One configured service. Every service is equal; `kind` is only a template
/// that chooses an icon and pairing instructions.
struct GuardedService: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case swiftBot = "SwiftBot", custom = "Other app" }
    static let leaseSecondsRange = 10...300
    static let defaultLeaseSeconds = 30

    var id = UUID().uuidString.lowercased()
    var name: String
    var clusterID: String
    var kind: Kind = .custom
    var nodeDisplayNames: [String: String] = [:]
    /// How long a grant lasts. Clients renew at about a third of this.
    var leaseSeconds = GuardedService.defaultLeaseSeconds

    init(id: String = UUID().uuidString.lowercased(), name: String, clusterID: String, kind: Kind = .custom,
         nodeDisplayNames: [String: String] = [:], leaseSeconds: Int = GuardedService.defaultLeaseSeconds) {
        self.id = id; self.name = name; self.clusterID = clusterID; self.kind = kind
        self.nodeDisplayNames = nodeDisplayNames; self.leaseSeconds = leaseSeconds
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        clusterID = try values.decode(String.self, forKey: .clusterID)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .custom
        nodeDisplayNames = try values.decodeIfPresent([String: String].self, forKey: .nodeDisplayNames) ?? [:]
        leaseSeconds = try values.decodeIfPresent(Int.self, forKey: .leaseSeconds) ?? Self.defaultLeaseSeconds
    }

    var symbol: String { kind == .swiftBot ? "bubble.left.and.bubble.right" : "server.rack" }
    /// The SwiftBot template keeps SwiftBot's own app icon.
    var brandAsset: String? { kind == .swiftBot ? "SwiftBotLogo" : nil }
    var keychainAccount: String { "service-" + id }
    var isValid: Bool {
        WitnessNodeName.normalized(name) == name && name.utf8.count <= 128 &&
        !clusterID.isEmpty && clusterID == clusterID.trimmingCharacters(in: .whitespacesAndNewlines) &&
        clusterID.utf8.count <= 128 && clusterID.rangeOfCharacter(from: .controlCharacters) == nil &&
        UUID(uuidString: id) != nil && Self.leaseSecondsRange.contains(leaseSeconds) &&
        WitnessConfiguration.validNames(nodeDisplayNames)
    }
}

struct WitnessConfiguration: Codable, Equatable {
    var bindAddress = "127.0.0.1"
    var port = 38990
    var publicEndpoint = ""
    var startAutomatically = true
    var showInDock = false
    var tunnel = WitnessTunnelSettings()
    var alerts = RuruAlertPreferences()
    /// Every configured service, in display order. A fresh install has none.
    var services: [GuardedService] = []
    // Keyed by stable service metadata ID, so a removed/re-added service cannot
    // inherit another service's preference, even when its cluster ID is reused.
    var servicePrimaryPreferences: [String: WitnessPrimaryPreference] = [:]

    var serviceCoordinationPolicies: [String: CoordinationPolicy] = [:]

    func coordinationPolicy(for serviceID: String) -> CoordinationPolicy {
        serviceCoordinationPolicies[serviceID] ?? .init()
    }

    mutating func approveCoordinationOrigin(_ origin: String, for serviceID: String) throws {
        var policy = coordinationPolicy(for: serviceID)
        policy.enabled = true
        if !policy.allowedOrigins.contains(origin) { policy.allowedOrigins.append(origin) }
        try setCoordinationPolicy(policy, for: serviceID)
    }

    mutating func setCoordinationPolicy(_ policy: CoordinationPolicy, for serviceID: String) throws {
        guard guardedServices.contains(where: { $0.id == serviceID }), policy.isValid else {
            throw WitnessStorage.ConfigurationError.invalidCoordinationPolicy
        }
        serviceCoordinationPolicies[serviceID] = policy
    }

    func primaryPreference(for serviceID: String) -> WitnessPrimaryPreference {
        servicePrimaryPreferences[serviceID] ?? .init()
    }

    @discardableResult
    mutating func setPreferredPrimary(_ nodeID: String?, for serviceID: String) throws -> Bool {
        guard guardedServices.contains(where: { $0.id == serviceID }),
              nodeID.map(WitnessPrimaryPreference.validNodeID) != false else {
            throw WitnessStorage.ConfigurationError.invalidPrimaryPreference
        }
        let previous = primaryPreference(for: serviceID)
        guard previous.isValid else { throw WitnessStorage.ConfigurationError.invalidPrimaryPreference }
        guard previous.preferredPrimaryNodeID != nodeID else { return false }
        guard previous.revision < Int64.max else { throw WitnessStorage.ConfigurationError.invalidPrimaryPreference }
        servicePrimaryPreferences[serviceID] = .init(preferredPrimaryNodeID: nodeID, revision: previous.revision + 1)
        return true
    }

    var guardedServices: [GuardedService] { services }

    mutating func removeGuardedService(id: String) throws {
        guard services.contains(where: { $0.id == id }) else { throw WitnessStorage.ConfigurationError.invalid }
        services.removeAll { $0.id == id }
        servicePrimaryPreferences.removeValue(forKey: id)
        serviceCoordinationPolicies.removeValue(forKey: id)
    }

    static func validNames(_ names: [String: String]) -> Bool {
        names.count <= 256 && names.allSatisfy {
            !$0.key.isEmpty && $0.key.utf8.count <= 128 && WitnessNodeName.normalized($0.value) == $0.value
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case bindAddress, port, publicEndpoint, startAutomatically, showInDock, tunnel, alerts, services, servicePrimaryPreferences, serviceCoordinationPolicies
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bindAddress = try values.decode(String.self, forKey: .bindAddress)
        port = try values.decode(Int.self, forKey: .port)
        publicEndpoint = try values.decode(String.self, forKey: .publicEndpoint)
        startAutomatically = try values.decode(Bool.self, forKey: .startAutomatically)
        showInDock = try values.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        tunnel = try values.decodeIfPresent(WitnessTunnelSettings.self, forKey: .tunnel) ?? WitnessTunnelSettings()
        alerts = try values.decodeIfPresent(RuruAlertPreferences.self, forKey: .alerts) ?? RuruAlertPreferences()
        services = try values.decode([GuardedService].self, forKey: .services)
        serviceCoordinationPolicies = try values.decodeIfPresent([String: CoordinationPolicy].self, forKey: .serviceCoordinationPolicies) ?? [:]
        servicePrimaryPreferences = try values.decodeIfPresent([String: WitnessPrimaryPreference].self, forKey: .servicePrimaryPreferences) ?? [:]
    }

    var isValid: Bool {
        let services = guardedServices
        guard Set(serviceCoordinationPolicies.keys).isSubset(of: Set(services.map(\.id))),
              serviceCoordinationPolicies.values.allSatisfy(\.isValid) else { return false }
        guard Set(servicePrimaryPreferences.keys).isSubset(of: Set(services.map(\.id))),
              servicePrimaryPreferences.values.allSatisfy(\.isValid) else { return false }
        guard services.count <= 32, services.allSatisfy(\.isValid),
              Set(services.map(\.clusterID)).count == services.count,
              Set(services.map(\.id)).count == services.count else { return false }
        guard ["127.0.0.1", "0.0.0.0", "::1"].contains(bindAddress), (1...65535).contains(port) else { return false }
        guard UUID(uuidString: tunnel.instanceID) != nil else { return false }
        if !tunnel.hostname.isEmpty || !tunnel.tunnelID.isEmpty || !tunnel.accountID.isEmpty {
            guard tunnel.isConfigured else { return false }
            guard WitnessInternetSetup.normalizedHostname(tunnel.hostname) == tunnel.hostname,
                  UUID(uuidString: tunnel.tunnelID) != nil, !tunnel.accountID.isEmpty,
                  bindAddress == "127.0.0.1", publicEndpoint == tunnel.publicURL else { return false }
        } else if tunnel.enabled { return false }
        if publicEndpoint.isEmpty { return true }
        guard let url = URL(string: publicEndpoint), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return true
    }
}

enum WitnessStorage {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ruru", isDirectory: true)
    }

    static func load(from directory: URL = Self.directory) throws -> WitnessConfiguration {
        let url = directory.appendingPathComponent("configuration.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return WitnessConfiguration() }
        let settings = try JSONDecoder().decode(WitnessConfiguration.self, from: Data(contentsOf: url))
        guard settings.isValid else { throw ConfigurationError.invalid }
        return settings
    }

    static func save(_ settings: WitnessConfiguration, in directory: URL = Self.directory) throws {
        guard settings.isValid else { throw ConfigurationError.invalid }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = directory.appendingPathComponent("configuration.json")
        try encoder.encode(settings).write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw ConfigurationError.persistence }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw ConfigurationError.persistence }
    }

    enum ConfigurationError: LocalizedError {
        case invalid, invalidNodeName, persistence, invalidPrimaryPreference, invalidCoordinationPolicy
        var errorDescription: String? {
            switch self {
            case .invalid: "Check the cluster ID, listener port, and HTTPS endpoint."
            case .invalidNodeName: "Choose a short name on one line for this server."
            case .persistence: "Ruru could not durably save its settings. Check storage access and free space."
            case .invalidCoordinationPolicy: "Choose a configured service and up to eight HTTPS origins without paths or credentials."
            case .invalidPrimaryPreference: "Choose a guarded service and a valid server node ID of up to 128 bytes."
            }
        }
    }
}
