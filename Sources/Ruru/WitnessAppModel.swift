import AppKit
import ServiceManagement
import RuruAlerting
import SwiftUI
import WitnessKit

@MainActor
final class WitnessAppModel: ObservableObject {
    enum ServiceState: String { case stopped = "Stopped", starting = "Starting", running = "Running", failed = "Unavailable" }

    @Published private(set) var configuration = WitnessConfiguration() {
        didSet { alertingInputsChanged() }
    }
    @Published var selectedPage: WitnessPage? = .overview
    /// A service Overview asked Guarding to open; Guarding consumes it when it appears.
    var pendingGuardedServiceID: String?
    @Published private(set) var state: ServiceState = .stopped
    @Published private(set) var coordinationLocations: [CoordinationLocation] = []
    @Published private(set) var coordinationEnrollments: [CoordinationEnrollment] = []
    private let catalogue = CoordinationCatalogue()
    private let pairing = PairingDesk()
    private let participants = ParticipantPresence()
    private let operationalStatus = OperationalStatusRegistry()
    private let monitor = MonitorEngine(networkAvailable: { NetworkPathGate.shared.isAvailable })
    @Published private(set) var participantObservations: [ParticipantObservation] = []
    @Published private(set) var operationalObservations: [OperationalStatusObservation] = []
    @Published private(set) var participantActivity: [ParticipantActivityRecord] = []
    /// Custom service icons by service ID. Display-only; absent means the template icon.
    @Published private(set) var serviceIcons: [String: NSImage] = [:]
    /// Latest check state by monitor target ID. Observation only.
    @Published private(set) var monitorStates: [String: MonitorState] = [:]
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
    @Published private(set) var notifyConfigured = false
    @Published private(set) var alertDeliveryError: String?
    private var alertMonitor = RuruAlertMonitor()
    private var participantAlertMonitor = ParticipantAlertMonitor()
    private var operationalAlertMonitor = OperationalAlertMonitor()
    private let alertDelivery = RuruAlertDelivery()
    /// Legacy-path alerts waiting for delivery. Delivery runs on its own task so
    /// a slow destination never delays the refresh loop or anything lease related.
    private var pendingLegacyAlerts: [RuruAlert] = []
    private var legacyDeliveryTask: Task<Void, Never>?
    private var monitoringTask: Task<Void, Never>?
    /// Rule-based alerting. Independent of the lease authority: it has its own
    /// storage, queue and delivery, and starts even when authority storage fails.
    private var alertService: AlertService?
    @Published private(set) var alertSnapshot = AlertSnapshot()
    /// True when alert rules decide notifications. False only if rules couldn't be
    /// saved, in which case the earlier fixed alert settings keep working.
    @Published private(set) var alertRulesActive = false
    private var alertEngineReady = false
    private var ownershipTransferMonitor = OwnershipTransferMonitor()
    private var lastAlertSync: AlertSync?
    private struct AlertSync: Equatable {
        var capabilities: AlertCapabilities
        var monitors: Set<String>
        var allMonitors: Set<String>
        var services: Set<String>
    }
    private var discordWebhook: URL?
    private var notifyToken: String?

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
         ProcessInfo.processInfo.arguments.contains("--preview-activity") ||
         ProcessInfo.processInfo.arguments.contains("--preview-alerts") ||
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
            if ProcessInfo.processInfo.arguments.contains("--preview-activity") {
                loadScreenshotPreview()
                loadPreviewActivity()
                loadPreviewMonitoring()
                return
            }
            if ProcessInfo.processInfo.arguments.contains("--preview-alerts") {
                loadScreenshotPreview()
                loadPreviewMonitoring()
                loadPreviewAlerts()
                selectedPage = .alerts
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
            if ProcessInfo.processInfo.arguments.contains("--preview-ups-battery") {
                loadPreviewUPSBattery()
            }
            return
        }
        do {
            configuration = try WitnessStorage.load()
            showingSetup = !configuration.setup.completed
            // Service and monitor-target IDs are distinct UUIDs, so one icon table serves both.
            for id in configuration.guardedServices.map(\.id) + configuration.monitorTargets.map(\.id) {
                serviceIcons[id] = RuruServiceIcons.load(serviceID: id)
            }
            discordWebhook = (try? WitnessKeychain.read(RuruDiscordWebhook.keychainAccount)).flatMap { $0 }
                .flatMap(RuruDiscordWebhook.validated)
            discordConfigured = discordWebhook != nil
            notifyToken = (try? WitnessKeychain.read(RuruNotify.keychainAccount)).flatMap { $0 }
            notifyConfigured = notifyToken != nil && RuruNotify.validID(configuration.notifyID) != nil
            // Monitoring does not depend on the lease authority: it starts first, and
            // keeps running even when authority storage fails to open below.
            let monitor = monitor, targets = configuration.monitorTargets
            Task { await monitor.configure(targets) }
            beginMonitoring()
            startAlerting()
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

    /// Fixture feed covering every ownership and participant activity kind,
    /// spread from seconds to days old across both preview services.
    private func loadPreviewActivity() {
        let now = Date()
        let build = "build-server"
        let owner: [(String, Double, String, String, String, Int64)] = [
            (previewCluster, -45, "Acquired", "home-mac", "Home Mac", 43),
            (previewCluster, -1_500, "Released", "backup-mac", "Backup Mac", 42),
            (build, -5_400, "Acquired", "build-mac", "Build Mac", 9),
            (previewCluster, -40_000, "Acquired", "backup-mac", "Backup Mac", 42),
            (build, -200_000, "Released", "build-mac", "Build Mac", 8)
        ]
        let events = owner.enumerated().map { index, e in
            WitnessEvent(clusterID: e.0, id: Int64(owner.count - index), time: now.addingTimeInterval(e.1),
                         action: e.2, nodeID: e.3, term: e.5, nodeName: e.4)
        }
        let kinds: [(ParticipantActivityKind, Double, String, String, String, String)] = [
            (.onBattery, -120, "home-mac", "Home Mac", "swiftbot", "Mains power lost; 50% remaining."),
            (.lowBattery, -300, "home-mac", "Home Mac", "swiftbot", "12% remaining, about 4 minutes."),
            (.sessionEnding, -420, "home-mac", "Home Mac", "swiftbot", "Shutdown expected within 2 minutes."),
            (.powerRestored, -900, "home-mac", "Home Mac", "swiftbot", "Mains power is back."),
            (.operationalSynchronizing, -2_000, "backup-mac", "Backup Mac", "swiftbot", "Catching up with the active server."),
            (.operationalOutdated, -2_600, "backup-mac", "Backup Mac", "swiftbot", "Behind by 14 changes."),
            (.operationalDegraded, -3_100, "backup-mac", "Backup Mac", "swiftbot", "Media store is read-only."),
            (.operationalUnavailable, -4_000, "build-mac", "Build Mac", "build-server", "No report for 5 minutes."),
            (.operationalReady, -4_800, "backup-mac", "Backup Mac", "swiftbot", "Synchronised and ready to take over."),
            (.failoverProtectionImpaired, -9_000, "backup-mac", "Backup Mac", "swiftbot", "No ready standby is reporting."),
            (.failoverProtectionRestored, -12_000, "backup-mac", "Backup Mac", "swiftbot", "A ready standby is reporting again.")
        ]
        participantActivity = kinds.enumerated().map { index, k in
            ParticipantActivityRecord(id: Int64(kinds.count - index), clusterID: k.4, nodeID: k.2, nodeName: k.3,
                                      time: now.addingTimeInterval(k.1), kind: k.0.rawValue, detail: k.5)
        }
        if let current = snapshot {
            snapshot = WitnessSnapshot(recoverySeconds: 0, leases: current.leases, events: events,
                                       participantActivity: participantActivity)
        }
    }

    /// Fixture targets covering up, down, flapping, paused and not-yet-checked states.
    private func loadPreviewMonitoring() {
        let now = Date()
        func target(_ n: Int, _ name: String, _ kind: MonitorTarget.Kind, host: String = "", port: Int = 0, url: String = "",
                    interval: Int = 60, enabled: Bool = true) -> MonitorTarget {
            MonitorTarget(id: String(format: "00000000-0000-4000-8000-0000000001%02d", n), name: name, kind: kind,
                          host: host, port: port, url: url, intervalSeconds: interval, failureThreshold: 3, enabled: enabled)
        }
        let targets = [
            target(1, "Home NAS", .tcp, host: "192.168.1.20", port: 445),
            target(2, "Router", .tcp, host: "192.168.1.1", port: 443),
            target(3, "Company website", .http, url: "https://example.com/health"),
            target(4, "Build Mac SSH", .tcp, host: "build-mac.local", port: 22),
            target(5, "Media server", .http, url: "http://192.168.1.30:8096/health"),
            target(6, "Backup server", .tcp, host: "backup-mac.local", port: 22, enabled: false),
            target(7, "New printer", .tcp, host: "192.168.1.44", port: 9100)
        ]
        // (target index, pattern of results oldest → newest; false = failed check)
        let patterns: [Int: [Bool]] = [
            0: Array(repeating: true, count: 60),
            1: (0..<60).map { $0 != 17 && $0 != 18 },
            2: Array(repeating: true, count: 40) + [false, false, false] + Array(repeating: true, count: 17),
            3: Array(repeating: true, count: 50) + Array(repeating: false, count: 10),
            4: Array(repeating: true, count: 54) + Array(repeating: false, count: 6)
        ]
        let details = [false: ["Connection refused", "Timed out", "HTTP 503", "Connection refused", "HTTP 503"]]
        var states: [String: MonitorState] = [:]
        for (index, pattern) in patterns {
            var state = MonitorState()
            for (step, ok) in pattern.enumerated() {
                let time = now.addingTimeInterval(-Double(pattern.count - step) * 60)
                state.record(MonitorResult(time: time, ok: ok, latencyMilliseconds: ok ? 4 + (step * 7) % 38 : nil,
                                           detail: ok ? "OK" : details[false]![index]), failureThreshold: targets[index].failureThreshold)
            }
            states[targets[index].id] = state
        }
        configuration.monitorTargets = targets
        monitorStates = states
        // Demonstrates a custom icon on the preview's media server; read-only, nothing is written.
        if let pick = try? RuruServiceIcons.pick(from: URL(fileURLWithPath: "/System/Applications/Calculator.app")) {
            setServiceIcon(pick.png, for: targets[4].id)
        }
    }

    /// Display-only fixture for the Alerts page: default rules, one customised rule, an
    /// open incident, an incident left unverified by a restart, and delivery history.
    private func loadPreviewAlerts() {
        let now = Date()
        // More than one guarded service, so per-service rules and targets can be tried.
        configuration.services += [
            GuardedService(id: "00000000-0000-4000-8000-000000000002", name: "Media Library", clusterID: "media", kind: .custom),
            GuardedService(id: "00000000-0000-4000-8000-000000000003", name: "Home Automation", clusterID: "home", kind: .custom)
        ]
        var file = AlertRulesFile()
        AlertTemplates.provision(into: &file, capabilities: .init(monitoring: true, guarding: true, internetAccess: true),
                                 legacy: .defaults)
        var rules = file.rules
        if let index = rules.firstIndex(where: { $0.trigger == .monitorUnavailable }) {
            rules[index].notifyOnRecovery = true
            rules[index].cooldownSeconds = 900
        }
        rules.append(AlertRule(name: "NAS latency", trigger: .monitorSlow, scope: AlertScope(ids: [configuration.monitorTargets[0].id]),
                               threshold: .failedChecks(3), limit: 30))
        rules.append(AlertRule(name: "Media Library failover", trigger: .failoverCompleted,
                               scope: AlertScope(ids: ["00000000-0000-4000-8000-000000000002"]), severity: .warning))
        rules.append(AlertRule(name: "Home Automation unreachable", trigger: .primaryUnreachable,
                               scope: AlertScope(ids: ["00000000-0000-4000-8000-000000000003"]), threshold: .after(60),
                               cooldownSeconds: 900, repeatSeconds: 1_800))
        rules.append(AlertRule(name: "Build Mac offline", trigger: .monitorUnavailable,
                               scope: AlertScope(ids: [configuration.monitorTargets[3].id]), threshold: .after(300),
                               repeatSeconds: 1_800, quietHours: QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)))
        let site = SubjectRef(source: .monitoring, kind: "monitor", id: configuration.monitorTargets[3].id, name: "Build Mac SSH")
        let media = SubjectRef(source: .monitoring, kind: "monitor", id: configuration.monitorTargets[4].id, name: "Media server")
        let monitorRule = rules.first { $0.trigger == .monitorUnavailable }!
        let incidents = [
            AlertIncident(ruleID: monitorRule.id, ruleName: monitorRule.name, trigger: .monitorUnavailable, subject: site,
                          severity: .critical, basis: .ruruObserved, title: "Build Mac SSH is unreachable",
                          detail: "build-mac.local:22: Connection refused", openedAt: now.addingTimeInterval(-600),
                          lastNotifiedAt: now.addingTimeInterval(-600), notificationCount: 1, noticeOutstanding: true),
            AlertIncident(ruleID: monitorRule.id, ruleName: monitorRule.name, trigger: .monitorUnavailable, subject: media,
                          severity: .critical, basis: .ruruObserved, verification: .unverified,
                          title: "Media server is unreachable", detail: "http://192.168.1.30:8096/health: HTTP 503",
                          openedAt: now.addingTimeInterval(-7_200), lastNotifiedAt: now.addingTimeInterval(-7_200),
                          notificationCount: 1, noticeOutstanding: true)
        ]
        var history: [AlertHistoryEntry] = []
        func entry(_ id: Int64, _ ago: Double, _ kind: AlertHistoryEntry.Kind, _ title: String, _ subject: String,
                   _ severity: AlertSeverity, deliveries: [DeliveryOutcome] = [], suppressed: String? = nil) {
            history.append(AlertHistoryEntry(id: id, time: now.addingTimeInterval(-ago), ruleID: monitorRule.id, ruleName: monitorRule.name,
                                             trigger: .monitorUnavailable, subjectName: subject, kind: kind, title: title,
                                             detail: "", severity: severity, suppressedReason: suppressed, deliveries: deliveries))
        }
        let ok = DeliveryOutcome(destination: .macOS, ok: true), discord = DeliveryOutcome(destination: .discord, ok: true)
        entry(6, 600, .opened, "Build Mac SSH is unreachable", "Build Mac SSH", .critical, deliveries: [ok, discord])
        entry(5, 3_000, .recovered, "Company website is reachable again", "Company website", .info, deliveries: [ok, discord])
        entry(4, 3_400, .opened, "Company website is unreachable", "Company website", .critical,
              deliveries: [ok, DeliveryOutcome(destination: .discord, ok: false, message: "Discord rejected the alert (HTTP 404)")])
        entry(3, 7_200, .opened, "Media server is unreachable", "Media server", .critical, deliveries: [ok, discord])
        entry(2, 9_000, .opened, "Router is unreachable", "Router", .critical, suppressed: "cooldown")
        var snapshot = AlertSnapshot()
        snapshot.started = true; snapshot.revision = 1
        snapshot.rules = rules; snapshot.openIncidents = incidents; snapshot.history = history.sorted { $0.time > $1.time }
        snapshot.lastTriggered = [monitorRule.id: now.addingTimeInterval(-600)]
        alertSnapshot = snapshot
        alertRulesActive = true
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

    private func loadPreviewUPSBattery() {
        state = .running
        listenerPort = UInt16(configuration.port)
        participantObservations = [
            .init(clusterID: previewCluster, nodeID: "home-mac", nodeName: "Home Mac", role: .active,
                  ageSeconds: 3, fresh: true, powerSource: .ups, externalPower: false,
                  batteryPercent: 50, batteryTimeRemaining: 300),
            .init(clusterID: previewCluster, nodeID: "backup-mac", nodeName: "Backup Mac", role: .standby,
                  ageSeconds: 6, fresh: true, powerSource: .ups, externalPower: true,
                  batteryPercent: 100, batteryTimeRemaining: nil)
        ]
        snapshot = WitnessSnapshot(recoverySeconds: 0,
            leases: [LeaseStatus(clusterID: previewCluster, ownerNodeID: "home-mac", term: 42,
                                  remainingSeconds: 28, ownerNodeName: "Home Mac")],
            events: [WitnessEvent(clusterID: previewCluster, id: 1, time: Date().addingTimeInterval(-300),
                                   action: "Acquired", nodeID: "home-mac", term: 42, nodeName: "Home Mac")])
    }


    // MARK: Monitoring

    var monitorDownCount: Int { configuration.monitorTargets.filter { monitorStates[$0.id]?.status == .down }.count }

    /// Adds a target, or replaces the one with the same ID. Never touches leases or listeners.
    func saveMonitorTarget(_ target: MonitorTarget) async throws {
        guard !busy, !savingConfiguration, !shuttingDown, target.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        if let index = saved.monitorTargets.firstIndex(where: { $0.id == target.id }) { saved.monitorTargets[index] = target }
        else { saved.monitorTargets.append(target) }
        guard saved.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        if !preview { try WitnessStorage.save(saved) }
        configuration = saved
        if !preview { await monitor.configure(saved.monitorTargets) }
    }

    func removeMonitorTarget(id: String) async throws {
        guard !busy, !savingConfiguration, !shuttingDown,
              configuration.monitorTargets.contains(where: { $0.id == id }) else { throw WitnessStorage.ConfigurationError.invalid }
        var saved = configuration
        saved.monitorTargets.removeAll { $0.id == id }
        if !preview { try WitnessStorage.save(saved) }
        configuration = saved
        monitorStates[id] = nil
        setServiceIcon(nil, for: id)
        if !preview { await monitor.configure(saved.monitorTargets) }
    }

    func checkMonitorNow(_ id: String) async {
        guard !preview else { return }
        await monitor.checkNow(id)
        monitorStates = await monitor.snapshot()
    }

    func lease(for clusterID: String) -> LeaseStatus? {
 snapshot?.leases.first { $0.clusterID == clusterID } }
    func service(for clusterID: String) -> GuardedService? { configuration.guardedServices.first { $0.clusterID == clusterID } }
    func serviceName(for clusterID: String) -> String { service(for: clusterID)?.name ?? clusterID }
    func events(for clusterID: String) -> [WitnessEvent] { (snapshot?.events ?? []).filter { $0.clusterID == clusterID } }
    func knownNodes(for clusterID: String) -> [String] {
        var nodes = Set(events(for: clusterID).map(\.nodeID))
        nodes.formUnion(participantObservations.filter { $0.clusterID == clusterID }.map(\.nodeID))
        nodes.formUnion(operationalObservations.filter { $0.clusterID == clusterID }.map(\.nodeID))
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
    func operationalStatus(for nodeID: String, clusterID: String) -> OperationalStatusObservation? {
        operationalObservations.first { $0.clusterID == clusterID && $0.nodeID == nodeID }
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
            let appBundle = Bundle.main
            let authorityVersion = appBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            let authorityBuild = appBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            let server = try WitnessHTTPServer(store: store, services: accessCredentials(), catalogue: catalogue, pairing: pairing,
                                               participants: participants, operationalStatus: operationalStatus,
                                               authorityVersion: authorityVersion, authorityBuild: authorityBuild)
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
        monitoringTask?.cancel()
        legacyDeliveryTask?.cancel()
        await monitor.stop()
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
                           leaseSeconds: Int = GuardedService.defaultLeaseSeconds, iconPNG: Data? = nil) async throws {
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
        if let iconPNG { setServiceIcon(iconPNG, for: service.id) }
    }

    /// Best effort: an icon that cannot be written still shows for this session.
    func setServiceIcon(_ png: Data?, for serviceID: String) {
        if let png, let image = NSImage(data: png) {
            if !preview { try? RuruServiceIcons.save(png, serviceID: serviceID) }
            serviceIcons[serviceID] = image
        } else {
            if !preview { RuruServiceIcons.remove(serviceID: serviceID) }
            serviceIcons[serviceID] = nil
        }
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
        setServiceIcon(nil, for: service.id)
        coordinationLocations.removeAll { $0.clusterID == service.clusterID }
        coordinationEnrollments.removeAll { $0.clusterID == service.clusterID }
        participantObservations.removeAll { $0.clusterID == service.clusterID }
        operationalObservations.removeAll { $0.clusterID == service.clusterID }
        await pairing.revoke(clusterID: service.clusterID)
        if !preview, let access = try? accessCredentials() {
            try await catalogue.configureServices(access)
            try await participants.configureServices(access)
            try await operationalStatus.configureServices(access)
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

    /// Publishes monitor results independently of the authority poll loop.
    private func beginMonitoring() {
        monitoringTask?.cancel()
        monitoringTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshMonitoring()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    private func refreshMonitoring() async {
        guard !preview, !shuttingDown else { return }
        monitorStates = await monitor.snapshot()
        let observations = await monitor.drainObservations()
        let transitions = await monitor.drainTransitions()
        guard alertEngineReady else { return }
        if alertRulesActive, let alertService {
            let now = Date()
            if !observations.isEmpty {
                await alertService.recordMonitoring(observations.map {
                    RollupSample(targetID: $0.targetID, time: $0.result.time, ok: $0.result.ok,
                                 inconclusive: $0.result.inconclusive, latencyMilliseconds: $0.result.latencyMilliseconds)
                })
                await alertService.ingest(observations.flatMap { [RuruAlertSignals.monitor($0, at: now), RuruAlertSignals.monitorLatency($0, at: now)] })
            }
            await alertService.tick()
            let snapshot = await alertService.snapshot()
            if snapshot.revision != alertSnapshot.revision { alertSnapshot = snapshot }
        } else {
            // Earlier fixed-toggle alerts, used only if rules could not be saved.
            var alerts: [RuruAlert] = []
            for transition in transitions where transition.change.status != .unknown {
                let down = transition.change.status == .down
                alerts.append(RuruAlert(kind: down ? .monitorDown : .monitorRecovered,
                                        key: "monitor|\(transition.targetID)|\(down ? "down" : "up")",
                                        title: down ? "\(transition.name) is unreachable" : "\(transition.name) is reachable again",
                                        detail: down ? "\(transition.address): \(transition.change.detail)" : transition.address,
                                        context: .init(service: "Monitoring")))
            }
            enqueueLegacyDelivery(alerts)
        }
    }

    // MARK: Alert engine

    private var alertCapabilities: AlertCapabilities {
        AlertCapabilities(monitoring: !configuration.monitorTargets.isEmpty, guarding: !configuration.services.isEmpty,
                          internetAccess: configuration.tunnel.isConfigured)
    }

    private var legacyAlertPreferences: LegacyAlertPreferences {
        let alerts = configuration.alerts
        return LegacyAlertPreferences([.serviceDown: alerts.serviceDown, .failover: alerts.failover,
                                       .authorityProblems: alerts.authorityProblems, .participantStatus: alerts.participantStatus,
                                       .operationalStatus: alerts.operationalStatus, .monitoring: alerts.monitoring])
    }

    /// Destinations that are set up and switched on in Settings.
    var enabledAlertDestinations: Set<AlertDestination> {
        var destinations: Set<AlertDestination> = []
        if configuration.alerts.notifications { destinations.insert(.macOS) }
        if configuration.alerts.discord, discordConfigured { destinations.insert(.discord) }
        if configuration.alerts.notify, notifyConfigured { destinations.insert(.notify) }
        return destinations
    }

    private func startAlerting() {
        let directory = WitnessStorage.directory
        let delivery = alertDelivery
        let service = AlertService(.init(
            rulesURL: directory.appendingPathComponent("alert-rules.json"),
            databaseURL: directory.appendingPathComponent("Alerts", isDirectory: true).appendingPathComponent("alerts.duckdb"),
            transport: RuruAlertTransport(delivery: delivery, credentials: { [weak self] in
                RuruAlertDelivery.Credentials(webhook: self?.discordWebhook, notifyID: self?.configuration.notifyID ?? "",
                                              notifyToken: self?.notifyToken)
            }),
            enabledDestinations: { [weak self] in await MainActor.run { self?.enabledAlertDestinations ?? [] } }))
        alertService = service
        let capabilities = alertCapabilities, legacy = legacyAlertPreferences
        let monitors = Set(configuration.monitorTargets.filter(\.enabled).map(\.id))
        let allMonitors = Set(configuration.monitorTargets.map(\.id))
        let services = Set(configuration.services.map(\.id))
        Task { [weak self] in
            let report = await service.start(capabilities: capabilities, legacy: legacy)
            guard let self, !self.shuttingDown else { return }
            self.alertRulesActive = report.rulesActive
            self.lastAlertSync = AlertSync(capabilities: capabilities, monitors: monitors, allMonitors: allMonitors, services: services)
            if report.rulesActive {
                await service.pruneSubjects(source: .monitoring, kind: "monitor", keeping: monitors)
                await service.forgetMonitoringHistory(keeping: allMonitors)
                await service.pruneSubjects(source: .guarding, kind: "service", keeping: services)
                await service.pruneGroups(source: .operationalStatus, keeping: services)
            }
            self.alertSnapshot = await service.snapshot()
            self.alertEngineReady = true
            if report.rulesActive, self.store != nil, capabilities.guarding {
                await service.ingest([AlertSignal(
                    trigger: .authorityRestarted, subject: RuruAlertSubjects.authority, shape: .event,
                    title: "Ruru restarted", detail: "Ruru started and is waiting out any earlier leases before granting ownership.",
                    basis: .ruruObserved, observedAt: Date())])
            }
        }
    }

    /// Keeps default rules and open incidents in step with what is configured: a
    /// newly added capability gets its default rules, and a removed or paused
    /// monitor or service has its open incidents archived (not "recovered").
    private func alertingInputsChanged() {
        guard alertEngineReady, alertRulesActive, !preview, let service = alertService else { return }
        let sync = AlertSync(capabilities: alertCapabilities,
                             monitors: Set(configuration.monitorTargets.filter(\.enabled).map(\.id)),
                             allMonitors: Set(configuration.monitorTargets.map(\.id)),
                             services: Set(configuration.services.map(\.id)))
        guard sync != lastAlertSync else { return }
        lastAlertSync = sync
        let legacy = legacyAlertPreferences
        Task { [weak self] in
            await service.provision(capabilities: sync.capabilities, legacy: legacy)
            await service.pruneSubjects(source: .monitoring, kind: "monitor", keeping: sync.monitors)
            await service.forgetMonitoringHistory(keeping: sync.allMonitors)
            await service.pruneSubjects(source: .guarding, kind: "service", keeping: sync.services)
            await service.pruneGroups(source: .operationalStatus, keeping: sync.services)
            if let self { self.alertSnapshot = await service.snapshot() }
        }
    }

    // MARK: Alert rules (used by the Alerts page)

    func saveAlertRule(_ rule: AlertRule) async throws -> AlertRule {
        guard let alertService else { throw AlertServiceError.notStarted }
        let saved = try await alertService.saveRule(rule)
        alertSnapshot = await alertService.snapshot()
        return saved
    }

    func deleteAlertRule(_ id: UUID) async throws {
        guard let alertService else { throw AlertServiceError.notStarted }
        try await alertService.deleteRule(id)
        alertSnapshot = await alertService.snapshot()
    }

    func setAlertRule(_ id: UUID, enabled: Bool) async throws {
        guard let alertService else { throw AlertServiceError.notStarted }
        try await alertService.setRuleEnabled(id, enabled)
        alertSnapshot = await alertService.snapshot()
    }

    func addAlertRule(fromTemplate id: String) async throws -> AlertRule {
        guard let alertService else { throw AlertServiceError.notStarted }
        let rule = try await alertService.addRule(fromTemplate: id)
        alertSnapshot = await alertService.snapshot()
        return rule
    }

    func duplicateAlertRule(_ id: UUID) async throws -> AlertRule {
        guard let alertService else { throw AlertServiceError.notStarted }
        let rule = try await alertService.duplicateRule(id)
        alertSnapshot = await alertService.snapshot()
        return rule
    }

    func alertHistory(ruleID: UUID?) async -> [AlertHistoryEntry] {
        await alertService?.history(ruleID: ruleID, limit: 100) ?? []
    }

    func alertIncidents(subjectKey: String?) async -> [AlertIncident] {
        await alertService?.incidents(subjectKey: subjectKey, limit: 25) ?? []
    }

    func monitorUptime(_ targetID: String) async -> [(label: String, summary: UptimeSummary)] {
        await alertService?.uptime(targetID: targetID) ?? []
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
        operationalObservations = await operationalStatus.snapshot().filter { observation in
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
            participantActivity = snapshot?.participantActivity ?? []
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
        enum Tier: String { case authority = "Authority", guarding = "Guarding", transport = "Transport", monitoring = "Monitoring", alerts = "Alerts" }
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
        // Someone who only monitors never configured Guarding; its prompts would be noise.
        let monitoringOnly = configuration.services.isEmpty && !configuration.monitorTargets.isEmpty
        if state == .stopped, !legacyStorageNeedsReplacement, !monitoringOnly {
            items.append(.init(id: "stopped", tier: .authority, title: "Ruru is stopped",
                               detail: "Servers can’t take or keep ownership until it runs.",
                               health: .warning, actionTitle: "Start", action: .start))
        }

        // Transport tier
        if !configuration.tunnel.isConfigured, !configuration.setup.localOnly, !monitoringOnly {
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
        if configuration.services.isEmpty, !monitoringOnly {
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

        // Alerts tier — incidents Ruru can't currently show as healthy
        let open = alertSnapshot.openIncidents
        if !open.isEmpty {
            let unverified = open.filter { $0.verification == .unverified }.count
            let verified = open.count - unverified
            items.append(.init(id: "alerts", tier: .alerts,
                               title: open.count == 1 ? "1 open alert" : "\(open.count) open alerts",
                               detail: unverified == 0 ? open.prefix(3).map(\.title).joined(separator: " · ")
                                   : (verified == 0 ? "Ruru restarted and hasn't observed \(unverified == 1 ? "this" : "these") since. Not shown as healthy."
                                      : "\(verified) active, \(unverified) unverified since Ruru restarted."),
                               health: verified > 0 ? .error : .warning, actionTitle: "Alerts", action: .page(.alerts)))
        }

        // Monitoring tier — confirmed-down targets only
        let down = configuration.monitorTargets.filter { monitorStates[$0.id]?.status == .down }
        if !down.isEmpty {
            items.append(.init(id: "monitoring", tier: .monitoring,
                               title: down.count == 1 ? "\(down[0].name) is unreachable" : "\(down.count) monitored targets are unreachable",
                               detail: down.count == 1 ? (monitorStates[down[0].id]?.last?.detail ?? "Checks are failing.") : down.map(\.name).joined(separator: ", "),
                               health: .error, actionTitle: "Monitoring", action: .page(.monitoring)))
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
        guard !preview, !shuttingDown, alertEngineReady else { return }
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
        let now = Date()
        var alerts = alertMonitor.observe(observation, at: now)
        let participantTransitions = participantAlertMonitor.observe(
            participantObservations,
            serviceNames: Dictionary(configuration.guardedServices.map { ($0.clusterID, $0.name) },
                                     uniquingKeysWith: { first, _ in first }),
            at: now)
        alerts.append(contentsOf: participantTransitions.alerts)
        let operationalTransitions = operationalAlertMonitor.observe(
            operationalObservations, participants: participantObservations,
            owners: Set(leases.filter { $0.remainingSeconds > 0 && !$0.ownerNodeID.isEmpty }.map(\.clusterID)),
            serviceNames: Dictionary(configuration.guardedServices.map { ($0.clusterID, $0.name) },
                                     uniquingKeysWith: { first, _ in first }),
            at: now)
        alerts.append(contentsOf: operationalTransitions.alerts)
        for transition in participantTransitions.events + operationalTransitions.events {
            guard let store else { continue }
            do {
                let record = try await store.recordParticipantActivity(
                    clusterID: transition.clusterID, nodeID: transition.nodeID,
                    nodeName: transition.nodeName, kind: transition.kind.rawValue,
                    detail: transition.detail, at: transition.date)
                participantActivity.insert(record, at: 0)
                participantActivity = Array(participantActivity.prefix(128))
            } catch {
                alertDeliveryError = "Operational activity could not be saved to DuckDB."
            }
        }
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
        guard alertRulesActive, let alertService else {
            enqueueLegacyDelivery(alerts)
            return
        }
        // Rules decide what is notified. The detectors above stay as they were: they
        // are read for their current conditions and events, never for delivery. Only
        // Ruru's own built-in notices (pairing requests) bypass the rules.
        let subjects = RuruAlertSubjects(services: configuration.guardedServices)
        var signals = alertMonitor.conditionSignals(subjects: subjects, at: now)
        signals += operationalAlertMonitor.conditionSignals(subjects: subjects, at: now)
        signals += participantAlertMonitor.conditionSignals(subjects: subjects, at: now)
        signals += alerts.compactMap { RuruAlertSignals.failover($0, subjects: subjects, at: now) }
        signals += RuruAlertSignals.participantEvents(participantTransitions.events, subjects: subjects, at: now)
        signals += RuruAlertSignals.ownership(
            ownershipTransferMonitor.observe(owners: observation.owners, serving: alertMonitor.serving,
                                             services: Set(subjects.services.keys)), subjects: subjects, at: now)
        await alertService.ingest(signals)
        enqueueLegacyDelivery(alerts.filter { $0.kind == .pairingRequest })
    }

    /// Hands alerts to a serial delivery task and returns immediately.
    private func enqueueLegacyDelivery(_ alerts: [RuruAlert]) {
        guard !alerts.isEmpty else { return }
        pendingLegacyAlerts.append(contentsOf: alerts)
        if pendingLegacyAlerts.count > 64 { pendingLegacyAlerts.removeFirst(pendingLegacyAlerts.count - 64) }
        guard legacyDeliveryTask == nil else { return }
        legacyDeliveryTask = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pendingLegacyAlerts.isEmpty {
                let batch = self.pendingLegacyAlerts
                self.pendingLegacyAlerts = []
                if let failure = await self.alertDelivery.deliver(
                    batch, preferences: self.configuration.alerts, webhook: self.discordWebhook,
                    notifyID: self.configuration.notifyID, notifyToken: self.notifyToken) {
                    self.alertDeliveryError = failure
                }
            }
            self?.legacyDeliveryTask = nil
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

    /// Verifies the Notify! destination before storing its token in Keychain.
    func setNotifyDestination(id: String, token: String) async throws {
        guard !preview else { throw WitnessStorage.ConfigurationError.invalid }
        guard let identifier = RuruNotify.validID(id), let secret = RuruNotify.validToken(token) else {
            throw RuruBackup.Failure("Enter a valid Notify! device/group ID and token.")
        }
        try await RuruNotify.validate(id: identifier, token: secret)
        try WitnessKeychain.save(secret, account: RuruNotify.keychainAccount)
        notifyToken = secret
        notifyConfigured = true
        alertDeliveryError = nil
        var draft = configuration
        draft.notifyID = identifier
        draft.alerts.notify = true
        try await saveConfiguration(draft)
    }

    func removeNotifyDestination() async throws {
        guard !preview else { return }
        try WitnessKeychain.delete(RuruNotify.keychainAccount)
        notifyToken = nil
        notifyConfigured = false
        alertDeliveryError = nil
        var draft = configuration
        draft.notifyID = ""
        draft.alerts.notify = false
        try await saveConfiguration(draft)
    }

    /// Sends one test alert to every configured destination.
    func sendTestAlert() async {
        guard !preview else { return }
        let alert = RuruAlert(kind: .test, key: "test", title: "Ruru alerts are working",
                              detail: "You'll be told here when a service goes down or fails over.")
        var preferences = configuration.alerts
        preferences.discord = discordWebhook != nil
        preferences.notify = notifyConfigured
        alertDeliveryError = await alertDelivery.deliver([alert], preferences: preferences, webhook: discordWebhook,
                                                        notifyID: configuration.notifyID, notifyToken: notifyToken)
    }
}
