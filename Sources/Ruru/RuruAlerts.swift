import Foundation
import WitnessKit

/// Which problems Ruru reports, and where. The Discord webhook URL itself is a
/// secret and lives in Keychain; only whether to use it is stored here.
struct RuruAlertPreferences: Codable, Equatable {
    var notifications = true
    var discord = false
    var serviceDown = true
    var failover = true
    var authorityProblems = true

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        notifications = try values.decodeIfPresent(Bool.self, forKey: .notifications) ?? defaults.notifications
        discord = try values.decodeIfPresent(Bool.self, forKey: .discord) ?? defaults.discord
        serviceDown = try values.decodeIfPresent(Bool.self, forKey: .serviceDown) ?? defaults.serviceDown
        failover = try values.decodeIfPresent(Bool.self, forKey: .failover) ?? defaults.failover
        authorityProblems = try values.decodeIfPresent(Bool.self, forKey: .authorityProblems) ?? defaults.authorityProblems
    }
}

struct RuruAlert: Equatable {
    enum Kind: Equatable { case serviceDown, serviceRecovered, failover, authorityProblem, authorityRecovered, pairingRequest, test }
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
        case .serviceDown, .authorityProblem: .critical
        case .failover: .warning
        case .serviceRecovered, .authorityRecovered: .resolved
        case .pairingRequest, .test: .info
        }
    }

    func isEnabled(in preferences: RuruAlertPreferences) -> Bool {
        switch kind {
        case .serviceDown, .serviceRecovered: preferences.serviceDown
        case .failover: preferences.failover
        case .authorityProblem, .authorityRecovered: preferences.authorityProblems
        case .pairingRequest, .test: true
        }
    }
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
