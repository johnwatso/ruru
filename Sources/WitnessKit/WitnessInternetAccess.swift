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

/// A Cloudflare zone the API token can manage, offered as Ruru's domain.
public struct CloudflareDomain: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
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

    /// The domains (zones) this token can see. Listing them is also the token
    /// check, and works for both user and account-owned tokens.
    public func listDomains(apiToken: String) async throws -> [CloudflareDomain] {
        let token = Self.normalizedToken(apiToken)
        guard !token.isEmpty else { throw SetupError.missingToken }
        let zones: [CloudflareDNSProvider.ZoneSummary]
        do { zones = try await CloudflareDNSProvider(apiToken: token, session: session).listZones() }
        catch { throw SetupError.step("Checking the token", error) }
        guard !zones.isEmpty else { throw SetupError.noDomains }
        return zones.map { CloudflareDomain(id: $0.id, name: $0.name.lowercased()) }.sorted { $0.name < $1.name }
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
        let zones: [CloudflareDNSProvider.ZoneSummary]
        do { zones = try await dns.listZones() } catch { throw SetupError.step("Checking Cloudflare access", error) }
        guard let zone = zones.filter({ hostname.hasSuffix("." + $0.name.lowercased()) })
            .max(by: { $0.name.count < $1.name.count }) else { throw SetupError.zoneNotFound }
        await progress("Checking the hostname…")
        // Never replace a bot's or somebody else's DNS record. No force option.
        let existingRecord: CloudflareDNSProvider.DNSRecordSummary?
        do { existingRecord = try await dns.findDNSRecord(zoneID: zone.id, hostname: hostname) }
        catch { throw SetupError.step("Checking the address", error) }
        if let record = existingRecord {
            guard !settings.tunnelID.isEmpty, record.type.uppercased() == "CNAME",
                  record.content.caseInsensitiveCompare(CloudflareTunnelClient.tunnelTargetHostname(for: settings.tunnelID)) == .orderedSame
            else { throw SetupError.hostnameInUse }
        }
        await progress("Creating Ruru’s tunnel…")
        let client = CloudflareTunnelClient(apiToken: normalizedToken, session: session)
        let tunnel: CloudflareTunnelClient.TunnelSummary
        do { (tunnel, _) = try await client.createTunnel(hostname: hostname, zone: zone, name: settings.name) }
        catch { throw SetupError.step("Creating Ruru’s tunnel", error) }
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
        do { try await client.configureTunnel(tunnel, hostname: hostname, originURL: "http://127.0.0.1:\(port)") }
        catch { throw SetupError.step("Routing the tunnel to Ruru", error) }
        await progress("Creating the HTTPS address…")
        do {
            _ = try await dns.configureTunnelDNSRoute(hostname: hostname,
                tunnelTarget: CloudflareTunnelClient.tunnelTargetHostname(for: tunnel.id), zoneID: zone.id)
        } catch { throw SetupError.step("Creating the DNS record", error) }
        saved.enabled = true
        return ProvisionedWitnessTunnel(settings: saved, connectorToken: tunnel.token)
    }

    public enum SetupError: LocalizedError {
        case invalidConfiguration, missingToken, zoneNotFound, hostnameInUse, noDomains
        /// A Cloudflare step failed; the message says which one.
        case step(String, Swift.Error)
        public var errorDescription: String? {
            switch self {
            case .noDomains: "This token can’t see any domains. Give it Zone → Zone → Read for the domain Ruru should use."
            case .step(let name, let error): "\(name) failed: \(error.localizedDescription)"
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
    private let probe = WitnessTransportProbe()
    public init() {}

    public func start(settings: WitnessTunnelSettings, token: String,
                      status: @escaping @MainActor @Sendable (WitnessInternetStatus) -> Void) async {
        guard settings.enabled, settings.isConfigured else { await stop(); return }
        await manager.configure(TunnelRuntimeConfiguration(hostname: settings.hostname,
            publicURL: settings.publicURL, originURL: "", tunnelToken: token),
            logger: { _ in }, statusHandler: status)
    }

    public func stop() async { await manager.stopForAppTermination() }

    /// The Cloudflare connector's recent output (secrets redacted).
    public func diagnostics() async -> [String] { await manager.recentOutput() }

    /// Checks the local listener and the public tunnel route without changing
    /// connector, listener, storage, or lease state. The connector's current
    /// telemetry is included as the middle hop.
    public func inspectTransport(localEndpoint: URL?, publicEndpoint: URL?) async -> WitnessTransportDiagnostics {
        let connector = await manager.diagnostics()
        return await probe.inspect(localEndpoint: localEndpoint, publicEndpoint: publicEndpoint, connector: connector)
    }
}
