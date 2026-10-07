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
    private let internetAccess = WitnessInternetAccess()
    private var shuttingDown = false

    private var store: LeaseStore?
    private var server: WitnessHTTPServer?
    private var serviceCredentials: [String: String] = [:]
    private var savingConfiguration = false
    private var pollTask: Task<Void, Never>?
    private let preview: Bool

    init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview") ||
         ProcessInfo.processInfo.arguments.contains("--preview-screenshots")) {
        self.preview = preview
        if preview {
            // Display-only service; previews never touch storage or Keychain.
            configuration.services = [Self.previewService]
            if ProcessInfo.processInfo.arguments.contains("--preview-screenshots") {
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
            return
        }
        do {
            configuration = try WitnessStorage.load()
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
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, let current = self.snapshot else { return }
                self.snapshot = WitnessSnapshot(recoverySeconds: 0, leases: current.leases.map {
                    LeaseStatus(clusterID: $0.clusterID, ownerNodeID: $0.ownerNodeID, term: $0.term,
                                remainingSeconds: 30, ownerNodeName: $0.ownerNodeName)
                }, events: current.events)
            }
        }
    }

    func lease(for clusterID: String) -> LeaseStatus? { snapshot?.leases.first { $0.clusterID == clusterID } }
    func service(for clusterID: String) -> GuardedService? { configuration.guardedServices.first { $0.clusterID == clusterID } }
    func serviceName(for clusterID: String) -> String { service(for: clusterID)?.name ?? clusterID }
    func events(for clusterID: String) -> [WitnessEvent] { (snapshot?.events ?? []).filter { $0.clusterID == clusterID } }
    func knownNodes(for clusterID: String) -> [String] {
        var nodes = Set(events(for: clusterID).map(\.nodeID))
        if let owner = lease(for: clusterID)?.ownerNodeID, !owner.isEmpty { nodes.insert(owner) }
        return nodes.sorted()
    }
    func reportedName(for nodeID: String, clusterID: String) -> String? {
        let lease = lease(for: clusterID)
        if lease?.ownerNodeID == nodeID { return lease?.ownerNodeName }
        return events(for: clusterID).first { $0.nodeID == nodeID }?.nodeName
    }
    var guardingSummary: String {
        let count = configuration.guardedServices.count
        return "\(count) \(count == 1 ? "service" : "services") · \(activeServiceCount) with an owner"
    }
    var activeServiceCount: Int {
        configuration.guardedServices.filter { (lease(for: $0.clusterID)?.remainingSeconds ?? 0) > 0 }.count
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
            let server = try WitnessHTTPServer(store: store, services: accessCredentials(), catalogue: catalogue)
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
        if state != .running { await start() }
        else { await syncInternetAccess() }
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
        if !preview, let access = try? accessCredentials() { try await catalogue.configureServices(access) }
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
                ($0.clusterID, nodeDisplayName(for: $0.ownerNodeID, reportedName: $0.ownerNodeName, clusterID: $0.clusterID))
            }, uniquingKeysWith: { first, _ in first }),
            services: Dictionary(configuration.services.map { ($0.clusterID, $0.name) }, uniquingKeysWith: { first, _ in first }),
            releases: Set((snapshot?.events ?? []).filter { $0.action == "Released" }.map { "\($0.clusterID)|\($0.id)" }))
        let alerts = alertMonitor.observe(observation, at: Date())
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
