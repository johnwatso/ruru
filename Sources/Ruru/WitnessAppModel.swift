import AppKit
import ServiceManagement
import SwiftUI
import WitnessKit

@MainActor
final class WitnessAppModel: ObservableObject {
    enum ServiceState: String { case stopped = "Stopped", starting = "Starting", running = "Running", failed = "Unavailable" }

    @Published private(set) var configuration = WitnessConfiguration()
    @Published var selectedPage: WitnessPage? = .overview
    @Published private(set) var state: ServiceState = .stopped
    @Published private(set) var coordinationLocations: [CoordinationLocation] = []
    @Published private(set) var coordinationEnrollments: [CoordinationEnrollment] = []
    private let catalogue = CoordinationCatalogue()
    private let pairing = PairingDesk()
    private let participants = ParticipantPresence()
    @Published private(set) var participantObservations: [ParticipantObservation] = []
    @Published private(set) var pairingCodes: [PairingDesk.Code] = []
    @Published private(set) var pairingRequests: [PairingDesk.Request] = []
    /// Servers approved this session, by cluster ID, for the setup assistant.
    @Published private(set) var pairedServers: [String: [String]] = [:]
    /// The first-run setup assistant. Opens until setup is completed.
    @Published var showingSetup = false
    private var announcedPairings: Set<String> = []
    @Published private(set) var snapshot: WitnessSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var listenerPort: UInt16?
    @Published private(set) var serviceStartedAt: ContinuousClock.Instant?
    @Published private(set) var legacyStorageNeedsReplacement = false
    @Published private(set) var storageArchivePath: String?
    @Published private(set) var lastSnapshotDate: Date?
    @Published private(set) var snapshotError: String?
    private var snapshotTask: Task<Void, Never>?
    @Published private(set) var discordConfigured = false
    @Published private(set) var alertDeliveryError: String?
    private var alertMonitor = RuruAlertMonitor()
    private let alertDelivery = RuruAlertDelivery()
    private var discordWebhook: URL?

    @Published private(set) var internetStatus = WitnessInternetStatus()
    @Published private(set) var internetBusy = false
    @Published private(set) var internetProgress = ""
    @Published private(set) var internetError: String?
    /// Results from an explicit, observation-only Internet Access check.
    @Published private(set) var transportDiagnostics: WitnessTransportDiagnostics?
    @Published private(set) var transportDiagnosticsBusy = false
    private let internetAccess = WitnessInternetAccess()
    private var shuttingDown = false

    private var store: LeaseStore?
    private var server: WitnessHTTPServer?
    private var serviceCredentials: [String: String] = [:]
    private var savingConfiguration = false
    private var pollTask: Task<Void, Never>?
    private let preview: Bool

    init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview") ||
         ProcessInfo.processInfo.arguments.contains("--preview-screenshots") ||
         Bundle.main.object(forInfoDictionaryKey: "RuruScreenshotPreview") as? Bool == true) {
        self.preview = preview
        if preview {
            // Display-only service; previews never touch storage or Keychain.
            configuration.services = [Self.previewService]
            configuration.setup.completed = true
            if ProcessInfo.processInfo.arguments.contains("--preview-setup") {
                configuration.services = []
                configuration.setup.completed = false
                state = .running
                listenerPort = UInt16(configuration.port)
                showingSetup = true
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-screenshots") ||
                Bundle.main.object(forInfoDictionaryKey: "RuruScreenshotPreview") as? Bool == true {
                loadScreenshotPreview()
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-primary-preference") {
                // Static, ephemeral UI fixtures. No store, listener or credentials.
                snapshot = WitnessSnapshot(recoverySeconds: 0,
                    leases: [LeaseStatus(clusterID: previewCluster, ownerNodeID: "backup-mac", term: 7,
                                         remainingSeconds: 26, ownerNodeName: "Backup Mac")],
                    events: [WitnessEvent(clusterID: previewCluster, id: 2, time: Date(), action: "Acquired",
                                          nodeID: "backup-mac", term: 7, nodeName: "Backup Mac"),
                             WitnessEvent(clusterID: previewCluster, id: 1, time: Date(), action: "Acquired",
                                          nodeID: "home-mac", term: 6, nodeName: "Home Mac")])
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-legacy-storage") {
                legacyStorageNeedsReplacement = true
                state = .failed
                error = LegacyAuthorityStorageError().localizedDescription
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-transport-error") {
                loadPreviewTransportError()
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-quarantine") {
                loadPreviewQuarantine()
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-ownerless") {
                loadPreviewOwnerless()
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-authority-error") {
                loadPreviewAuthorityError()
            }
            return
        }
        do {
            configuration = try WitnessStorage.load()
            showingSetup = !configuration.setup.completed
            discordWebhook = (try? WitnessKeychain.read(RuruDiscordWebhook.keychainAccount)).flatMap { $0 }
                .flatMap(RuruDiscordWebhook.validated)
            discordConfigured = discordWebhook != nil
            try WitnessStorage.checkAuthorityPresent()
            store = try LeaseStore(databaseURL: WitnessStorage.databaseURL)
            try WitnessStorage.recordAuthorityCreated()
            beginSnapshots()
            for service in configuration.guardedServices {
                serviceCredentials[service.clusterID] = try WitnessKeychain.loadOrCreate(account: service.keychainAccount)
            }
            refreshLoginStatus()
            beginPolling()
            if configuration.startAutomatically { Task { await start() } }
        } catch {
            legacyStorageNeedsReplacement = error is LegacyAuthorityStorageError
            self.error = error.localizedDescription
            state = .failed
        }
    }

    private static let previewService = GuardedService(id: "00000000-0000-4000-8000-000000000001", name: "SwiftBot",
                                                       clusterID: "swiftbot", kind: .swiftBot)
    private var previewCluster: String { Self.previewService.clusterID }

    private func loadScreenshotPreview() {
        // Display-only fixtures: never initialize storage, credentials, a listener,
        // a connector or polling. The lease remains stable while taking screenshots.
        configuration.publicEndpoint = "https://gaurd.ruruapp.dev"
        configuration.tunnel.hostname = "gaurd.ruruapp.dev"
        configuration.tunnel.enabled = true
        configuration.tunnel.tunnelID = "00000000-0000-4000-8000-000000000001"
        configuration.tunnel.accountID = "screenshot-preview"
        configuration.servicePrimaryPreferences[Self.previewService.id] = .init(preferredPrimaryNodeID: "home-mac", revision: 1)
        configuration.serviceCoordinationPolicies[Self.previewService.id] = .init(enabled: true, allowedOrigins: ["https://videos.ruruapp.dev"])
        let buildService = GuardedService(id: "00000000-0000-4000-8000-000000000002", name: "Build Server", clusterID: "build-server")
        configuration.services.append(buildService)
        configuration.serviceCoordinationPolicies[buildService.id] = .init(enabled: true, allowedOrigins: ["https://builds.ruruapp.dev"])
        coordinationLocations = [
            .init(clusterID: previewCluster, nodeID: "home-mac", nodeName: "Home Mac",
                resource: .init(namespace: "recordings", resourceID: "session-42", title: "Community catch-up", url: "https://videos.ruruapp.dev/recordings/session-42"), ageSeconds: 12, fresh: true),
            .init(clusterID: previewCluster, nodeID: "backup-mac", nodeName: "Backup Mac",
                resource: .init(namespace: "recordings", resourceID: "session-42", title: "Community catch-up", url: "https://videos.ruruapp.dev/backup/session-42"), ageSeconds: 145, fresh: false),
            .init(clusterID: buildService.clusterID, nodeID: "build-mac", nodeName: "Build Mac",
                resource: .init(namespace: "artifacts", resourceID: "nightly-macos", title: "Nightly macOS build", url: "https://builds.ruruapp.dev/artifacts/nightly-macos"), ageSeconds: 24, fresh: true)
        ]
        coordinationEnrollments = [.init(id: UUID(), clusterID: previewCluster, nodeID: "new-backup-mac",
            nodeName: "New Backup Mac", origin: "https://backup.swiftbot.example", ageSeconds: 20)]
        state = .running
        listenerPort = UInt16(configuration.port)
        serviceStartedAt = .now.advanced(by: .seconds(-18_240))
        internetStatus = WitnessInternetStatus(state: .enabled, publicURL: configuration.publicEndpoint,
                                              detail: "Connected to Cloudflare.")
        let now = Date()
        participantObservations = [
            .init(clusterID: previewCluster, nodeID: "home-mac", nodeName: "Home Mac", role: .active, ageSeconds: 2, fresh: true),
            .init(clusterID: previewCluster, nodeID: "backup-mac", nodeName: "Backup Mac", role: .standby, ageSeconds: 4, fresh: true),
            .init(clusterID: previewCluster, nodeID: "new-standby", nodeName: "New Standby", role: .standby, ageSeconds: 75, fresh: false)
        ]
        snapshot = WitnessSnapshot(recoverySeconds: 0,
            leases: [LeaseStatus(clusterID: previewCluster, ownerNodeID: "home-mac", term: 42,
                                 remainingSeconds: 26, ownerNodeName: "Home Mac")],
            events: [WitnessEvent(clusterID: previewCluster, id: 4, time: now.addingTimeInterval(-180),
                                  action: "Acquired", nodeID: "home-mac", term: 42, nodeName: "Home Mac"),
                     WitnessEvent(clusterID: previewCluster, id: 3, time: now.addingTimeInterval(-900),
                                  action: "Acquired", nodeID: "backup-mac", term: 41, nodeName: "Backup Mac"),
                     WitnessEvent(clusterID: previewCluster, id: 2, time: now.addingTimeInterval(-7_200),
                                  action: "Acquired", nodeID: "home-mac", term: 40, nodeName: "Home Mac"),
                     WitnessEvent(clusterID: previewCluster, id: 1, time: now.addingTimeInterval(-18_240),
                                  action: "Acquired", nodeID: "backup-mac", term: 39, nodeName: "Backup Mac")])
        // Simulate the owner renewing every five seconds, so the lease ring
        // shows its normal refill cycle instead of draining to "late".
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, let current = self.snapshot else { return }
                self.snapshot = WitnessSnapshot(recoverySeconds: 0, leases: current.leases.map {
                    LeaseStatus(clusterID: $0.clusterID, ownerNodeID: $0.ownerNodeID, term: $0.term,
                                remainingSeconds: $0.remainingSeconds <= 26 ? 30 : $0.remainingSeconds - 1,
                                ownerNodeName: $0.ownerNodeName)
                }, events: current.events)
            }
        }
    }

    private func loadPreviewTransportError() {
        state = .running
        listenerPort = UInt16(configuration.port)
        serviceStartedAt = .now.advanced(by: .seconds(-3_600))
        internetStatus = WitnessInternetStatus(state: .error, publicURL: "", detail: "Tunnel connection lost.")
        configuration.tunnel.hostname = "gaurd.ruruapp.dev"
        configuration.tunnel.enabled = true
        configuration.tunnel.tunnelID = "00000000-0000-4000-8000-000000000001"
        configuration.tunnel.accountID = "screenshot-preview"
        snapshot = WitnessSnapshot(recoverySeconds: 0,
            leases: [LeaseStatus(clusterID: previewCluster, ownerNodeID: "home-mac", term: 42,
                                 remainingSeconds: 280, ownerNodeName: "Home Mac")],
            events: [WitnessEvent(clusterID: previewCluster, id: 1, time: Date().addingTimeInterval(-3_600),
                                  action: "Acquired", nodeID: "home-mac", term: 42, nodeName: "Home Mac")])
    }

    private func loadPreviewQuarantine() {
        state = .running
        listenerPort = UInt16(configuration.port)
        serviceStartedAt = .now.advanced(by: .seconds(-10))
        configuration.publicEndpoint = "https://gaurd.ruruapp.dev"
        configuration.tunnel.hostname = "gaurd.ruruapp.dev"
        configuration.tunnel.enabled = true
        configuration.tunnel.tunnelID = "00000000-0000-4000-8000-000000000001"
        configuration.tunnel.accountID = "screenshot-preview"
        internetStatus = WitnessInternetStatus(state: .enabled, publicURL: configuration.publicEndpoint,
                                              detail: "Connected to Cloudflare.")
        snapshot = WitnessSnapshot(recoverySeconds: 245,
            leases: [],
            events: [WitnessEvent(clusterID: previewCluster, id: 1, time: Date().addingTimeInterval(-600),
                                  action: "Acquired", nodeID: "home-mac", term: 41, nodeName: "Home Mac")])
    }

    private func loadPreviewOwnerless() {
        state = .running
        listenerPort = UInt16(configuration.port)
        serviceStartedAt = .now.advanced(by: .seconds(-7_200))
        configuration.publicEndpoint = "https://gaurd.ruruapp.dev"
        configuration.tunnel.hostname = "gaurd.ruruapp.dev"
        configuration.tunnel.enabled = true
        configuration.tunnel.tunnelID = "00000000-0000-4000-8000-000000000001"
        configuration.tunnel.accountID = "screenshot-preview"
        internetStatus = WitnessInternetStatus(state: .enabled, publicURL: configuration.publicEndpoint,
                                              detail: "Connected to Cloudflare.")
        snapshot = WitnessSnapshot(recoverySeconds: 0,
            leases: [],
            events: [WitnessEvent(clusterID: previewCluster, id: 2, time: Date().addingTimeInterval(-1_800),
                                  action: "Released", nodeID: "home-mac", term: 40, nodeName: "Home Mac"),
                     WitnessEvent(clusterID: previewCluster, id: 1, time: Date().addingTimeInterval(-7_200),
                                  action: "Acquired", nodeID: "home-mac", term: 40, nodeName: "Home Mac")])
        participantObservations = [
            .init(clusterID: previewCluster, nodeID: "home-mac", nodeName: "Home Mac", role: .standby, ageSeconds: 4, fresh: true),
            .init(clusterID: previewCluster, nodeID: "backup-mac", nodeName: "Backup Mac", role: .standby, ageSeconds: 8, fresh: true)
        ]
    }

    private func loadPreviewAuthorityError() {
        state = .failed
        error = "The database could not be opened. Check storage permissions and disk space."
    }

    func lease(for clusterID: String) -> LeaseStatus? { snapshot?.leases.first { $0.clusterID == clusterID } }
    func service(for clusterID: String) -> GuardedService? { configuration.guardedServices.first { $0.clusterID == clusterID } }
    func serviceName(for clusterID: String) -> String { service(for: clusterID)?.name ?? clusterID }
    func events(for clusterID: String) -> [WitnessEvent] { (snapshot?.events ?? []).filter { $0.clusterID == clusterID } }
    func knownNodes(for clusterID: String) -> [String] {
        var nodes = Set(events(for: clusterID).map(\.nodeID))
        nodes.formUnion(participantObservations.filter { $0.clusterID == clusterID }.map(\.nodeID))
        if let owner = lease(for: clusterID)?.ownerNodeID, !owner.isEmpty { nodes.insert(owner) }
        return nodes.sorted()
    }
    func reportedName(for nodeID: String, clusterID: String) -> String? {
        if let name = participant(for: nodeID, clusterID: clusterID)?.nodeName { return name }
        let lease = lease(for: clusterID)
        if lease?.ownerNodeID == nodeID { return lease?.ownerNodeName }
        return events(for: clusterID).first { $0.nodeID == nodeID }?.nodeName
    }
    func participant(for nodeID: String, clusterID: String) -> ParticipantObservation? {
        participantObservations.first { $0.clusterID == clusterID && $0.nodeID == nodeID }
    }
    var guardingSummary: String {
        let count = configuration.guardedServices.count
        return "\(count) \(count == 1 ? "service" : "services") · \(activeServiceCount) with an owner"
    }
    var activeServiceCount: Int {
        configuration.guardedServices.filter { (lease(for: $0.clusterID)?.remainingSeconds ?? 0) > 0 }.count
    }
    var menuBarSymbol: String {
        if attentionItems.isEmpty { return "checkmark.shield" }
        if attentionItems.contains(where: { $0.health == .error }) { return "xmark.shield.fill" }
        return "exclamationmark.shield"
    }
    func nodeDisplayName(for nodeID: String, reportedName: String?, clusterID: String? = nil) -> String {
        let service = clusterID.flatMap(service(for:))
        return service?.nodeDisplayNames[nodeID] ?? WitnessNodeName.normalized(reportedName) ?? "Unnamed server"
    }

    func saveNodeDisplayName(_ name: String, for nodeID: String, clusterID: String) throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeID.isEmpty, nodeID.utf8.count <= 128,
              trimmed.isEmpty || WitnessNodeName.normalized(trimmed) != nil else {
            throw WitnessStorage.ConfigurationError.invalidNodeName
        }
        var draft = configuration
        guard let index = draft.services.firstIndex(where: { $0.clusterID == clusterID }) else {
            throw WitnessStorage.ConfigurationError.invalid
        }
        draft.services[index].nodeDisplayNames[nodeID] = trimmed.isEmpty ? nil : trimmed
        guard draft.isValid else { throw WitnessStorage.ConfigurationError.invalidNodeName }
        if !preview { try WitnessStorage.save(draft) }
        // A cosmetic rename must never restart the listener or change a lease.
        configuration = draft
    }
    var isRecovering: Bool { (snapshot?.recoverySeconds ?? 0) > 0 }
    var statusText: String { state == .running && isRecovering ? "Recovering" : state.rawValue }
    var localURL: String {
        let host = configuration.bindAddress == "::1" ? "[::1]" : "127.0.0.1"
        return "http://\(host):\(listenerPort.map(Int.init) ?? configuration.port)"
    }

    /// Produces the secret-free input for a support report. Existing snapshots
    /// already bound history and observation counts, so this does no I/O and
    /// cannot delay lease handling.
    func diagnosticSnapshot(now: Date = Date()) -> RuruDiagnostics.Snapshot {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        let process = ProcessInfo.processInfo
        let events = snapshot?.events ?? []

        let services = configuration.guardedServices.enumerated().map { index, service in
            let serviceEvents = events.filter { $0.clusterID == service.clusterID }
            let observations = participantObservations.filter { $0.clusterID == service.clusterID }
            let nodeIDs = Set(serviceEvents.map(\.nodeID))
                .union(observations.map(\.nodeID))
                .union(lease(for: service.clusterID).map { [$0.ownerNodeID] } ?? [])
                .sorted()
            let aliases = Dictionary(uniqueKeysWithValues: nodeIDs.enumerated().map { ("participant-\($0.offset + 1)", $0.element) })
            let aliasFor: (String) -> String = { nodeID in
                aliases.first(where: { $0.value == nodeID })?.key ?? "participant-unknown"
            }
            let policy = configuration.coordinationPolicy(for: service.id)
            let locations = coordinationLocations.filter { $0.clusterID == service.clusterID }
            let currentLease = lease(for: service.clusterID)
            return RuruDiagnostics.Snapshot.Service(
                identifier: "service-\(index + 1)", kind: service.kind.rawValue, leaseSeconds: service.leaseSeconds,
                coordinationEnabled: policy.enabled, allowedOriginCount: policy.allowedOrigins.count,
                locationCount: locations.count, freshLocationCount: locations.filter(\.fresh).count,
                pendingPairingCount: pairingRequests(for: service.clusterID).count,
                pendingWebsiteCount: coordinationEnrollments.filter { $0.clusterID == service.clusterID }.count,
                lease: currentLease.map { .init(owner: $0.ownerNodeID.isEmpty ? nil : aliasFor($0.ownerNodeID),
                                                term: $0.term, remainingSeconds: $0.remainingSeconds) },
                participants: observations.sorted { $0.nodeID < $1.nodeID }.map {
                    .init(identifier: aliasFor($0.nodeID), role: $0.role.rawValue, ageSeconds: $0.ageSeconds,
                          fresh: $0.fresh, hasWebUI: $0.webUIURL != nil)
                },
                events: serviceEvents.map {
                    .init(time: $0.time, action: $0.action, participant: aliasFor($0.nodeID), term: $0.term)
                }
            )
        }

        #if arch(arm64)
        let architecture = "arm64"
        #elseif arch(x86_64)
        let architecture = "x86_64"
        #else
        let architecture = "unknown"
        #endif
        return .init(generatedAt: now, appVersion: version, appBuild: build,
                     operatingSystem: process.operatingSystemVersionString,
                     architecture: architecture,
                     authorityState: statusText, listenerPort: listenerPort,
                     recoverySeconds: snapshot?.recoverySeconds ?? 0, hasAuthorityError: error != nil,
                     internetState: internetStatus.state.rawValue, hasInternetError: internetError != nil || internetStatus.state == .error,
                     services: services)
    }

    func start() async {
        guard !busy, state != .running else { return }
        guard !preview, let store, configuration.isValid else {
            if !preview, error == nil { error = "The ownership database is unavailable." }
            return
        }
        busy = true
        state = .starting
        error = nil
        do {
            for service in configuration.guardedServices where serviceCredentials[service.clusterID] == nil {
                serviceCredentials[service.clusterID] = try WitnessKeychain.loadOrCreate(account: service.keychainAccount)
            }
            let server = try WitnessHTTPServer(store: store, services: accessCredentials(), catalogue: catalogue, pairing: pairing, participants: participants)
            self.server = server
            listenerPort = try await server.start(bindAddress: configuration.bindAddress, port: UInt16(configuration.port))
            state = .running
            serviceStartedAt = .now
            if pollTask == nil { beginPolling() }
        } catch {
            await server?.stop()
            server = nil
            state = .failed
            serviceStartedAt = nil
            self.error = error.localizedDescription
        }
        busy = false
        await syncInternetAccess()
        await refresh()
    }

    func stop() async {
        guard !busy else { return }
        busy = true
        await internetAccess.stop()
        internetStatus = WitnessInternetStatus()
        transportDiagnostics = nil
        await server?.stop()
        server = nil
        listenerPort = nil
        state = .stopped
        serviceStartedAt = nil
        busy = false
    }

    func saveConfiguration(_ draft: WitnessConfiguration) async throws {
        // Saves app-wide settings only; services have their own operations.
        var draft = draft
        draft.services = configuration.services
        draft.servicePrimaryPreferences = configuration.servicePrimaryPreferences
        draft.serviceCoordinationPolicies = configuration.serviceCoordinationPolicies
        guard draft.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        guard !busy, !internetBusy, !savingConfiguration else { throw WitnessStorage.ConfigurationError.invalid }
        savingConfiguration = true
        defer { savingConfiguration = false }
        guard draft.tunnel == configuration.tunnel,
              !draft.tunnel.isConfigured || draft.port == configuration.port else {
            throw WitnessStorage.ConfigurationError.invalid
        }
        if preview {
            configuration = draft
            applyDockVisibility()
            return
        }
        let wasRunning = state == .running
        let listenerChanged = draft.bindAddress != configuration.bindAddress || draft.port != configuration.port
        // Save before changing the listener, so a disk error keeps the old service.
        try WitnessStorage.save(draft)
        if wasRunning && listenerChanged { await stop() }
        configuration = draft
        applyDockVisibility()
        if wasRunning && listenerChanged { await start() }
    }

    func setupInternetAccess(hostname: String, tokenDraft: String) async throws {
        guard !preview, !shuttingDown, store != nil, !busy, !internetBusy, !savingConfiguration else { throw WitnessStorage.ConfigurationError.invalid }
        internetBusy = true
        internetError = nil
        defer { internetBusy = false; internetProgress = "" }
        do {
            let token = WitnessInternetSetup.normalizedToken(tokenDraft.isEmpty
                ? (try WitnessKeychain.read("cloudflare-api-token") ?? "") : tokenDraft)
            // Persist the private naming identity before the first Cloudflare write.
            try WitnessStorage.save(configuration)
            let result = try await WitnessInternetSetup().provision(apiToken: token, hostname: hostname,
                settings: configuration.tunnel, port: configuration.port,
                progress: { [weak self] message in
                    await MainActor.run { self?.internetProgress = message }
                }, checkpoint: { [weak self] result in
                    guard let self else { throw CancellationError() }
                    try await self.saveProvisionedTunnel(result, apiToken: token)
                })
            try saveProvisionedTunnel(result, apiToken: token)
            // The tunnel always originates on IPv4 loopback on the witness host.
            if state == .running { await stop() }
            await start()
        } catch {
            internetError = error.localizedDescription
            await syncInternetAccess()
            throw error
        }
    }

    private func saveProvisionedTunnel(_ result: ProvisionedWitnessTunnel, apiToken: String) throws {
        guard !shuttingDown else { throw CancellationError() }
        try WitnessKeychain.save(apiToken, account: "cloudflare-api-token")
        try WitnessKeychain.save(result.connectorToken, account: "cloudflare-connector-token")
        var saved = configuration
        saved.bindAddress = "127.0.0.1"
        saved.publicEndpoint = result.settings.publicURL
        saved.tunnel = result.settings
        try WitnessStorage.save(saved)
        configuration = saved
    }

    func pauseInternetAccess() async throws {
        guard !preview, !busy, !internetBusy, !savingConfiguration else { return }
        var saved = configuration
        saved.tunnel.enabled = false
        try WitnessStorage.save(saved)
        configuration = saved
        await internetAccess.stop()
        internetStatus = WitnessInternetStatus()
        transportDiagnostics = nil
    }

    func resumeInternetAccess() async throws {
        guard !preview, !busy, !internetBusy, !savingConfiguration, configuration.tunnel.isConfigured else { return }
        // Fail before saving if the host credential is missing.
        guard let token = try WitnessKeychain.read("cloudflare-connector-token"), !token.isEmpty else {
            throw WitnessInternetSetup.SetupError.missingToken
        }
        var saved = configuration
        saved.tunnel.enabled = true
        try WitnessStorage.save(saved)
        configuration = saved
        transportDiagnostics = nil
        if state != .running { await start() }
        else { await syncInternetAccess() }
    }

    /// Reads the local listener, Cloudflare connector telemetry, and public
    /// health route. This deliberately has no lifecycle, storage, or lease
    /// side effects, so an operator can run it during an outage investigation.
    func inspectInternetAccess() async {
        guard !preview, !busy, !internetBusy, !transportDiagnosticsBusy else { return }
        transportDiagnosticsBusy = true
        defer { transportDiagnosticsBusy = false }
        let localEndpoint = listenerPort.flatMap { URL(string: "http://127.0.0.1:\($0)") }
        let publicEndpoint = URL(string: configuration.publicEndpoint)
        transportDiagnostics = await internetAccess.inspectTransport(
            localEndpoint: localEndpoint,
            publicEndpoint: publicEndpoint
        )
    }

    private func syncInternetAccess() async {
        guard !preview, state == .running, configuration.tunnel.enabled else {
            await internetAccess.stop()
            internetStatus = WitnessInternetStatus()
            return
        }
        do {
            guard configuration.bindAddress == "127.0.0.1",
                  let token = try WitnessKeychain.read("cloudflare-connector-token"), !token.isEmpty else {
                throw WitnessInternetSetup.SetupError.missingToken
            }
            await internetAccess.start(settings: configuration.tunnel, token: token) { [weak self] status in
                self?.internetStatus = status
            }
        } catch {
            internetStatus = WitnessInternetStatus(state: .error,
                publicURL: configuration.publicEndpoint, detail: error.localizedDescription)
        }
    }

    func shutdown() async {
        shuttingDown = true
        pollTask?.cancel()
        snapshotTask?.cancel()
        await internetAccess.stop()
        await server?.stop()
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard !preview else { return }
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try await SMAppService.mainApp.unregister() }
            refreshLoginStatus()
        } catch { self.error = "Launch at login: \(error.localizedDescription)" }
    }

    func refreshLoginStatus() {
        guard !preview else { return }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginNeedsApproval = SMAppService.mainApp.status == .requiresApproval
    }

    func applyDockVisibility() {
        let policy: NSApplication.ActivationPolicy = configuration.showInDock ? .regular : .accessory
        if NSApplication.shared.activationPolicy() != policy {
            let windows = NSApplication.shared.windows.filter { $0.isVisible && $0.canBecomeMain }
            NSApplication.shared.setActivationPolicy(policy)
            for window in windows { window.makeKeyAndOrderFront(nil) }
            if !windows.isEmpty { NSApplication.shared.activate() }
        }
    }

    private func accessCredentials(configuration: WitnessConfiguration? = nil, tokens: [String: String]? = nil) throws -> [WitnessServiceCredential] {
        let configuration = configuration ?? self.configuration
        let tokens = tokens ?? serviceCredentials
        return try configuration.guardedServices.map { service in
            guard let token = tokens[service.clusterID] else { throw WitnessStorage.ConfigurationError.invalid }
            return WitnessServiceCredential(clusterID: service.clusterID, token: token,
                                            primaryPreference: configuration.primaryPreference(for: service.id),
                                            coordinationPolicy: configuration.coordinationPolicy(for: service.id),
                                            leaseSeconds: Double(service.leaseSeconds))
        }
    }

    func addGuardedService(name: String, clusterID: String, kind: GuardedService.Kind,
                           leaseSeconds: Int = GuardedService.defaultLeaseSeconds) async throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        let service = GuardedService(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     clusterID: clusterID.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
                                     leaseSeconds: leaseSeconds)
        saved.services.append(service)
        guard saved.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        busy = true
        defer { busy = false }
        var tokens = serviceCredentials
        if !preview {
            let token = try WitnessKeychain.randomToken()
            tokens[service.clusterID] = token
            let access = server == nil ? nil : try accessCredentials(configuration: saved, tokens: tokens)
            try WitnessKeychain.save(token, account: service.keychainAccount)
            // Metadata must survive restart before the new service is admitted.
            try WitnessStorage.save(saved)
            if let access { try await server?.configureServices(access) }
        }
        serviceCredentials = tokens
        configuration = saved
    }

    func removeGuardedService(id: String) async throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        guard let service = configuration.guardedServices.first(where: { $0.id == id }) else {
            throw WitnessStorage.ConfigurationError.invalid
        }
        var saved = configuration
        try saved.removeGuardedService(id: id)
        guard saved.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        var tokens = serviceCredentials
        tokens.removeValue(forKey: service.clusterID)
        busy = true
        defer { busy = false }
        if !preview {
            // A failed startup must still allow catalog removal. No database reset
            // or Keychain access is needed to stop admitting this service.
            let access = server == nil ? nil : try accessCredentials(configuration: saved, tokens: tokens)
            try WitnessStorage.save(saved)
            do { if let access { try await server?.configureServices(access) } }
            catch {
                await server?.stop()
                server = nil
                listenerPort = nil
                state = .failed
                serviceStartedAt = nil
                self.error = error.localizedDescription
                await internetAccess.stop()
                internetStatus = WitnessInternetStatus()
            }
        }
        serviceCredentials = tokens
        configuration = saved
        coordinationLocations.removeAll { $0.clusterID == service.clusterID }
        coordinationEnrollments.removeAll { $0.clusterID == service.clusterID }
        participantObservations.removeAll { $0.clusterID == service.clusterID }
        await pairing.revoke(clusterID: service.clusterID)
        if !preview, let access = try? accessCredentials() {
            try await catalogue.configureServices(access)
            try await participants.configureServices(access)
        }
        // Durable leases and terms remain in DuckDB. Already granted permission
        // expires normally; old tokens cannot acquire or renew through the router.
    }

    func replaceLegacyStorage() async throws {
        guard legacyStorageNeedsReplacement, store == nil, server == nil,
              !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        saved.servicePrimaryPreferences = [:]
        saved.serviceCoordinationPolicies = [:]
        // Every service gets a fresh ownership group, so no old term is reused.
        for index in saved.services.indices {
            saved.services[index].clusterID = "service-" + UUID().uuidString.lowercased()
            saved.services[index].nodeDisplayNames = [:]
        }
        saved.startAutomatically = false
        guard saved.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        busy = true
        defer { busy = false }
        if preview {
            configuration = saved
            legacyStorageNeedsReplacement = false
            storageArchivePath = "/Preview/Legacy Archives"
            state = .stopped
            error = nil
            return
        }
        var tokens: [String: String] = [:]
        do {
            let url = WitnessStorage.databaseURL
            let archive = try LegacyAuthorityReplacement.archiveAndReplace(databaseURL: url) {
                for service in saved.guardedServices {
                    let token = try WitnessKeychain.randomToken()
                    try WitnessKeychain.save(token, account: service.keychainAccount)
                    tokens[service.clusterID] = token
                }
                try WitnessStorage.save(saved)
                configuration = saved
                serviceCredentials = tokens
            }
            storageArchivePath = archive.path
            legacyStorageNeedsReplacement = false
            store = try LeaseStore(databaseURL: url)
            try WitnessStorage.recordAuthorityCreated()
            beginSnapshots()
            state = .stopped
            error = nil
            beginPolling()
            await refresh()
        } catch {
            self.error = error.localizedDescription
            throw error
        }
    }

    // MARK: Backup

    struct BackupContents {
        let url: URL
        let createdAt: Date?
        let configuration: WitnessConfiguration?
        let leases: LeaseSnapshot?
    }

    var backupAvailable: Bool { !preview }

    /// Daily snapshot while the authority is open; the newest 14 are kept.
    private func beginSnapshots() {
        snapshotTask?.cancel()
        lastSnapshotDate = WitnessStorage.latestSnapshotDate()
        snapshotTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.lastSnapshotDate.map({ Date().timeIntervalSince($0) >= 86_400 }) ?? true {
                    await self.takeSnapshot()
                }
                do { try await Task.sleep(for: .seconds(3_600)) } catch { return }
            }
        }
    }

    func takeSnapshot() async {
        guard !preview, let store else { return }
        do {
            let snapshot = try await store.makeSnapshot()
            try WitnessStorage.writeSnapshot(snapshot)
            lastSnapshotDate = snapshot.createdAt
            snapshotError = nil
        } catch { snapshotError = error.localizedDescription }
    }

    /// Settings plus current terms and history. Never includes credentials.
    func exportBackup(to url: URL) async throws {
        guard !preview else { throw WitnessStorage.ConfigurationError.invalid }
        var leases = try await store?.makeSnapshot()
        if leases == nil, let latest = WitnessStorage.snapshotFiles().last {
            leases = try LeaseSnapshot.decode(Data(contentsOf: latest))
        }
        try RuruBackup(configuration: configuration, leases: leases).encoded().write(to: url, options: .atomic)
    }

    func readBackup(at url: URL) throws -> BackupContents {
        let contents = try RuruBackup.read(Data(contentsOf: url))
        let created = (try? LeaseSnapshot.decoder.decode(RuruBackup.self, from: Data(contentsOf: url)))?.createdAt
            ?? contents.leases?.createdAt
        return BackupContents(url: url, createdAt: created, configuration: contents.configuration, leases: contents.leases)
    }

    /// Explicit disaster restore. Stops the service, archives the current
    /// database and rebuilds it with every term raised by LeaseRestore.termMargin,
    /// then leaves the authority stopped and quarantined for a full lease.
    func restoreBackup(_ backup: BackupContents, includeSettings: Bool) async throws {
        guard !preview, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        guard !legacyStorageNeedsReplacement else {
            throw RuruBackup.Failure("Set Up DuckDB before restoring a backup.")
        }
        let imported = try includeSettings
            ? backup.configuration.map { try RuruBackup.importedConfiguration($0, current: configuration) } : nil
        guard imported != nil || backup.leases != nil else { return }
        if server != nil || state == .running { await stop() }
        guard !busy else { throw WitnessStorage.ConfigurationError.invalid }
        busy = true
        defer { busy = false }
        pollTask?.cancel()
        snapshotTask?.cancel()
        do {
            if let leases = backup.leases {
                let known = try await store?.checkpointedTerms()
                store = nil
                snapshot = nil
                var attempts = 0
                while true {
                    do {
                        try LeaseRestore.restore(databaseURL: WitnessStorage.databaseURL, snapshot: leases, knownTerms: known)
                        break
                    } catch LeaseRestoreError.authorityInUse where attempts < 20 {
                        // The released store closes once in-flight reads finish.
                        attempts += 1
                        try await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            if let imported {
                try WitnessStorage.save(imported)
                configuration = imported
                applyDockVisibility()
                serviceCredentials = [:]
                for service in imported.guardedServices {
                    serviceCredentials[service.clusterID] = try WitnessKeychain.loadOrCreate(account: service.keychainAccount)
                }
            }
        } catch {
            reopenAfterRestore()
            throw error
        }
        reopenAfterRestore()
        if let error { throw RuruBackup.Failure(error) }
    }

    private func reopenAfterRestore() {
        do {
            if store == nil {
                store = try LeaseStore(databaseURL: WitnessStorage.databaseURL)
                try WitnessStorage.recordAuthorityCreated()
            }
            state = .stopped
            error = nil
            beginSnapshots()
        } catch {
            state = .failed
            self.error = error.localizedDescription
        }
        beginPolling()
    }

    private func beginPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    /// Renames a service or changes its lease length. Neither interrupts the
    /// current owner: a new length applies from the owner's next renewal.
    func updateService(id: String, name: String, leaseSeconds: Int) async throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        guard let index = saved.services.firstIndex(where: { $0.id == id }) else { throw WitnessStorage.ConfigurationError.invalid }
        saved.services[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        saved.services[index].leaseSeconds = leaseSeconds
        guard saved.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        let access = server == nil || preview ? nil : try accessCredentials(configuration: saved)
        busy = true
        defer { busy = false }
        if !preview { try WitnessStorage.save(saved) }
        configuration = saved
        if let access { try await server?.configureServices(access) }
    }

    func setPreferredPrimary(_ nodeID: String?, for serviceID: String) async throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        guard try saved.setPreferredPrimary(nodeID, for: serviceID) else { return }
        guard saved.isValid else { throw WitnessStorage.ConfigurationError.invalidPrimaryPreference }
        let access = server == nil ? nil : try accessCredentials(configuration: saved)
        busy = true
        defer { busy = false }
        // Publish operator intent only after its durable configuration checkpoint.
        // The same store, leases and authority clock stay alive.
        if !preview { try WitnessStorage.save(saved) }
        configuration = saved
        do { if let access { try await server?.configureServices(access) } }
        catch {
            await server?.stop()
            server = nil
            listenerPort = nil
            state = .failed
            serviceStartedAt = nil
            self.error = error.localizedDescription
            await internetAccess.stop()
            internetStatus = WitnessInternetStatus()
            throw error
        }
    }

    func setCoordinationPolicy(_ policy: CoordinationPolicy, for serviceID: String) async throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        try saved.setCoordinationPolicy(policy, for: serviceID)
        let access = preview ? nil : try? accessCredentials(configuration: saved)
        guard server == nil || access != nil else { throw WitnessStorage.ConfigurationError.invalid }
        busy = true
        defer { busy = false }
        if !preview { try WitnessStorage.save(saved) }
        configuration = saved
        // Publish catalogue intent independently of the lease router/listener.
        // Metadata policy changes cannot interrupt existing ownership requests.
        if let access { try await catalogue.configureServices(access) }
        if !policy.enabled, let cluster = configuration.guardedServices.first(where: { $0.id == serviceID })?.clusterID {
            coordinationLocations.removeAll { $0.clusterID == cluster }
        }
        if !preview { coordinationLocations = await catalogue.snapshot() }
        if !preview { coordinationEnrollments = await catalogue.pendingEnrollments() }
    }

    func approveCoordinationEnrollment(id: UUID, serviceID: String) async throws {
        let requests = preview ? coordinationEnrollments : await catalogue.pendingEnrollments()
        guard let request = requests.first(where: { $0.id == id }),
              configuration.guardedServices.contains(where: { $0.id == serviceID && $0.clusterID == request.clusterID }) else {
            throw EnrollmentError.expired
        }
        var saved = configuration
        try saved.approveCoordinationOrigin(request.origin, for: serviceID)
        // Reuse the checkpoint-before-publication path; no remote policy writes.
        try await setCoordinationPolicy(saved.coordinationPolicy(for: serviceID), for: serviceID)
        if preview { coordinationEnrollments.removeAll { $0.origin == request.origin && $0.clusterID == request.clusterID } }
    }

    func rejectCoordinationEnrollment(id: UUID) async {
        if !preview { await catalogue.rejectEnrollment(id: id) }
        coordinationEnrollments.removeAll { $0.id == id }
    }

    private enum EnrollmentError: LocalizedError {
        case expired
        var errorDescription: String? { "This request has expired or been withdrawn. Wait for the server to request access again." }
    }

    func hasCredential(for clusterID: String) -> Bool { serviceCredentials[clusterID]?.isEmpty == false }

    func copyToken(clusterID: String) { copy(serviceCredentials[clusterID] ?? "") }
    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyConnectionDetails(clusterID: String) {
        guard !configuration.publicEndpoint.isEmpty,
              let token = serviceCredentials[clusterID] else { return }
        let details = ["endpoint": configuration.publicEndpoint, "clusterID": clusterID, "token": token]
        guard let data = try? JSONEncoder().encode(details), let text = String(data: data, encoding: .utf8) else { return }
        copy(text)
    }

    private func refresh() async {
        participantObservations = await participants.snapshot().filter { observation in
            configuration.guardedServices.contains { $0.clusterID == observation.clusterID }
        }
        pairingCodes = await pairing.activeCodes()
        pairingRequests = await pairing.pendingRequests()
        coordinationEnrollments = await catalogue.pendingEnrollments()
        coordinationLocations = await catalogue.snapshot().filter { location in
            configuration.guardedServices.contains { $0.clusterID == location.clusterID && configuration.coordinationPolicy(for: $0.id).enabled }
        }
        do {
            snapshot = try await store?.snapshot()
            if let failure = await server?.failure() {
                state = .failed
                serviceStartedAt = nil
                error = failure
                await internetAccess.stop()
                internetStatus = WitnessInternetStatus()
            }
        } catch {
            self.error = error.localizedDescription
            state = .failed
            serviceStartedAt = nil
            await internetAccess.stop()
            internetStatus = WitnessInternetStatus()
            // A storage failure closes the listener; it never resets ownership.
            await server?.stop()
            server = nil
        }
        await evaluateAlerts()
    }

    // MARK: Cloudflare

    var hasSavedCloudflareToken: Bool {
        !preview && ((try? WitnessKeychain.read("cloudflare-api-token")) ?? nil).map { !$0.isEmpty } == true
    }

    /// The domains a Cloudflare token can manage. An empty draft uses the saved token.
    func cloudflareDomains(tokenDraft: String) async throws -> [CloudflareDomain] {
        if preview {
            try await Task.sleep(for: .milliseconds(400))
            return [.init(id: "preview-1", name: "example.com"), .init(id: "preview-2", name: "ruruapp.dev")]
        }
        let token = tokenDraft.isEmpty ? ((try? WitnessKeychain.read("cloudflare-api-token")) ?? nil) ?? "" : tokenDraft
        return try await WitnessInternetSetup().listDomains(apiToken: token)
    }

    /// Provisions the tunnel, then waits for the connector to register with
    /// Cloudflare. If it doesn't within `timeout`, the error includes the
    /// connector's recent output instead of leaving setup spinning.
    func connectCloudflare(hostname: String, tokenDraft: String, timeout: Duration = .seconds(90)) async throws {
        if preview {
            // Display-only: walk the progress messages and show a connected tunnel.
            for message in ["Checking Cloudflare access…", "Checking the hostname…", "Creating Ruru’s tunnel…",
                            "Connecting the local Ruru service…", "Creating the HTTPS address…",
                            "Starting Cloudflare’s connector on this Mac…"] {
                internetProgress = message
                try await Task.sleep(for: .milliseconds(450))
            }
            internetProgress = ""
            configuration.tunnel.hostname = hostname
            configuration.tunnel.tunnelID = "00000000-0000-4000-8000-000000000009"
            configuration.tunnel.accountID = "preview"
            configuration.tunnel.enabled = true
            configuration.publicEndpoint = configuration.tunnel.publicURL
            internetStatus = WitnessInternetStatus(state: .enabled, publicURL: configuration.publicEndpoint, detail: "Connected")
            return
        }
        try await setupInternetAccess(hostname: hostname, tokenDraft: tokenDraft)
        internetProgress = "Starting Cloudflare’s connector on this Mac…"
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if internetStatus.state == .enabled { internetProgress = ""; return }
            if internetStatus.state == .error { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        internetProgress = ""
        let lines = await internetAccess.diagnostics().suffix(6)
        let reason = internetStatus.state == .error ? internetStatus.detail
            : "The Cloudflare connector didn’t connect within \(Int(timeout.components.seconds)) seconds."
        throw RuruBackup.Failure(lines.isEmpty ? reason : reason + "\n\nConnector output:\n" + lines.joined(separator: "\n"))
    }

    // MARK: Setup

    /// Records setup choices (completion, local-only testing) without
    /// touching services or the listener.
    func updateSetup(_ change: (inout RuruSetupState) -> Void) async throws {
        var draft = configuration
        change(&draft.setup)
        guard draft.setup != configuration.setup else { return }
        try await saveConfiguration(draft)
    }

    /// A readable, unique cluster ID from a service name: "Media Server" → "media-server".
    func suggestedClusterID(for name: String) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        let base = String((slug.isEmpty ? "service" : slug).prefix(48))
        var candidate = base, index = 2
        while configuration.services.contains(where: { $0.clusterID == candidate }) {
            candidate = base + "-\(index)"; index += 1
        }
        return candidate
    }

    /// Checks that Ruru answers at its public address through Cloudflare, as a
    /// server elsewhere would. Retries while DNS and the tunnel come up.
    /// Returns nil on success, or a description of the last failure.
    func verifyPublicAddress(attempts: Int = 12) async -> String? {
        guard !preview else { return nil }
        guard let url = URL(string: configuration.publicEndpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/health") else {
            return "Ruru has no public address yet."
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var last = "No response"
        for attempt in 0..<attempts {
            if attempt > 0 { try? await Task.sleep(for: .seconds(5)) }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if (status == 200 || status == 503), body?["ready"] != nil { return nil }
                last = "HTTP \(status)"
            } catch { last = error.localizedDescription }
        }
        return "Ruru isn’t reachable at \(configuration.publicEndpoint) yet (\(last)). DNS can take a few minutes; try again shortly."
    }

    struct Attention: Identifiable {
        enum Tier: String { case authority = "Authority", guarding = "Guarding", transport = "Transport" }
        enum Action { case continueSetup, start, setupStorage, page(WitnessPage) }
        let id: String
        let tier: Tier
        let title: String
        let detail: String
        let health: WitnessHealth
        let actionTitle: String
        let action: Action
    }

    /// What stops Ruru being useful right now, most important first. Shown on
    /// Overview, each with the one action that fixes it.
    var attentionItems: [Attention] {
        var items: [Attention] = []

        // Authority tier — highest priority
        if let error {
            items.append(.init(id: "authority-error", tier: .authority, title: "Authority unavailable",
                               detail: error, health: .error,
                               actionTitle: legacyStorageNeedsReplacement ? "Set Up DuckDB…" : "Review",
                               action: legacyStorageNeedsReplacement ? .setupStorage : .page(.internet)))
        }
        if isRecovering {
            items.append(.init(id: "recovery", tier: .authority, title: "Restart quarantine",
                               detail: "Renewals and new grants refused for \(Int(ceil(snapshot?.recoverySeconds ?? 0))) seconds while earlier leases expire.",
                               health: .warning, actionTitle: "Guarding", action: .page(.guarding)))
        }

        // Guarding tier — pairing requests
        let waiting = pairingRequests.count
        if waiting > 0 {
            items.append(.init(id: "pairing", tier: .guarding,
                               title: waiting == 1 ? "A server wants to pair" : "\(waiting) servers want to pair",
                               detail: "Approve or reject in the service’s page.", health: .warning,
                               actionTitle: "Review", action: .page(.guarding)))
        }
        guard configuration.setup.completed else {
            items.insert(.init(id: "setup", tier: .authority, title: "Finish setting up Ruru",
                               detail: "A few steps remain before your servers can use Ruru.", health: .warning,
                               actionTitle: "Continue Setup", action: .continueSetup), at: 0)
            return items
        }
        if state == .stopped, !legacyStorageNeedsReplacement {
            items.append(.init(id: "stopped", tier: .authority, title: "Ruru is stopped",
                               detail: "Servers can’t take or keep ownership until it runs.",
                               health: .warning, actionTitle: "Start", action: .start))
        }

        // Transport tier
        if !configuration.tunnel.isConfigured, !configuration.setup.localOnly {
            items.append(.init(id: "address", tier: .transport, title: "No public address",
                               detail: "Servers on other Macs can’t reach Ruru until Internet Access is set up.",
                               health: .warning, actionTitle: "Set Up", action: .page(.internet)))
        }
        if internetStatus.state == .error {
            items.append(.init(id: "transport-error", tier: .transport, title: "Tunnel unavailable",
                               detail: internetStatus.detail, health: .error,
                               actionTitle: "Internet Access", action: .page(.internet)))
        }

        // Guarding tier — services
        if configuration.services.isEmpty {
            items.append(.init(id: "services", tier: .guarding, title: "No services yet",
                               detail: "Add an app such as SwiftBot, then pair its servers.",
                               health: .inactive, actionTitle: "Add Service", action: .page(.guarding)))
        }
        for service in configuration.services where knownNodes(for: service.clusterID).isEmpty
            && (pairedServers[service.clusterID] ?? []).isEmpty {
            items.append(.init(id: "unpaired-" + service.id, tier: .guarding,
                               title: "\(service.name) has no servers yet",
                               detail: "Pair its servers with a code from Connection Details.", health: .inactive,
                               actionTitle: "Pair", action: .page(.guarding)))
        }
        return items
    }

    // MARK: Pairing

    /// A single-use code a server can exchange for this service's connection
    /// details, once approved here. Only useful while the listener is running.
    func createPairingCode(for clusterID: String) async throws -> PairingDesk.Code {
        guard state == .running, service(for: clusterID) != nil else {
            throw RuruBackup.Failure("Start Ruru's service before pairing a server.")
        }
        let code: PairingDesk.Code
        do { code = try await pairing.createCode(for: clusterID) }
        catch { throw RuruBackup.Failure("Too many pairing codes are active. Wait for one to expire or cancel it.") }
        pairingCodes = await pairing.activeCodes()
        return code
    }

    func cancelPairingCode(_ code: String) async {
        await pairing.cancelCode(code)
        pairingCodes = await pairing.activeCodes()
    }

    func approvePairing(_ request: PairingDesk.Request) async throws {
        guard let service = service(for: request.clusterID), let token = serviceCredentials[request.clusterID] else {
            throw RuruBackup.Failure("This service no longer exists or its credential is unavailable.")
        }
        try await pairing.approve(request.id, with: .init(clusterID: service.clusterID, token: token,
                                                         leaseSeconds: Double(service.leaseSeconds)))
        pairedServers[request.clusterID, default: []].append(request.nodeName ?? request.nodeID)
        pairingRequests = await pairing.pendingRequests()
    }

    func rejectPairing(_ request: PairingDesk.Request) async {
        await pairing.reject(request.id)
        pairingRequests = await pairing.pendingRequests()
    }

    func pairingRequests(for clusterID: String) -> [PairingDesk.Request] {
        pairingRequests.filter { $0.clusterID == clusterID }
    }

    // MARK: Alerts

    private func evaluateAlerts() async {
        guard !preview, !shuttingDown else { return }
        let leases = snapshot?.leases ?? []
        let observation = RuruAlertMonitor.Observation(
            serviceRunning: state == .running, recovering: isRecovering,
            serviceFailure: state == .failed ? (error ?? "The service is unavailable.") : nil,
            tunnelError: internetStatus.state == .error ? internetStatus.detail : nil,
            snapshotError: snapshotError,
            owners: Dictionary(leases.filter { $0.remainingSeconds > 0 && !$0.ownerNodeID.isEmpty }.map {
                let contact = participant(for: $0.ownerNodeID, clusterID: $0.clusterID)
                return ($0.clusterID, RuruAlertMonitor.Owner(nodeID: $0.ownerNodeID,
                    name: nodeDisplayName(for: $0.ownerNodeID, reportedName: $0.ownerNodeName, clusterID: $0.clusterID),
                    webUIURL: contact?.fresh == true ? contact?.webUIURL : nil))
            }, uniquingKeysWith: { first, _ in first }),
            services: Dictionary(configuration.services.map { ($0.clusterID, $0.name) }, uniquingKeysWith: { first, _ in first }),
            releases: Set((snapshot?.events ?? []).filter { $0.action == "Released" }.map { "\($0.clusterID)|\($0.id)" }))
        var alerts = alertMonitor.observe(observation, at: Date())
        for request in pairingRequests where !announcedPairings.contains(request.id) {
            announcedPairings.insert(request.id)
            let server = request.nodeName ?? request.nodeID
            let service = serviceName(for: request.clusterID)
            alerts.append(RuruAlert(kind: .pairingRequest, key: "pair|" + request.id,
                                    title: "\(server) wants to pair with \(service)",
                                    detail: "Approve or reject it in Ruru → Guarding → \(service).",
                                    context: .init(service: service, server: server)))
        }
        announcedPairings.formIntersection(pairingRequests.map(\.id))
        guard !alerts.isEmpty else { return }
        if let failure = await alertDelivery.deliver(alerts, preferences: configuration.alerts, webhook: discordWebhook) {
            alertDeliveryError = failure
        }
    }

    /// Saves a Discord webhook to Keychain and turns Discord alerts on.
    func setDiscordWebhook(_ text: String) async throws {
        guard !preview else { throw WitnessStorage.ConfigurationError.invalid }
        guard let url = RuruDiscordWebhook.validated(text) else {
            throw RuruBackup.Failure("Paste a Discord webhook URL, such as https://discord.com/api/webhooks/….")
        }
        try WitnessKeychain.save(url.absoluteString, account: RuruDiscordWebhook.keychainAccount)
        discordWebhook = url
        discordConfigured = true
        alertDeliveryError = nil
        var draft = configuration
        draft.alerts.discord = true
        try await saveConfiguration(draft)
    }

    func removeDiscordWebhook() async throws {
        guard !preview else { return }
        try WitnessKeychain.delete(RuruDiscordWebhook.keychainAccount)
        discordWebhook = nil
        discordConfigured = false
        alertDeliveryError = nil
        var draft = configuration
        draft.alerts.discord = false
        try await saveConfiguration(draft)
    }

    /// Sends one test alert to every configured destination.
    func sendTestAlert() async {
        guard !preview else { return }
        let alert = RuruAlert(kind: .test, key: "test", title: "Ruru alerts are working",
                              detail: "You'll be told here when a service goes down or fails over.")
        var preferences = configuration.alerts
        preferences.discord = discordWebhook != nil
        alertDeliveryError = await alertDelivery.deliver([alert], preferences: preferences, webhook: discordWebhook)
    }
}
