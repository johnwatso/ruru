import Foundation
import RuruAlerting
import WitnessKit

/// Which problems Ruru reports, and where. The Discord webhook URL itself is a
/// secret and lives in Keychain; only whether to use it is stored here.
struct RuruAlertPreferences: Codable, Equatable {
    var notifications = true
    var discord = false
    var notify = false
    var serviceDown = true
    var failover = true
    var authorityProblems = true
    var participantStatus = false
    var operationalStatus = true
    var monitoring = true

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? defaults.notifications
        discord = try values.decodeIfPresent(Bool.self, forKey: .discord) ?? defaults.discord
        notify = try values.decodeIfPresent(Bool.self, forKey: .notify) ?? defaults.notify
        serviceDown = try values.decodeIfPresent(Bool.self, forKey: .serviceDown) ?? defaults.serviceDown
        failover = try values.decodeIfPresent(Bool.self, forKey: .failover) ?? defaults.failover
        authorityProblems = try values.decodeIfPresent(Bool.self, forKey: .authorityProblems) ?? defaults.authorityProblems
        participantStatus = try values.decodeIfPresent(Bool.self, forKey: .participantStatus) ?? defaults.participantStatus
        operationalStatus = try values.decodeIfPresent(Bool.self, forKey: .operationalStatus) ?? defaults.operationalStatus
        monitoring = try values.decodeIfPresent(Bool.self, forKey: .monitoring) ?? defaults.monitoring
    }
}

/// Notify! push API. The endpoint is fixed to the official service; tokens are
/// never persisted in configuration or included in errors/logs.
enum RuruNotify {
    static let keychainAccount = "notify-token"
    private static let baseURL = URL(string: "https://push.getnotifyapp.com")!

    static func validID(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...32).contains(value.utf8.count),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return value
    }

    static func validToken(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...256).contains(value.utf8.count),
              value.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return value
    }

    static func validate(id: String, token: String, using session: URLSession = .shared) async throws {
        guard let identifier = validID(id), let secret = validToken(token),
              var components = URLComponents(url: baseURL.appendingPathComponent("link"), resolvingAgainstBaseURL: false) else {
            throw RuruBackup.Failure("Enter a valid Notify! device or group ID and token.")
        }
        components.queryItems = [URLQueryItem(name: "id", value: identifier), URLQueryItem(name: "token", value: secret)]
        guard let url = components.url else { throw RuruBackup.Failure("Notify! setup could not be validated.") }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              body["success"] as? Bool == true else {
            throw RuruBackup.Failure("Notify! could not verify that ID and token. Check them and try again.")
        }
    }

    static func payload(for alert: RuruAlert) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "title": String(alert.title.prefix(256)),
            "text": String(alert.detail.prefix(4_000)),
            "groupType": "ruru"
        ], options: [.sortedKeys])
    }

    static func request(for alert: RuruAlert, id: String, token: String) throws -> URLRequest {
        guard let identifier = validID(id), let secret = validToken(token),
              var components = URLComponents(url: baseURL.appendingPathComponent("notify-json").appendingPathComponent(identifier),
                                             resolvingAgainstBaseURL: false) else {
            throw RuruBackup.Failure("Notify! is not configured with a valid ID and token.")
        }
        components.queryItems = [URLQueryItem(name: "token", value: secret)]
        guard let url = components.url else { throw RuruBackup.Failure("Notify! could not prepare the alert.") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Ruru", forHTTPHeaderField: "User-Agent")
        request.httpBody = try payload(for: alert)
        return request
    }
}

struct RuruAlert: Equatable {
    enum Kind: Equatable {
        case serviceDown, serviceRecovered, failover, authorityProblem, authorityRecovered
        case participantOnBattery, participantLowBattery, participantPowerRestored, participantSessionEnding
        case pairingRequest, test
        case monitorDown, monitorRecovered
        case operationalDegraded, operationalRecovered, failoverProtectionImpaired, failoverProtectionRestored
        /// Sent by an alert rule; its severity and footer come from the rule.
        case rule
    }
    enum Severity: Equatable { case critical, warning, resolved, info }

    /// Display names only; never include credentials or internal alert keys.
    struct Context: Equatable {
        let service: String
        var previousOwner: String? = nil
        var currentOwner: String? = nil
        var server: String? = nil
        var webUIURL: String? = nil
    }

    let kind: Kind
    let key: String
    let title: String
    let detail: String
    var context: Context? = nil
    /// Set for rule notifications, which carry their own severity and evidence label.
    var severityOverride: Severity? = nil
    var basisLabel: String? = nil

    var severity: Severity {
        if let severityOverride { return severityOverride }
        return switch kind {
        case .serviceDown, .authorityProblem, .participantLowBattery, .failoverProtectionImpaired, .monitorDown: .critical
        case .failover, .participantOnBattery, .participantSessionEnding, .operationalDegraded: .warning
        case .participantPowerRestored, .operationalRecovered, .failoverProtectionRestored: .resolved
        case .serviceRecovered, .authorityRecovered, .monitorRecovered: .resolved
        case .pairingRequest, .test, .rule: .info
        }
    }

    func isEnabled(in preferences: RuruAlertPreferences) -> Bool {
        switch kind {
        case .serviceDown, .serviceRecovered: preferences.serviceDown
        case .failover: preferences.failover
        case .authorityProblem, .authorityRecovered: preferences.authorityProblems
        case .participantOnBattery, .participantLowBattery, .participantPowerRestored, .participantSessionEnding:
            preferences.participantStatus
        case .operationalDegraded, .operationalRecovered, .failoverProtectionImpaired, .failoverProtectionRestored:
            preferences.operationalStatus
        case .monitorDown, .monitorRecovered: preferences.monitoring
        case .pairingRequest, .test, .rule: true
        }
    }
}

/// Display-only participant categories. Their history is durable but never
/// becomes ownership events or influences who may act for a service.
enum ParticipantActivityKind: String, Equatable {
    case onBattery, lowBattery, powerRestored, sessionEnding
    case operationalReady, operationalSynchronizing, operationalOutdated, operationalDegraded, operationalUnavailable
    case failoverProtectionImpaired, failoverProtectionRestored

    var title: String {
        switch self {
        case .onBattery: "UPS on battery"
        case .lowBattery: "Battery low"
        case .powerRestored: "Power restored"
        case .sessionEnding: "Session ending soon"
        case .operationalReady: "Operationally ready"
        case .operationalSynchronizing: "Synchronising"
        case .operationalOutdated: "Needs synchronisation"
        case .operationalDegraded: "Operationally degraded"
        case .operationalUnavailable: "Operational report unavailable"
        case .failoverProtectionImpaired: "Failover protection impaired"
        case .failoverProtectionRestored: "Failover protection restored"
        }
    }
    var symbol: String {
        switch self {
        case .onBattery: "bolt.trianglebadge.exclamationmark"
        case .lowBattery: "battery.0percent"
        case .powerRestored: "powerplug"
        case .sessionEnding: "bolt.shield"
        case .operationalReady: "checkmark.seal"
        case .operationalSynchronizing: "arrow.triangle.2.circlepath"
        case .operationalOutdated: "arrow.clockwise"
        case .operationalDegraded: "exclamationmark.triangle"
        case .operationalUnavailable: "clock.badge.exclamationmark"
        case .failoverProtectionImpaired: "shield.slash"
        case .failoverProtectionRestored: "shield.checkered"
        }
    }

    var source: String {
        switch self {
        case .onBattery, .lowBattery, .powerRestored, .sessionEnding: "SwiftBot-reported"
        case .operationalReady, .operationalSynchronizing, .operationalOutdated, .operationalDegraded:
            "SwiftBot-reported"
        case .operationalUnavailable, .failoverProtectionImpaired, .failoverProtectionRestored:
            "Ruru-observed"
        }
    }
}

struct ParticipantActivityTransition {
    let clusterID: String
    let nodeID: String
    let nodeName: String
    let date: Date
    let kind: ParticipantActivityKind
    let detail: String
}

/// Edges from bounded operational reports. The monitor records what SwiftBot
/// reported separately from Ruru's own freshness/protection observations. It
/// does not read, write, or influence leases.
struct OperationalAlertMonitor {
    private enum Condition: Equatable {
        case ready, synchronizing, outdated, degraded, unavailable

        init(observation: OperationalStatusObservation) {
            guard observation.fresh else { self = .unavailable; return }
            switch observation.state {
            case .ready: self = .ready
            case .synchronizing: self = .synchronizing
            case .outdated: self = .outdated
            case .degraded: self = .degraded
            case .unknown: self = .unavailable
            }
        }

        var activityKind: ParticipantActivityKind {
            switch self {
            case .ready: .operationalReady
            case .synchronizing: .operationalSynchronizing
            case .outdated: .operationalOutdated
            case .degraded: .operationalDegraded
            case .unavailable: .operationalUnavailable
            }
        }

        /// Application-neutral wording for rule notifications.
        var neutralDetail: String {
            switch self {
            case .ready: "The application reported that readiness checks are complete."
            case .synchronizing: "The application reported that synchronisation is in progress."
            case .outdated: "The application reported that required data is out of date."
            case .degraded: "The application reported a degraded operational condition."
            case .unavailable: "Ruru observed that the operational report is stale or unavailable."
            }
        }

        var detail: String {
            switch self {
            case .ready: "SwiftBot reported that readiness checks are complete."
            case .synchronizing: "SwiftBot reported that synchronisation is in progress."
            case .outdated: "SwiftBot reported that required data is out of date."
            case .degraded: "SwiftBot reported a degraded operational condition."
            case .unavailable: "Ruru observed that the operational report is stale or unavailable."
            }
        }
    }

    private struct State {
        var condition: Condition
        var nodeName: String
        var standby = false
        var wasReady = false
        var changedAt = Date.distantPast
    }

    private var states: [String: State] = [:]
    private var protectionImpaired: [String: Date] = [:]

    mutating func observe(_ observations: [OperationalStatusObservation], participants: [ParticipantObservation],
                          owners: Set<String>, serviceNames: [String: String], at now: Date)
        -> (alerts: [RuruAlert], events: [ParticipantActivityTransition]) {
        let roles = Dictionary(uniqueKeysWithValues: participants.filter(\.fresh).map {
            ("\($0.clusterID)|\($0.nodeID)", $0.role)
        })
        let latest = Dictionary(uniqueKeysWithValues: observations.map { ("\($0.clusterID)|\($0.nodeID)", $0) })
        var alerts: [RuruAlert] = []
        var events: [ParticipantActivityTransition] = []

        for (key, observation) in latest.sorted(by: { $0.key < $1.key }) {
            let condition = Condition(observation: observation)
            let nodeName = observation.nodeName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? observation.nodeID
            let standby = roles[key] == .standby
            let prior = states[key]
            states[key] = State(condition: condition, nodeName: nodeName, standby: standby || prior?.standby == true,
                                wasReady: condition == .ready || prior?.wasReady == true,
                                changedAt: prior?.condition == condition ? prior!.changedAt : now)
            guard prior?.condition != condition else { continue }
            events.append(.init(clusterID: observation.clusterID, nodeID: observation.nodeID, nodeName: nodeName,
                                date: now, kind: condition.activityKind, detail: condition.detail))
            if prior?.condition == .ready, condition != .ready {
                let service = serviceNames[observation.clusterID] ?? observation.clusterID
                alerts.append(.init(kind: .operationalDegraded, key: "operational|\(key)",
                                    title: "\(nodeName) needs attention", detail: "\(service) · \(condition.detail)",
                                    context: .init(service: service, server: nodeName)))
            } else if prior != nil, prior!.condition != .ready, condition == .ready {
                let service = serviceNames[observation.clusterID] ?? observation.clusterID
                alerts.append(.init(kind: .operationalRecovered, key: "operational|\(key)",
                                    title: "\(nodeName) is operationally ready", detail: "\(service) · SwiftBot reported that readiness checks are complete.",
                                    context: .init(service: service, server: nodeName)))
            }
        }

        // A retained report that stops refreshing becomes a Ruru-observed
        // unavailable condition; it is deliberately distinct from a client
        // claiming that it is degraded.
        for (key, prior) in Array(states) where latest[key] == nil && serviceNames[key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""] != nil {
            guard prior.condition != .unavailable else { continue }
            let pieces = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard pieces.count == 2 else { continue }
            let clusterID = pieces[0], nodeID = pieces[1]
            states[key] = State(condition: .unavailable, nodeName: prior.nodeName, standby: prior.standby,
                                wasReady: prior.wasReady, changedAt: now)
            events.append(.init(clusterID: clusterID, nodeID: nodeID, nodeName: prior.nodeName, date: now,
                                kind: .operationalUnavailable, detail: Condition.unavailable.detail))
            if prior.condition == .ready {
                let service = serviceNames[clusterID] ?? clusterID
                alerts.append(.init(kind: .operationalDegraded, key: "operational|\(key)",
                                    title: "\(prior.nodeName) needs attention", detail: "\(service) · \(Condition.unavailable.detail)",
                                    context: .init(service: service, server: prior.nodeName)))
            }
        }

        for (clusterID, service) in serviceNames.sorted(by: { $0.key < $1.key }) {
            let standbys = states.filter { key, state in key.hasPrefix(clusterID + "|") && state.standby && state.wasReady }
            let protected = !standbys.isEmpty && standbys.contains { $0.value.condition == .ready }
            let impaired = owners.contains(clusterID) && !standbys.isEmpty && !protected
            if impaired, protectionImpaired[clusterID] == nil {
                protectionImpaired[clusterID] = now
                events.append(.init(clusterID: clusterID, nodeID: "ruru", nodeName: "Ruru", date: now,
                                    kind: .failoverProtectionImpaired,
                                    detail: "Ruru observed no previously-ready standby that is operationally ready."))
                alerts.append(.init(kind: .failoverProtectionImpaired, key: "protection|\(clusterID)",
                                    title: "\(service) failover protection is impaired",
                                    detail: "The Primary still owns the service, but no previously-ready standby is operationally ready.",
                                    context: .init(service: service)))
            } else if !impaired, protectionImpaired.removeValue(forKey: clusterID) != nil {
                events.append(.init(clusterID: clusterID, nodeID: "ruru", nodeName: "Ruru", date: now,
                                    kind: .failoverProtectionRestored,
                                    detail: "Ruru observed an operationally ready standby."))
                alerts.append(.init(kind: .failoverProtectionRestored, key: "protection|\(clusterID)",
                                    title: "\(service) failover protection is restored",
                                    detail: "Ruru observed an operationally ready standby again.",
                                    context: .init(service: service)))
            }
        }
        states = states.filter { key, _ in serviceNames[key.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""] != nil }
        protectionImpaired = protectionImpaired.filter { serviceNames[$0.key] != nil }
        return (alerts, events)
    }

    /// Current readiness of every node that has been ready, and failover protection
    /// per service, as readings. A node that never became ready is not reported:
    /// "was ready and is not" is the condition worth a notification. What the
    /// application reported and what Ruru itself observed (a report gone stale)
    /// carry different evidence labels.
    func conditionSignals(subjects: RuruAlertSubjects, at now: Date) -> [AlertSignal] {
        var signals: [AlertSignal] = []
        for (key, state) in states.sorted(by: { $0.key < $1.key }) {
            let pieces = key.split(separator: "|", maxSplits: 1).map(String.init)
            guard pieces.count == 2, let subject = subjects.node(clusterID: pieces[0], nodeID: pieces[1], name: state.nodeName) else { continue }
            let service = subject.groupName ?? pieces[0]
            if state.condition == .ready {
                signals.append(AlertSignal(
                    trigger: .nodeDegraded, subject: subject, shape: .condition(.clear),
                    title: "\(state.nodeName) is operationally ready",
                    detail: "\(service) · The application reported that readiness checks are complete.",
                    basis: .applicationReported, observedAt: now))
            } else if state.wasReady {
                let observed = state.condition == .unavailable
                signals.append(AlertSignal(
                    trigger: .nodeDegraded, subject: subject,
                    shape: .condition(.active(.init(since: state.changedAt == .distantPast ? nil : state.changedAt,
                                                    confirmed: true, maxGap: 30))),
                    title: "\(state.nodeName) needs attention",
                    detail: "\(service) · " + (observed ? "Ruru observed that the operational report is stale or unavailable."
                                                       : state.condition.neutralDetail),
                    basis: observed ? .ruruObserved : .applicationReported, observedAt: now))
            }
        }
        for (clusterID, subject) in subjects.services.sorted(by: { $0.key < $1.key }) {
            if let since = protectionImpaired[clusterID] {
                signals.append(AlertSignal(
                    trigger: .protectionImpaired, subject: subject,
                    shape: .condition(.active(.init(since: since, confirmed: true, maxGap: 30))),
                    title: "\(subject.name) failover protection is impaired",
                    detail: "The Primary still owns the service, but no previously-ready standby is operationally ready.",
                    basis: .ruruObserved, observedAt: now))
            } else {
                signals.append(AlertSignal(
                    trigger: .protectionImpaired, subject: subject, shape: .condition(.clear),
                    title: "\(subject.name) failover protection is restored",
                    detail: "Ruru observed an operationally ready standby again.", basis: .ruruObserved, observedAt: now))
            }
        }
        return signals
    }
}

/// Detects edges in fresh, self-reported participant telemetry. The first
/// observation establishes a baseline so opening Ruru doesn't invent an alert.
struct ParticipantAlertMonitor {
    private struct State {
        var externalPower: Bool?
        var batteryPercent: Int?
        var sessionEnding: Bool?
        var onBattery = false
        var onBatterySince = Date.distantPast
        var nodeName = ""
        var clusterID = ""
        var nodeID = ""
    }
    private var states: [String: State] = [:]

    mutating func observe(_ observations: [ParticipantObservation], serviceNames: [String: String], at now: Date)
        -> (alerts: [RuruAlert], events: [ParticipantActivityTransition]) {
        var alerts: [RuruAlert] = []
        var events: [ParticipantActivityTransition] = []
        let fresh = observations.filter(\.fresh)
        let seen = Set(fresh.map { "\($0.clusterID)|\($0.nodeID)" })
        for observation in fresh.sorted(by: {
            $0.clusterID == $1.clusterID ? $0.nodeID < $1.nodeID : $0.clusterID < $1.clusterID
        }) {
            let key = "\(observation.clusterID)|\(observation.nodeID)"
            let prior = states[key]
            let node = observation.nodeName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? observation.nodeID
            let service = serviceNames[observation.clusterID] ?? observation.clusterID
            func append(_ kind: ParticipantActivityKind, _ alertKind: RuruAlert.Kind, _ detail: String) {
                events.append(.init(clusterID: observation.clusterID, nodeID: observation.nodeID,
                                    nodeName: node, date: now, kind: kind, detail: detail))
                alerts.append(.init(kind: alertKind, key: "participant|\(alertKind)|\(key)",
                                    title: "\(node): \(kind.title)", detail: "\(service) · \(detail)"))
            }
            if let prior {
                if observation.powerSource == .ups, prior.externalPower == true, observation.externalPower == false {
                    append(.onBattery, .participantOnBattery, "The UPS is supplying power.")
                }
                if let percent = observation.batteryPercent, percent <= 20,
                   prior.batteryPercent.map({ $0 > 20 }) == true, observation.externalPower != true {
                    append(.lowBattery, .participantLowBattery, "Battery is at \(percent)%.")
                }
                if prior.externalPower == false, observation.externalPower == true {
                    append(.powerRestored, .participantPowerRestored, "External power is connected again.")
                }
                if prior.sessionEnding != true, observation.sessionEnding == true {
                    append(.sessionEnding, .participantSessionEnding, "The participant reports a planned session end.")
                }
            }
            let onBattery = observation.powerSource == .ups && observation.externalPower == false
            states[key] = State(externalPower: observation.externalPower,
                                batteryPercent: observation.batteryPercent,
                                sessionEnding: observation.sessionEnding,
                                onBattery: onBattery,
                                onBatterySince: onBattery ? (prior?.onBattery == true ? prior!.onBatterySince : now) : .distantPast,
                                nodeName: node, clusterID: observation.clusterID, nodeID: observation.nodeID)
        }
        // Participants are bounded per service by ParticipantPresence; prune
        // departed keys so this edge cache remains bounded as configurations change.
        states = states.filter { seen.contains($0.key) }
        return (alerts, events)
    }

    /// Whether each fresh participant is currently running on battery power. Only
    /// participants reporting now are read; an absent one produces no reading.
    func conditionSignals(subjects: RuruAlertSubjects, at now: Date) -> [AlertSignal] {
        states.sorted(by: { $0.key < $1.key }).compactMap { _, state in
            guard let subject = subjects.node(clusterID: state.clusterID, nodeID: state.nodeID, name: state.nodeName) else { return nil }
            let service = subject.groupName ?? state.clusterID
            if state.onBattery {
                return AlertSignal(
                    trigger: .participantOnBattery, subject: subject,
                    shape: .condition(.active(.init(since: state.onBatterySince, confirmed: true, maxGap: 90))),
                    title: "\(state.nodeName): UPS on battery", detail: "\(service) · The UPS is supplying power.",
                    basis: .applicationReported, observedAt: now)
            }
            guard state.externalPower != nil else { return nil }
            return AlertSignal(
                trigger: .participantOnBattery, subject: subject, shape: .condition(.clear),
                title: "\(state.nodeName): Power restored", detail: "\(service) · External power is connected again.",
                basis: .applicationReported, observedAt: now)
        }
    }
}

/// Spots every change of owner, planned or not, from the leases Ruru itself holds.
/// Failovers and outages are judged elsewhere; this only reports that ownership moved.
struct OwnershipTransferMonitor {
    struct Transfer: Equatable { let clusterID: String; let from: String; let to: String }
    private var previous: [String: RuruAlertMonitor.Owner] = [:]

    mutating func observe(owners: [String: RuruAlertMonitor.Owner], serving: Bool, services: Set<String>) -> [Transfer] {
        // While not serving, or in restart quarantine, leases say nothing about owners.
        guard serving else { return [] }
        var transfers: [Transfer] = []
        for (cluster, owner) in owners.sorted(by: { $0.key < $1.key }) where services.contains(cluster) {
            if let before = previous[cluster], before.nodeID != owner.nodeID {
                transfers.append(Transfer(clusterID: cluster, from: before.name, to: owner.name))
            }
            previous[cluster] = owner
        }
        previous = previous.filter { services.contains($0.key) }
        return transfers
    }
}

/// Stable identities for the things alerts are about. Ruru's guarded services are
/// referred to by their metadata ID, never their protocol cluster ID or name.
struct RuruAlertSubjects {
    static let authority = SubjectRef(source: .authority, kind: "ruru", id: "ruru", name: "Ruru")

    /// clusterID → the guarded service's subject.
    var services: [String: SubjectRef] = [:]

    init(services: [GuardedService] = []) {
        for service in services {
            self.services[service.clusterID] = SubjectRef(source: .guarding, kind: "service", id: service.id, name: service.name)
        }
    }

    func node(clusterID: String, nodeID: String, name: String) -> SubjectRef? {
        guard let service = services[clusterID] else { return nil }
        return SubjectRef(source: .operationalStatus, kind: "node", id: "\(service.id)|\(nodeID)", name: name,
                          groupID: service.id, groupName: service.name)
    }

    func monitor(_ target: MonitorTarget) -> SubjectRef {
        SubjectRef(source: .monitoring, kind: "monitor", id: target.id, name: target.name)
    }

    func monitor(id: String, name: String) -> SubjectRef {
        SubjectRef(source: .monitoring, kind: "monitor", id: id, name: name)
    }
}

/// Translates what Ruru's producers already detect into application-neutral signals.
enum RuruAlertSignals {
    /// A failover detected by the ownership monitor.
    static func failover(_ alert: RuruAlert, subjects: RuruAlertSubjects, at now: Date) -> AlertSignal? {
        guard alert.kind == .failover, alert.key.hasPrefix("failover|"),
              let subject = subjects.services[String(alert.key.dropFirst("failover|".count))] else { return nil }
        return AlertSignal(trigger: .failoverCompleted, subject: subject, shape: .event, title: alert.title,
                           detail: alert.detail, basis: .authoritativeLease, observedAt: now)
    }

    static func ownership(_ transfers: [OwnershipTransferMonitor.Transfer], subjects: RuruAlertSubjects, at now: Date) -> [AlertSignal] {
        transfers.compactMap { transfer in
            guard let subject = subjects.services[transfer.clusterID] else { return nil }
            return AlertSignal(trigger: .ownershipTransferred, subject: subject, shape: .event,
                               title: "\(subject.name) is now owned by \(transfer.to)", detail: "Previously \(transfer.from).",
                               basis: .authoritativeLease, observedAt: now)
        }
    }

    /// Low battery and planned session end are point-in-time reports.
    static func participantEvents(_ transitions: [ParticipantActivityTransition], subjects: RuruAlertSubjects,
                                  at now: Date) -> [AlertSignal] {
        transitions.compactMap { transition in
            let trigger: TriggerID
            switch transition.kind {
            case .lowBattery: trigger = .participantLowBattery
            case .sessionEnding: trigger = .participantSessionEnding
            default: return nil
            }
            guard let subject = subjects.node(clusterID: transition.clusterID, nodeID: transition.nodeID, name: transition.nodeName) else { return nil }
            return AlertSignal(trigger: trigger, subject: subject, shape: .event,
                               title: "\(transition.nodeName): \(transition.kind.title)",
                               detail: "\(subject.groupName ?? "") · \(transition.detail)", basis: .applicationReported, observedAt: now)
        }
    }

    /// A monitor's response time, for rules with a limit. A failed or inconclusive check has no
    /// response time, so it is inconclusive here; the unavailable rule covers outages.
    static func monitorLatency(_ observation: MonitorObservation, at now: Date) -> AlertSignal {
        let subject = RuruAlertSubjects().monitor(id: observation.targetID, name: observation.name)
        let result = observation.result
        let maxGap = max(120, Double(observation.intervalSeconds * 3 + observation.timeoutSeconds))
        guard result.ok, let latency = result.latencyMilliseconds else {
            return AlertSignal(trigger: .monitorSlow, subject: subject, shape: .condition(.inconclusive), title: "", detail: "",
                               basis: .ruruObserved, observedAt: now)
        }
        return AlertSignal(trigger: .monitorSlow, subject: subject, shape: .condition(.measurement(Double(latency), maxGap: maxGap)),
                           title: "\(observation.name) is responding slowly",
                           detail: "\(observation.address) responded in \(latency) ms", basis: .ruruObserved, observedAt: now,
                           recoveryTitle: "\(observation.name) is responding normally",
                           recoveryDetail: "\(observation.address) responded in \(latency) ms")
    }

    /// One check of a monitor. Failures and recoveries are readings of a condition:
    /// a failing check is evidence, a passing check clears it, and a check that
    /// could not tell (no network, ran late) neither confirms nor clears anything.
    static func monitor(_ observation: MonitorObservation, at now: Date) -> AlertSignal {
        let subject = RuruAlertSubjects().monitor(id: observation.targetID, name: observation.name)
        let result = observation.result
        let shape: AlertSignal.Shape
        var title = "\(observation.name) is unreachable", detail = "\(observation.address): \(result.detail)"
        if result.inconclusive {
            shape = .condition(.inconclusive)
        } else if result.ok {
            shape = .condition(.clear)
            title = "\(observation.name) is reachable again"; detail = observation.address
        } else {
            // Three checks plus a timeout without a result means this monitor stopped reporting.
            let maxGap = max(120, Double(observation.intervalSeconds * 3 + observation.timeoutSeconds))
            shape = .condition(.active(.init(failures: observation.consecutiveFailures,
                                             confirmed: observation.status == .down, maxGap: maxGap)))
        }
        return AlertSignal(trigger: .monitorUnavailable, subject: subject, shape: shape, title: title, detail: detail,
                           basis: .ruruObserved, observedAt: now)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Turns successive observations into alerts. Pure and deterministic: the
/// model feeds it once per poll, and tests feed it directly.
struct RuruAlertMonitor {
    struct Owner {
        let nodeID: String
        let name: String
        var webUIURL: String? = nil
    }
    struct Observation {
        var serviceRunning: Bool
        var recovering: Bool
        var serviceFailure: String?
        var tunnelError: String?
        var snapshotError: String?
        /// clusterID → current owner, identified by the durable lease's node ID.
        var owners: [String: Owner]
        /// clusterID → service name, for every configured service.
        var services: [String: String]
        /// IDs of release events, so planned hand-offs never alert.
        var releases: Set<String>
    }

    /// An owner that disappears without releasing is "down" if nobody takes
    /// over within this time; a takeover inside it is reported as a failover.
    var takeoverGrace: TimeInterval = 15

    private var owners: [String: Owner] = [:]
    private var lost: [String: (owner: Owner, since: Date)] = [:]
    private var down: [String: (owner: Owner, since: Date)] = [:]
    private var problems: [String: String] = [:]
    private var problemSince: [String: Date] = [:]
    private var seenReleases: Set<String>?
    /// Whether the last observation could judge ownership: serving, not in quarantine.
    private(set) var serving = false

    mutating func observe(_ observation: Observation, at now: Date) -> [RuruAlert] {
        var alerts = authorityAlerts(observation, at: now)
        serving = observation.serviceRunning && !observation.recovering
        // Ownership is only meaningful while serving and out of restart
        // quarantine; a stop or restart must not look like services failing.
        guard observation.serviceRunning, !observation.recovering else {
            owners = [:]; lost = [:]; down = [:]
            seenReleases = observation.releases
            return alerts
        }
        let newReleases = observation.releases.subtracting(seenReleases ?? observation.releases)
        seenReleases = observation.releases
        let released = Set(newReleases.compactMap { $0.split(separator: "|").first.map(String.init) })

        for (cluster, name) in observation.services.sorted(by: { $0.key < $1.key }) {
            let current = observation.owners[cluster]
            if let previous = owners[cluster], current == nil {
                if released.contains(cluster) { lost[cluster] = nil }
                else { lost[cluster] = (previous, now) }
            }
            if let current {
                if let loss = lost.removeValue(forKey: cluster), loss.owner.nodeID != current.nodeID, observation.services[cluster] != nil {
                    alerts.append(RuruAlert(kind: .failover, key: "failover|" + cluster, title: "\(name) failed over",
                                            detail: "Ownership moved from \(loss.owner.name) to \(current.name).",
                                            context: .init(service: name, previousOwner: loss.owner.name, currentOwner: current.name,
                                                           webUIURL: ParticipantWebUI.normalizedURL(current.webUIURL))))
                } else if let previous = owners[cluster], previous.nodeID != current.nodeID, !released.contains(cluster) {
                    alerts.append(RuruAlert(kind: .failover, key: "failover|" + cluster, title: "\(name) failed over",
                                            detail: "Ownership moved from \(previous.name) to \(current.name).",
                                            context: .init(service: name, previousOwner: previous.name, currentOwner: current.name,
                                                           webUIURL: ParticipantWebUI.normalizedURL(current.webUIURL))))
                }
                if down.removeValue(forKey: cluster) != nil {
                    alerts.append(RuruAlert(kind: .serviceRecovered, key: "down|" + cluster, title: "\(name) is back",
                                            detail: "\(current.name) now owns \(name).",
                                            context: .init(service: name, currentOwner: current.name,
                                                           webUIURL: ParticipantWebUI.normalizedURL(current.webUIURL))))
                }
            } else if let loss = lost[cluster], now.timeIntervalSince(loss.since) >= takeoverGrace, down[cluster] == nil {
                lost[cluster] = nil
                down[cluster] = loss
                alerts.append(RuruAlert(kind: .serviceDown, key: "down|" + cluster, title: "\(name) is down",
                                        detail: "\(loss.owner.name) stopped renewing and no other server has taken over.",
                                        context: .init(service: name, previousOwner: loss.owner.name)))
            }
        }
        owners = observation.owners.filter { observation.services[$0.key] != nil }
        lost = lost.filter { observation.services[$0.key] != nil }
        down = down.filter { observation.services[$0.key] != nil }
        return alerts
    }

    /// The current state of Ruru's own conditions and of each service's ownership, as
    /// fresh readings for the alert engine. Authority problems are read every poll;
    /// ownership is only judged while serving, since a stop or restart quarantine
    /// says nothing about whether a service has lost its owner.
    func conditionSignals(subjects: RuruAlertSubjects, at now: Date) -> [AlertSignal] {
        var signals: [AlertSignal] = []
        let authority: [(key: String, trigger: TriggerID, problem: String, resolved: String)] = [
            ("listener", .serviceStopped, "Ruru's service stopped", "Ruru's service is running again"),
            ("snapshot", .snapshotFailed, "Ruru could not save a snapshot", "Ruru saved a snapshot"),
            ("tunnel", .internetAccessDown, "Ruru's Internet Access is down", "Ruru's Internet Access is back")
        ]
        for check in authority {
            if let detail = problems[check.key] {
                signals.append(AlertSignal(
                    trigger: check.trigger, subject: RuruAlertSubjects.authority,
                    shape: .condition(.active(.init(since: problemSince[check.key], confirmed: true, maxGap: 30))),
                    title: check.problem, detail: detail, basis: .ruruObserved, observedAt: now))
            } else {
                signals.append(AlertSignal(
                    trigger: check.trigger, subject: RuruAlertSubjects.authority, shape: .condition(.clear),
                    title: check.resolved, detail: "Resolved.", basis: .ruruObserved, observedAt: now))
            }
        }
        for (clusterID, subject) in subjects.services.sorted(by: { $0.key < $1.key }) {
            let shape: AlertSignal.Shape
            var title = "\(subject.name) is back", detail = "Ownership is normal."
            if !serving {
                shape = .condition(.inconclusive)
            } else if let loss = lost[clusterID] ?? down[clusterID] {
                signals.append(AlertSignal(
                    trigger: .primaryUnreachable, subject: subject,
                    shape: .condition(.active(.init(since: loss.since, confirmed: true, maxGap: 30))),
                    title: "\(subject.name) is down",
                    detail: "\(loss.owner.name) stopped renewing and no other server has taken over.",
                    basis: .authoritativeLease, observedAt: now))
                continue
            } else {
                if let owner = owners[clusterID] { detail = "\(owner.name) now owns \(subject.name)." }
                shape = .condition(.clear)
            }
            title = "\(subject.name) is back"
            signals.append(AlertSignal(trigger: .primaryUnreachable, subject: subject, shape: shape,
                                       title: title, detail: detail, basis: .authoritativeLease, observedAt: now))
        }
        return signals
    }

    private mutating func authorityAlerts(_ observation: Observation, at now: Date) -> [RuruAlert] {
        let checks: [(key: String, problem: String, resolved: String, detail: String?)] = [
            ("listener", "Ruru's service stopped", "Ruru's service is running again", observation.serviceFailure),
            ("snapshot", "Ruru could not save a snapshot", "Ruru saved a snapshot", observation.snapshotError),
            ("tunnel", "Ruru's Internet Access is down", "Ruru's Internet Access is back", observation.tunnelError)
        ]
        var alerts: [RuruAlert] = []
        for check in checks {
            if let detail = check.detail, problems[check.key] != detail {
                if problems[check.key] == nil { problemSince[check.key] = now }
                problems[check.key] = detail
                alerts.append(RuruAlert(kind: .authorityProblem, key: "authority|" + check.key, title: check.problem, detail: detail))
            } else if check.detail == nil, problems.removeValue(forKey: check.key) != nil {
                problemSince[check.key] = nil
                alerts.append(RuruAlert(kind: .authorityRecovered, key: "authority|" + check.key,
                                        title: check.resolved, detail: "Resolved."))
            }
        }
        return alerts
    }
}

/// Discord incoming webhooks. Only official Discord hosts are accepted, so a
/// pasted URL cannot send alerts to an arbitrary server.
enum RuruDiscordWebhook {
    static let keychainAccount = "discord-webhook"

    static func validated(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= 512, let url = URL(string: trimmed), url.scheme == "https",
              let host = url.host?.lowercased(),
              ["discord.com", "discordapp.com", "ptb.discord.com", "canary.discord.com"].contains(host),
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/")
        guard parts.count == 4, parts[0] == "api", parts[1] == "webhooks",
              Int64(parts[2]) != nil, parts[3].count >= 32,
              parts[3].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        return url
    }

    static func payload(for alert: RuruAlert, at date: Date) throws -> Data {
        let color: Int = switch alert.severity {
        case .critical: 0xE5484D
        case .warning: 0xF5A524
        case .resolved: 0x30A46C
        case .info: 0x5865F2
        }
        let presentation: (icon: String, footer: String) = switch alert.kind {
        case .serviceDown: ("⛔", "Ruru • Guarding")
        case .serviceRecovered: ("✅", "Ruru • Guarding")
        case .failover: ("🔄", "Ruru • Guarding")
        case .authorityProblem: ("⚠️", "Ruru • System")
        case .authorityRecovered: ("✅", "Ruru • System")
        case .participantOnBattery: ("🔋", "Ruru • Participant status")
        case .participantLowBattery: ("🪫", "Ruru • Participant status")
        case .participantPowerRestored: ("🔌", "Ruru • Participant status")
        case .participantSessionEnding: ("⚡", "Ruru • Participant status")
        case .operationalDegraded: ("⚠️", "Ruru • Operational status")
        case .operationalRecovered: ("✅", "Ruru • Operational status")
        case .failoverProtectionImpaired: ("🛡️", "Ruru • Failover protection")
        case .failoverProtectionRestored: ("✅", "Ruru • Failover protection")
        case .monitorDown: ("📡", "Ruru • Monitoring")
        case .monitorRecovered: ("✅", "Ruru • Monitoring")
        case .pairingRequest: ("🔔", "Ruru • Pairing")
        case .test: ("✅", "Ruru • Test notification")
        case .rule:
            (Self.icon(for: alert.severity), "Ruru • Alerts" + (alert.basisLabel.map { " • \($0)" } ?? ""))
        }
        let description: String
        if alert.context != nil {
            description = switch alert.kind {
            case .serviceDown: "The owner stopped renewing and no other server has taken over."
            case .serviceRecovered: "Ownership has been restored."
            case .failover: ParticipantWebUI.normalizedURL(alert.context?.webUIURL) != nil
                ? "Another server has taken over ownership. Use the Web UI below to connect to the new owner."
                : "Another server has taken over ownership."
            case .pairingRequest: "Approve or reject this request in Ruru → Guarding."
            default: alert.detail
            }
        } else {
            description = alert.detail
        }
        var embed: [String: Any] = [
            "title": limitedText("\(presentation.icon) \(alert.title)", to: 256),
            "description": limitedText(plainText(description), to: 2_000),
            "color": color,
            "footer": ["text": presentation.footer],
            "timestamp": ISO8601DateFormatter().string(from: date)
        ]
        if let context = alert.context {
            var fields: [[String: Any]] = []
            func addField(_ name: String, _ value: String?, inline: Bool) {
                guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                fields.append(["name": name, "value": limitedText(plainText(value), to: 512), "inline": inline])
            }
            addField("Service", context.service, inline: false)
            addField(alert.kind == .serviceDown ? "Last owner" : "Previous owner", context.previousOwner, inline: true)
            addField("Current owner", context.currentOwner, inline: true)
            addField("Server", context.server, inline: true)
            if [.failover, .serviceRecovered].contains(alert.kind),
               let url = ParticipantWebUI.normalizedURL(context.webUIURL) {
                let address = plainText(String(url.dropFirst("https://".count)))
                fields.append(["name": "Web UI", "value": "[\(address)](\(url))", "inline": false])
            }
            if !fields.isEmpty { embed["fields"] = fields }
        }
        let body: [String: Any] = [
            "username": "Ruru",
            "allowed_mentions": ["parse": [String]()],
            "embeds": [embed]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    private static func icon(for severity: RuruAlert.Severity) -> String {
        switch severity { case .critical: "⛔"; case .warning: "⚠️"; case .resolved: "✅"; case .info: "ℹ️" }
    }

    /// Keep display names and error details from becoming Discord formatting.
    private static func plainText(_ text: String) -> String {
        text.reduce(into: "") { result, character in
            if "\\`*_~|>[]".contains(character) { result.append("\\") }
            result.append(character)
        }
    }

    /// A conservative UTF-16 budget also bounds emoji-heavy names. Preserve
    /// whole characters and leave room for an ellipsis when truncating.
    private static func limitedText(_ text: String, to limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var result = ""
        var length = 0
        for character in text {
            let count = String(character).utf16.count
            guard length + count < limit else { break }
            result.append(character)
            length += count
        }
        return result + "…"
    }
}
