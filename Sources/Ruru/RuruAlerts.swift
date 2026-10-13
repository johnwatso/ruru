import Foundation
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
        case operationalDegraded, operationalRecovered, failoverProtectionImpaired, failoverProtectionRestored
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

    var severity: Severity {
        switch kind {
        case .serviceDown, .authorityProblem, .participantLowBattery, .failoverProtectionImpaired: .critical
        case .failover, .participantOnBattery, .participantSessionEnding, .operationalDegraded: .warning
        case .participantPowerRestored, .operationalRecovered, .failoverProtectionRestored: .resolved
        case .serviceRecovered, .authorityRecovered: .resolved
        case .pairingRequest, .test: .info
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
        case .pairingRequest, .test: true
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
    }

    private var states: [String: State] = [:]
    private var protectionImpaired: Set<String> = []

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
                                wasReady: condition == .ready || prior?.wasReady == true)
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
            states[key] = State(condition: .unavailable, nodeName: prior.nodeName, standby: prior.standby, wasReady: prior.wasReady)
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
            if impaired, protectionImpaired.insert(clusterID).inserted {
                events.append(.init(clusterID: clusterID, nodeID: "ruru", nodeName: "Ruru", date: now,
                                    kind: .failoverProtectionImpaired,
                                    detail: "Ruru observed no previously-ready standby that is operationally ready."))
                alerts.append(.init(kind: .failoverProtectionImpaired, key: "protection|\(clusterID)",
                                    title: "\(service) failover protection is impaired",
                                    detail: "The Primary still owns the service, but no previously-ready standby is operationally ready.",
                                    context: .init(service: service)))
            } else if !impaired, protectionImpaired.remove(clusterID) != nil {
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
        protectionImpaired.formIntersection(Set(serviceNames.keys))
        return (alerts, events)
    }
}

/// Detects edges in fresh, self-reported participant telemetry. The first
/// observation establishes a baseline so opening Ruru doesn't invent an alert.
struct ParticipantAlertMonitor {
    private struct State {
        var externalPower: Bool?
        var batteryPercent: Int?
        var sessionEnding: Bool?
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
            states[key] = State(externalPower: observation.externalPower,
                                batteryPercent: observation.batteryPercent,
                                sessionEnding: observation.sessionEnding)
        }
        // Participants are bounded per service by ParticipantPresence; prune
        // departed keys so this edge cache remains bounded as configurations change.
        states = states.filter { seen.contains($0.key) }
        return (alerts, events)
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
    private var down: Set<String> = []
    private var problems: [String: String] = [:]
    private var seenReleases: Set<String>?

    mutating func observe(_ observation: Observation, at now: Date) -> [RuruAlert] {
        var alerts = authorityAlerts(observation)
        // Ownership is only meaningful while serving and out of restart
        // quarantine; a stop or restart must not look like services failing.
        guard observation.serviceRunning, !observation.recovering else {
            owners = [:]; lost = [:]; down = []
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
                if down.remove(cluster) != nil {
                    alerts.append(RuruAlert(kind: .serviceRecovered, key: "down|" + cluster, title: "\(name) is back",
                                            detail: "\(current.name) now owns \(name).",
                                            context: .init(service: name, currentOwner: current.name,
                                                           webUIURL: ParticipantWebUI.normalizedURL(current.webUIURL))))
                }
            } else if let loss = lost[cluster], now.timeIntervalSince(loss.since) >= takeoverGrace, !down.contains(cluster) {
                lost[cluster] = nil
                down.insert(cluster)
                alerts.append(RuruAlert(kind: .serviceDown, key: "down|" + cluster, title: "\(name) is down",
                                        detail: "\(loss.owner.name) stopped renewing and no other server has taken over.",
                                        context: .init(service: name, previousOwner: loss.owner.name)))
            }
        }
        owners = observation.owners.filter { observation.services[$0.key] != nil }
        lost = lost.filter { observation.services[$0.key] != nil }
        down = down.filter { observation.services[$0] != nil }
        return alerts
    }

    private mutating func authorityAlerts(_ observation: Observation) -> [RuruAlert] {
        let checks: [(key: String, problem: String, resolved: String, detail: String?)] = [
            ("listener", "Ruru's service stopped", "Ruru's service is running again", observation.serviceFailure),
            ("snapshot", "Ruru could not save a snapshot", "Ruru saved a snapshot", observation.snapshotError),
            ("tunnel", "Ruru's Internet Access is down", "Ruru's Internet Access is back", observation.tunnelError)
        ]
        var alerts: [RuruAlert] = []
        for check in checks {
            if let detail = check.detail, problems[check.key] != detail {
                problems[check.key] = detail
                alerts.append(RuruAlert(kind: .authorityProblem, key: "authority|" + check.key, title: check.problem, detail: detail))
            } else if check.detail == nil, problems.removeValue(forKey: check.key) != nil {
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
        case .pairingRequest: ("🔔", "Ruru • Pairing")
        case .test: ("✅", "Ruru • Test notification")
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
