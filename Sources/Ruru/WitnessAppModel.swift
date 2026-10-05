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
    @Published private(set) var snapshot: WitnessSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    @Published private(set) var launchAtLogin = false
    @Published private(set) var loginNeedsApproval = false
    @Published private(set) var listenerPort: UInt16?
    @Published private(set) var serviceStartedAt: ContinuousClock.Instant?
    @Published private(set) var legacyStorageNeedsReplacement = false
    @Published private(set) var storageArchivePath: String?

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

    init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--preview")) {
        self.preview = preview
        if preview {
            if ProcessInfo.processInfo.arguments.contains("--preview-legacy-storage") {
                legacyStorageNeedsReplacement = true
                state = .failed
                error = LegacyAuthorityStorageError().localizedDescription
            }
            return
        }
        do {
            configuration = try WitnessStorage.load()
            store = try LeaseStore(databaseURL: WitnessStorage.directory.appendingPathComponent("leases.duckdb"))
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

    var currentLease: LeaseStatus? { lease(for: configuration.clusterID) }
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
    var ownerText: String {
        guard let lease = currentLease, lease.remainingSeconds > 0 else { return "No active owner" }
        return nodeDisplayName(for: lease.ownerNodeID, reportedName: lease.ownerNodeName)
    }
    func nodeDisplayName(for nodeID: String, reportedName: String?, clusterID: String? = nil) -> String {
        let service = service(for: clusterID ?? configuration.clusterID)
        return service?.nodeDisplayNames[nodeID] ?? WitnessNodeName.normalized(reportedName) ?? "Unnamed server"
    }

    func saveNodeDisplayName(_ name: String, for nodeID: String, clusterID: String? = nil) throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nodeID.isEmpty, nodeID.utf8.count <= 128,
              trimmed.isEmpty || WitnessNodeName.normalized(trimmed) != nil else {
            throw WitnessStorage.ConfigurationError.invalidNodeName
        }
        var draft = configuration
        let cluster = clusterID ?? configuration.clusterID
        if service(for: cluster)?.id == "swiftbot" {
            draft.nodeDisplayNames[nodeID] = trimmed.isEmpty ? nil : trimmed
        } else if let index = draft.additionalServices.firstIndex(where: { $0.clusterID == cluster }) {
            draft.additionalServices[index].nodeDisplayNames[nodeID] = trimmed.isEmpty ? nil : trimmed
        } else { throw WitnessStorage.ConfigurationError.invalid }
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
            let server = try WitnessHTTPServer(store: store, services: accessCredentials())
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
        var draft = draft
        draft.nodeDisplayNames = configuration.nodeDisplayNames
        draft.primaryServiceName = configuration.primaryServiceName
        draft.primaryServiceRemoved = configuration.primaryServiceRemoved
        draft.additionalServices = configuration.additionalServices
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
        let listenerChanged = draft.clusterID != configuration.clusterID || draft.bindAddress != configuration.bindAddress || draft.port != configuration.port
        // Save before changing the listener, so a disk error keeps the old service.
        try WitnessStorage.save(draft)
        if wasRunning && listenerChanged { await stop() }
        if !configuration.primaryServiceRemoved, draft.clusterID != configuration.clusterID {
            let credential = serviceCredentials[configuration.clusterID]
            serviceCredentials.removeValue(forKey: configuration.clusterID)
            serviceCredentials[draft.clusterID] = credential
        }
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
            return WitnessServiceCredential(clusterID: service.clusterID, token: token)
        }
    }

    func addGuardedService(name: String, clusterID: String, kind: GuardedService.Kind) async throws {
        guard !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        let service = GuardedService(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                     clusterID: clusterID.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind)
        saved.additionalServices.append(service)
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
        // Durable leases and terms remain in DuckDB. Already granted permission
        // expires normally; old tokens cannot acquire or renew through the router.
    }

    func replaceLegacyStorage(newClusterID: String) async throws {
        guard legacyStorageNeedsReplacement, store == nil, server == nil,
              !busy, !internetBusy, !savingConfiguration, !shuttingDown else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        let cluster = newClusterID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cluster.isEmpty, !configuration.guardedServices.contains(where: { $0.clusterID == cluster }),
              cluster != configuration.clusterID else { throw WitnessStorage.ConfigurationError.invalid }
        saved.clusterID = cluster
        saved.nodeDisplayNames = [:]
        for index in saved.additionalServices.indices {
            saved.additionalServices[index].clusterID = "service-" + UUID().uuidString.lowercased()
            saved.additionalServices[index].nodeDisplayNames = [:]
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
            let url = WitnessStorage.directory.appendingPathComponent("leases.duckdb")
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
            state = .stopped
            error = nil
            beginPolling()
            await refresh()
        } catch {
            self.error = error.localizedDescription
            throw error
        }
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

    func renameService(id: String, name: String) throws {
        guard !busy, !internetBusy, !savingConfiguration else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if id == "swiftbot" { saved.primaryServiceName = name }
        else if let index = saved.additionalServices.firstIndex(where: { $0.id == id }) {
            saved.additionalServices[index].name = name
        } else { throw WitnessStorage.ConfigurationError.invalid }
        guard saved.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        if !preview { try WitnessStorage.save(saved) }
        configuration = saved
    }

    func hasCredential(for clusterID: String) -> Bool { serviceCredentials[clusterID]?.isEmpty == false }

    func copyToken(clusterID: String? = nil) { copy(serviceCredentials[clusterID ?? configuration.clusterID] ?? "") }
    func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func copyConnectionDetails(clusterID: String? = nil) {
        guard !configuration.publicEndpoint.isEmpty,
              let token = serviceCredentials[clusterID ?? configuration.clusterID] else { return }
        let details = ["endpoint": configuration.publicEndpoint, "clusterID": clusterID ?? configuration.clusterID, "token": token]
        guard let data = try? JSONEncoder().encode(details), let text = String(data: data, encoding: .utf8) else { return }
        copy(text)
    }

    private func refresh() async {
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
    }
}
