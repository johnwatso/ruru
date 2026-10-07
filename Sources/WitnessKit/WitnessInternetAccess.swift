import Foundation

/// Non-secret connection metadata. Connector and API credentials belong in Keychain.
public struct WitnessTunnelSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var hostname = ""
    public var tunnelID = ""
    public var accountID = ""
    public var instanceID = UUID().uuidString.lowercased()
    public init() {}
    public var publicURL: String { hostname.isEmpty ? "" : "https://\(hostname)" }
    public var name: String { "ruru-\(instanceID)" }
    public var isConfigured: Bool { !hostname.isEmpty && !tunnelID.isEmpty && !accountID.isEmpty }
}

public struct ProvisionedWitnessTunnel: Sendable {
    public let settings: WitnessTunnelSettings
    public let connectorToken: String
}

/// SwiftBot's API setup flow, scoped to a dedicated witness-owned tunnel.
public struct WitnessInternetSetup: Sendable {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public static func normalizedToken(_ token: String) -> String {
        CloudflareDNSProvider.normalizedAPIToken(from: token)
    }

    public static func normalizedHostname(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept a hostname or a bare HTTPS URL, not a path, credentials or port.
        let candidate = value.hasPrefix("https://") ? String(value.dropFirst(8)) : value
        let host = candidate.hasSuffix("/") ? String(candidate.dropLast()) : candidate
        guard host.utf8.count <= 253, host.contains("."),
              host.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                    && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }), host.split(separator: ".").last?.allSatisfy({ $0.isNumber }) == false else { return nil }
        return host
    }

    public func provision(
        apiToken: String, hostname: String, settings: WitnessTunnelSettings, port: Int,
        progress: @escaping @Sendable (String) async -> Void = { _ in },
        checkpoint: @escaping @Sendable (ProvisionedWitnessTunnel) async throws -> Void = { _ in }
    ) async throws -> ProvisionedWitnessTunnel {
        guard let hostname = Self.normalizedHostname(hostname), (1...65535).contains(port),
              UUID(uuidString: settings.instanceID) != nil else { throw SetupError.invalidConfiguration }
        let normalizedToken = Self.normalizedToken(apiToken)
        guard !normalizedToken.isEmpty else { throw SetupError.missingToken }
        let dns = CloudflareDNSProvider(apiToken: normalizedToken, session: session)
        await progress("Checking Cloudflare access…")
        try await dns.verifyAPITokenDetailed()
        let zones = try await dns.listZones()
        guard let zone = zones.filter({ hostname.hasSuffix("." + $0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) else { throw SetupError.zoneNotFound }
        await progress("Checking the hostname…")
        // Never replace a bot's or somebody else's DNS record. No force option.
        if let record = try await dns.findDNSRecord(zoneID: zone.id, hostname: hostname) {
            guard !settings.tunnelID.isEmpty, record.type.uppercased() == "CNAME",
                  record.content.caseInsensitiveCompare(CloudflareTunnelClient.tunnelTargetHostname(for: settings.tunnelID)) == .orderedSame
            else { throw SetupError.hostnameInUse }
        }
        await progress("Creating Ruru’s tunnel…")
        let client = CloudflareTunnelClient(apiToken: normalizedToken, session: session)
        let (tunnel, _) = try await client.createTunnel(hostname: hostname, zone: zone, name: settings.name)
        guard UUID(uuidString: tunnel.id) != nil, tunnel.name == settings.name else {
            throw SetupError.invalidConfiguration
        }
        // Persist the ID and token before publishing so a retry/restart knows which tunnel it owns.
        var saved = settings
        saved.enabled = false
        saved.hostname = hostname
        saved.tunnelID = tunnel.id
        saved.accountID = tunnel.accountID
        let provisioned = ProvisionedWitnessTunnel(settings: saved, connectorToken: tunnel.token)
        try await checkpoint(provisioned)
        await progress("Connecting the local Ruru service…")
        try await client.configureTunnel(tunnel, hostname: hostname, originURL: "http://127.0.0.1:\(port)")
        await progress("Creating the HTTPS address…")
        _ = try await dns.configureTunnelDNSRoute(hostname: hostname,
            tunnelTarget: CloudflareTunnelClient.tunnelTargetHostname(for: tunnel.id), zoneID: zone.id)
        saved.enabled = true
        return ProvisionedWitnessTunnel(settings: saved, connectorToken: tunnel.token)
    }

    public enum SetupError: LocalizedError {
        case invalidConfiguration, missingToken, zoneNotFound, hostnameInUse
        public var errorDescription: String? {
            switch self {
            case .invalidConfiguration: "Enter a subdomain such as ruru.example.com and a valid listener port."
            case .missingToken: "Enter a Cloudflare API token."
            case .zoneNotFound: "This subdomain is not in a zone accessible to this Cloudflare API token. Check Zone Read and DNS Edit permissions."
            case .hostnameInUse: "This hostname already has a DNS record belonging to another service. Choose an unused subdomain."
            }
        }
    }
}

/// Runs independently of either bot; no Cloudflare API requests are needed on ordinary startup.
public actor WitnessInternetAccess {
    private let manager = TunnelManager()
    public init() {}

    public func start(settings: WitnessTunnelSettings, token: String,
                      status: @escaping @MainActor @Sendable (WitnessInternetStatus) -> Void) async {
        guard settings.enabled, settings.isConfigured else { await stop(); return }
        await manager.configure(TunnelRuntimeConfiguration(hostname: settings.hostname,
            publicURL: settings.publicURL, originURL: "", tunnelToken: token),
            logger: { _ in }, statusHandler: status)
    }

    public func stop() async { await manager.stopForAppTermination() }
}
