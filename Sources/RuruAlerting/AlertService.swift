import Foundation

public struct AlertSnapshot: Sendable, Equatable {
    public var revision = 0
    public var started = false
    public var rules: [AlertRule] = []
    public var openIncidents: [AlertIncident] = []
    public var history: [AlertHistoryEntry] = []
    public var lastTriggered: [UUID: Date] = [:]
    public var storage: AlertStorageStatus = .ready
    /// A message to show when rules or storage needed recovery at launch.
    public var notice: String?
    /// The most recent destination failure that no later success has cleared.
    public var deliveryProblems: [AlertDestination: String] = [:]
    public var pendingDeliveries = 0

    public init() {}
    public func rule(_ id: UUID) -> AlertRule? { rules.first { $0.id == id } }
}

public struct AlertStartReport: Sendable, Equatable {
    /// False only if rules could not be saved at all; the app then keeps its older alerting.
    public var rulesActive: Bool
    public var notice: String?
    public var storage: AlertStorageStatus
    public var provisioned: [String]
}

public enum AlertServiceError: LocalizedError {
    case invalid(String), notFound, tooManyRules, persistence, notStarted
    public var errorDescription: String? {
        switch self {
        case .invalid(let message): message
        case .notFound: "That rule no longer exists."
        case .tooManyRules: "Ruru supports up to \(AlertRule.maxRules) alert rules."
        case .persistence: "Ruru couldn't save the alert rules. Check storage access and free space."
        case .notStarted: "Alerts are still starting."
        }
    }
}

/// Owns alert rules, incidents and delivery. Everything here runs on its own actor
/// and its own storage; producers hand it signals and never wait on its I/O.
public actor AlertService {
    public struct Configuration: Sendable {
        public var rulesURL: URL
        public var databaseURL: URL
        public var transport: any AlertTransport
        /// Destinations currently set up and switched on in Settings.
        public var enabledDestinations: @Sendable () async -> Set<AlertDestination>
        public var clock: @Sendable () -> Date
        public var policy: AlertEngineCore.Policy
        public var retryDelay: Duration

        public init(rulesURL: URL, databaseURL: URL, transport: any AlertTransport,
                    enabledDestinations: @escaping @Sendable () async -> Set<AlertDestination>,
                    clock: @escaping @Sendable () -> Date = { Date() },
                    policy: AlertEngineCore.Policy = .init(), retryDelay: Duration = .seconds(10)) {
            self.rulesURL = rulesURL; self.databaseURL = databaseURL; self.transport = transport
            self.enabledDestinations = enabledDestinations; self.clock = clock; self.policy = policy
            self.retryDelay = retryDelay
        }
    }

    static let historyMirror = 200
    static let rollupFlushInterval: TimeInterval = 30
    static let pruneInterval: TimeInterval = 3_600

    private let configuration: Configuration
    private var core: AlertEngineCore
    private var file = AlertRulesFile()
    private var store: AlertStore?
    private var dispatcher: AlertDispatcher?
    private var started = false
    private var rulesActive = false
    private var revision = 0
    private var history: [AlertHistoryEntry] = []
    private var lastTriggered: [UUID: Date] = [:]
    private var storage: AlertStorageStatus = .ready
    private var notice: String?
    private var deliveryProblems: [AlertDestination: String] = [:]
    private var localEntryID: Int64 = 0
    private var storeFailures = 0
    private var degradedByFailures = false
    private var pendingSamples: [RollupSample] = []
    private var lastRollupFlush: Date
    private var lastPrune: Date
    private var lastTick: Date = .distantPast

    public init(_ configuration: Configuration) {
        self.configuration = configuration
        core = AlertEngineCore(policy: configuration.policy)
        lastRollupFlush = configuration.clock()
        lastPrune = configuration.clock()
    }

    // MARK: Start

    public func start(capabilities: AlertCapabilities, legacy: LegacyAlertPreferences) async -> AlertStartReport {
        let now = configuration.clock()
        var problems: [String] = []
        switch AlertRuleStorage.load(from: configuration.rulesURL) {
        case .missing: file = AlertRulesFile()
        case .loaded(let loaded): file = loaded
        case .damaged:
            let moved = AlertRuleStorage.setAside(configuration.rulesURL, now: now)
            file = AlertRulesFile()
            problems.append(moved.map { "Your alert rules file couldn't be read. It was kept as \($0) and Ruru's default rules were restored." }
                            ?? "Your alert rules file couldn't be read.")
        }
        let added = AlertTemplates.provision(into: &file, capabilities: capabilities, legacy: legacy)
        do { try AlertRuleStorage.save(file, to: configuration.rulesURL); rulesActive = true }
        catch { rulesActive = false }
        guard rulesActive else {
            storage = .unavailable("Alert rules can't be saved.")
            started = true; revision += 1
            return AlertStartReport(rulesActive: false, notice: "Ruru couldn't save alert rules, so it is using its earlier alert settings.",
                                    storage: storage, provisioned: [])
        }

        let opened = AlertStore.open(at: configuration.databaseURL, now: now)
        store = opened.store; storage = opened.status
        if case .recovered(let moved) = opened.status {
            problems.append("Alert history was damaged and has been set aside as \(moved). Ruru started a new history.")
        } else if case .unavailable(let reason) = opened.status {
            problems.append("\(reason) Alerts still work, but incidents and history won't be kept until this is fixed.")
        }

        var restored: [AlertIncident] = [], evidence: [EvidenceRecord] = []
        if let store {
            do {
                restored = try await store.openIncidents()
                restored += try await store.resolvedIncidents(since: now.addingTimeInterval(-configuration.policy.reopenWindow))
                evidence = try await store.evidence()
                history = try await store.history(limit: Self.historyMirror)
                for entry in try await store.history(limit: 1_000) where [.opened, .event, .flapping].contains(entry.kind) {
                    lastTriggered[entry.ruleID] = max(lastTriggered[entry.ruleID] ?? .distantPast, entry.time)
                }
            } catch { await noteStoreFailure() }
        }

        dispatcher = AlertDispatcher(transport: configuration.transport, retryDelay: configuration.retryDelay) { [weak self] note, outcome in
            await self?.recordDelivery(note, outcome)
        }
        var effects = core.setRules(file.rules, now: now)
        effects += core.restore(incidents: restored, evidence: evidence, now: now)
        await apply(effects)
        started = true
        notice = problems.isEmpty ? nil : problems.joined(separator: " ")
        revision += 1
        return AlertStartReport(rulesActive: true, notice: notice, storage: storage, provisioned: added.map(\.name))
    }

    public func shutdown() async {
        await flushRollups(force: true)
        await dispatcher?.shutdown()
    }

    // MARK: Signals

    public func ingest(_ signals: [AlertSignal]) async {
        guard started, rulesActive else { return }
        let now = configuration.clock()
        var effects: [AlertEngineCore.Effect] = []
        for signal in signals { effects += core.ingest(signal, now: now) }
        await apply(effects)
    }

    /// Time-driven work. Safe to call often; it runs at most once a second.
    public func tick() async {
        guard started, rulesActive else { return }
        let now = configuration.clock()
        guard now.timeIntervalSince(lastTick) >= 1 || now < lastTick else { return }
        lastTick = now
        await apply(core.tick(now: now))
        await flushRollups(force: false)
        if now.timeIntervalSince(lastPrune) >= Self.pruneInterval {
            lastPrune = now
            if let store { do { try await store.prune(now: now) } catch { await noteStoreFailure() } }
        }
    }

    /// Archives open incidents for subjects that no longer exist or are paused.
    public func pruneSubjects(source: AlertSource, kind: String, keeping ids: Set<String>) async {
        guard started, rulesActive else { return }
        await apply(core.removeSubjects(source: source, kind: kind, keeping: ids, now: configuration.clock()))
    }

    /// Discards availability history for monitors that no longer exist. A paused
    /// monitor keeps its history, so this takes every configured ID.
    public func forgetMonitoringHistory(keeping ids: Set<String>) async {
        guard started, let store else { return }
        try? await store.removeRollups(keeping: ids)
    }

    /// Archives open incidents for services (or other groups) that were removed.
    public func pruneGroups(source: AlertSource, keeping ids: Set<String>) async {
        guard started, rulesActive else { return }
        await apply(core.removeGroups(source: source, keeping: ids, now: configuration.clock()))
    }

    public func recordMonitoring(_ samples: [RollupSample]) {
        guard started else { return }
        pendingSamples.append(contentsOf: samples)
        if pendingSamples.count > 2_000 { pendingSamples.removeFirst(pendingSamples.count - 2_000) }
    }

    // MARK: Rules

    public func saveRule(_ rule: AlertRule) async throws -> AlertRule {
        guard started, rulesActive else { throw AlertServiceError.notStarted }
        let normalized = rule.normalized()
        if let problem = normalized.validationProblem { throw AlertServiceError.invalid(problem) }
        var next = file
        if let index = next.rules.firstIndex(where: { $0.id == normalized.id }) { next.rules[index] = normalized }
        else {
            guard next.rules.count < AlertRule.maxRules else { throw AlertServiceError.tooManyRules }
            next.rules.append(normalized)
        }
        try await commit(next)
        return normalized
    }

    public func deleteRule(_ id: UUID) async throws {
        guard started, rulesActive else { throw AlertServiceError.notStarted }
        guard file.rules.contains(where: { $0.id == id }) else { throw AlertServiceError.notFound }
        var next = file
        next.rules.removeAll { $0.id == id }
        try await commit(next)
    }

    public func setRuleEnabled(_ id: UUID, _ enabled: Bool) async throws {
        guard var rule = file.rules.first(where: { $0.id == id }) else { throw AlertServiceError.notFound }
        rule.enabled = enabled
        _ = try await saveRule(rule)
    }

    /// The saved rules and which defaults were provisioned, for backups.
    public func rulesFile() -> AlertRulesFile { file }

    /// Replaces the rules with those from a backup. The record of provisioned defaults
    /// comes with them, so defaults the user deleted are not created again.
    public func restoreRules(_ restored: AlertRulesFile) async throws {
        guard started, rulesActive else { throw AlertServiceError.notStarted }
        var next = AlertRulesFile()
        next.rules = Array(restored.rules.prefix(AlertRule.maxRules)).map { $0.normalized() }
        next.provisioned = restored.provisioned
        try await commit(next)
    }

    /// Creates a rule from a template, even one that already exists.
    public func addRule(fromTemplate id: String) async throws -> AlertRule {
        guard let template = AlertTemplates.template(id) else { throw AlertServiceError.notFound }
        var rule = template.makeRule(enabled: true)
        rule.templateID = nil; rule.templateVersion = nil   // a user-created copy, not the provisioned default
        if file.rules.contains(where: { $0.name == rule.name }) { rule.name += " (copy)" }
        return try await saveRule(rule)
    }

    public func duplicateRule(_ id: UUID) async throws -> AlertRule {
        guard var rule = file.rules.first(where: { $0.id == id }) else { throw AlertServiceError.notFound }
        rule.id = UUID(); rule.name += " (copy)"; rule.templateID = nil; rule.templateVersion = nil
        return try await saveRule(rule)
    }

    /// Adds default rules for newly configured capabilities, such as the first guarded service.
    @discardableResult
    public func provision(capabilities: AlertCapabilities, legacy: LegacyAlertPreferences) async -> [AlertRule] {
        guard started, rulesActive else { return [] }
        var next = file
        let added = AlertTemplates.provision(into: &next, capabilities: capabilities, legacy: legacy)
        guard next != file else { return [] }
        do { try await commit(next) } catch { return [] }
        return added
    }

    private func commit(_ next: AlertRulesFile) async throws {
        do { try AlertRuleStorage.save(next, to: configuration.rulesURL) } catch { throw AlertServiceError.persistence }
        file = next
        await apply(core.setRules(file.rules, now: configuration.clock()))
        revision += 1
    }

    // MARK: Queries

    public func snapshot() -> AlertSnapshot {
        var snapshot = AlertSnapshot()
        snapshot.revision = revision; snapshot.started = started; snapshot.rules = file.rules
        snapshot.openIncidents = core.openIncidents; snapshot.history = history; snapshot.lastTriggered = lastTriggered
        snapshot.storage = storage; snapshot.notice = notice; snapshot.deliveryProblems = deliveryProblems
        return snapshot
    }

    public func history(ruleID: UUID?, limit: Int = 100) async -> [AlertHistoryEntry] {
        if let store, let rows = try? await store.history(limit: limit, ruleID: ruleID) { return rows }
        return Array(history.filter { ruleID == nil || $0.ruleID == ruleID }.prefix(limit))
    }

    public func incidents(subjectKey: String? = nil, ruleID: UUID? = nil, limit: Int = 25) async -> [AlertIncident] {
        guard let store, let rows = try? await store.incidents(subjectKey: subjectKey, ruleID: ruleID, limit: limit) else {
            return core.openIncidents.filter { (subjectKey == nil || $0.subject.key == subjectKey) && (ruleID == nil || $0.ruleID == ruleID) }
        }
        // Prefer the live copy of an open incident, which may be newer than the stored one.
        let live = Dictionary(uniqueKeysWithValues: core.openIncidents.map { ($0.id, $0) })
        return rows.map { live[$0.id] ?? $0 }
    }

    public func uptime(targetID: String) async -> [(label: String, summary: UptimeSummary)] {
        await flushRollups(force: true)
        let now = configuration.clock()
        guard let store else { return [] }
        let windows: [(String, TimeInterval)] = [("24 hours", 86_400), ("7 days", 7 * 86_400), ("30 days", 30 * 86_400)]
        var result: [(String, UptimeSummary)] = []
        for (label, window) in windows {
            result.append((label, (try? await store.uptime(targetID: targetID, window: window, now: now)) ?? .empty))
        }
        return result
    }

    // MARK: Effects

    private func apply(_ effects: [AlertEngineCore.Effect]) async {
        guard !effects.isEmpty else { return }
        for effect in effects {
            switch effect {
            case .incident(let incident):
                if let store { do { try await store.save(incident); noteStoreSuccess() } catch { await noteStoreFailure() } }
                revision += 1
            case .evidence(let record):
                if let store { do { try await store.save(record) } catch { await noteStoreFailure() } }
            case .clearEvidence(let rule, let key):
                if let store { do { try await store.clearEvidence(ruleID: rule, subjectKey: key) } catch { await noteStoreFailure() } }
            case .history(let entry, let notification):
                let stored = await persist(entry)
                history.insert(stored, at: 0)
                if history.count > Self.historyMirror { history.removeLast(history.count - Self.historyMirror) }
                if [.opened, .event, .flapping].contains(stored.kind) {
                    lastTriggered[stored.ruleID] = max(lastTriggered[stored.ruleID] ?? .distantPast, stored.time)
                }
                revision += 1
                if var notification { notification.entryID = stored.id; await dispatch(notification) }
            }
        }
    }

    private func persist(_ entry: AlertHistoryEntry) async -> AlertHistoryEntry {
        if let store {
            do { let stored = try await store.append(entry); noteStoreSuccess(); return stored }
            catch { await noteStoreFailure() }
        }
        localEntryID -= 1       // negative IDs mark entries that were never saved
        var local = entry; local.id = localEntryID
        return local
    }

    private func dispatch(_ notification: OutgoingNotification) async {
        let enabled = await configuration.enabledDestinations()
        let choice = notification.choice
        let targets = choice.useAllEnabled ? enabled : choice.destinations.intersection(enabled)
        for destination in choice.useAllEnabled ? [] : choice.destinations.subtracting(enabled).sorted(by: { $0.rawValue < $1.rawValue }) {
            await recordDelivery(notification, DeliveryOutcome(destination: destination, ok: false,
                message: "\(destination.title) isn't set up or is turned off in Settings.", time: configuration.clock()))
        }
        await dispatcher?.enqueue(notification, to: targets.sorted { $0.rawValue < $1.rawValue })
    }

    private func recordDelivery(_ notification: OutgoingNotification, _ outcome: DeliveryOutcome) async {
        if outcome.ok { deliveryProblems[outcome.destination] = nil }
        else { deliveryProblems[outcome.destination] = outcome.message ?? "Delivery failed." }
        if let index = history.firstIndex(where: { $0.id == notification.entryID }) {
            history[index].deliveries.removeAll { $0.destination == outcome.destination }
            history[index].deliveries.append(outcome)
            if let store, notification.entryID > 0 {
                do { try await store.setDeliveries(entryID: notification.entryID, history[index].deliveries) }
                catch { await noteStoreFailure() }
            }
        }
        revision += 1
    }

    private func flushRollups(force: Bool) async {
        let now = configuration.clock()
        guard !pendingSamples.isEmpty, force || now.timeIntervalSince(lastRollupFlush) >= Self.rollupFlushInterval else { return }
        lastRollupFlush = now
        guard let store else { pendingSamples = []; return }
        let batch = pendingSamples
        do { try await store.record(batch); pendingSamples.removeAll(keepingCapacity: true); noteStoreSuccess() }
        catch { await noteStoreFailure() }
    }

    private func noteStoreSuccess() {
        storeFailures = 0
        if degradedByFailures { degradedByFailures = false; storage = .ready; notice = nil; revision += 1 }
    }

    /// A single failed write is tolerated; repeated failures show as a visible warning.
    private func noteStoreFailure() async {
        storeFailures += 1
        if storeFailures >= 3, storage.isUsable {
            degradedByFailures = true
            storage = .unavailable("Alert history couldn't be saved.")
            notice = "Alert history couldn't be saved. Alerts still work, but incidents and history may be lost on restart."
            revision += 1
        }
    }
}
