import Darwin
import Foundation
import WitnessKit

struct GuardedService: Codable, Equatable, Identifiable {
    enum Kind: String, Codable, CaseIterable { case swiftBot = "SwiftBot", custom = "Other app" }
    var id = UUID().uuidString.lowercased()
    var name: String
    var clusterID: String
    var kind: Kind = .custom
    var nodeDisplayNames: [String: String] = [:]

    var symbol: String { kind == .swiftBot ? "bubble.left.and.bubble.right" : "server.rack" }
    var keychainAccount: String { id == "swiftbot" ? "authority-bearer-token" : "guarded-service-" + id }
    var isValid: Bool {
        WitnessNodeName.normalized(name) == name && name.utf8.count <= 128 &&
        !clusterID.isEmpty && clusterID == clusterID.trimmingCharacters(in: .whitespacesAndNewlines) &&
        clusterID.utf8.count <= 128 && clusterID.rangeOfCharacter(from: .controlCharacters) == nil &&
        (id == "swiftbot" || UUID(uuidString: id) != nil) &&
        WitnessConfiguration.validNames(nodeDisplayNames)
    }
}

struct WitnessConfiguration: Codable, Equatable {
    var clusterID = "swiftmesh"
    var bindAddress = "127.0.0.1"
    var port = 38990
    var publicEndpoint = ""
    var startAutomatically = true
    var showInDock = false
    var tunnel = WitnessTunnelSettings()
    var nodeDisplayNames: [String: String] = [:]
    var primaryServiceName = "SwiftBot"
    var primaryServiceRemoved = false
    var additionalServices: [GuardedService] = []
    // Keyed by stable service metadata ID, so a removed/re-added service cannot
    // inherit another service's preference, even when its cluster ID is reused.
    var servicePrimaryPreferences: [String: WitnessPrimaryPreference] = [:]

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

    var guardedServices: [GuardedService] {
        (primaryServiceRemoved ? [] : [GuardedService(id: "swiftbot", name: primaryServiceName, clusterID: clusterID,
                        kind: .swiftBot, nodeDisplayNames: nodeDisplayNames)]) + additionalServices
    }

    mutating func removeGuardedService(id: String) throws {
        guard guardedServices.contains(where: { $0.id == id }) else { throw WitnessStorage.ConfigurationError.invalid }
        if id == "swiftbot" { primaryServiceRemoved = true }
        else { additionalServices.removeAll { $0.id == id } }
        servicePrimaryPreferences.removeValue(forKey: id)
    }

    static func validNames(_ names: [String: String]) -> Bool {
        names.count <= 256 && names.allSatisfy {
            !$0.key.isEmpty && $0.key.utf8.count <= 128 && WitnessNodeName.normalized($0.value) == $0.value
        }
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case clusterID, bindAddress, port, publicEndpoint, startAutomatically, showInDock, tunnel, nodeDisplayNames, primaryServiceName, primaryServiceRemoved, additionalServices, servicePrimaryPreferences
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        clusterID = try values.decode(String.self, forKey: .clusterID)
        bindAddress = try values.decode(String.self, forKey: .bindAddress)
        port = try values.decode(Int.self, forKey: .port)
        publicEndpoint = try values.decode(String.self, forKey: .publicEndpoint)
        startAutomatically = try values.decode(Bool.self, forKey: .startAutomatically)
        showInDock = try values.decodeIfPresent(Bool.self, forKey: .showInDock) ?? false
        tunnel = try values.decodeIfPresent(WitnessTunnelSettings.self, forKey: .tunnel) ?? WitnessTunnelSettings()
        nodeDisplayNames = try values.decodeIfPresent([String: String].self, forKey: .nodeDisplayNames) ?? [:]
        primaryServiceName = try values.decodeIfPresent(String.self, forKey: .primaryServiceName) ?? "SwiftBot"
        primaryServiceRemoved = try values.decodeIfPresent(Bool.self, forKey: .primaryServiceRemoved) ?? false
        additionalServices = try values.decodeIfPresent([GuardedService].self, forKey: .additionalServices) ?? []
        servicePrimaryPreferences = try values.decodeIfPresent([String: WitnessPrimaryPreference].self, forKey: .servicePrimaryPreferences) ?? [:]
    }

    var isValid: Bool {
        let services = guardedServices
        guard Set(servicePrimaryPreferences.keys).isSubset(of: Set(services.map(\.id))),
              servicePrimaryPreferences.values.allSatisfy(\.isValid) else { return false }
        guard services.count <= 32, services.allSatisfy(\.isValid), additionalServices.allSatisfy({ $0.id != "swiftbot" }),
              Set(services.map(\.clusterID)).count == services.count,
              Set(services.map(\.id)).count == services.count else { return false }
        guard !clusterID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              clusterID.utf8.count <= 128, !clusterID.contains(where: { $0.isNewline }),
              ["127.0.0.1", "0.0.0.0", "::1"].contains(bindAddress), (1...65535).contains(port) else { return false }
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
            .appendingPathComponent("SwiftMeshWitness", isDirectory: true)
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
        case invalid, invalidNodeName, persistence, invalidPrimaryPreference
        var errorDescription: String? {
            switch self {
            case .invalid: "Check the cluster ID, listener port, and HTTPS endpoint."
            case .invalidNodeName: "Choose a short name on one line for this server."
            case .persistence: "Ruru could not durably save its settings. Check storage access and free space."
            case .invalidPrimaryPreference: "Choose a guarded service and a valid server node ID of up to 128 bytes."
            }
        }
    }
}
