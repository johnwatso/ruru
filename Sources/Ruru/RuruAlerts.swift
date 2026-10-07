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
    enum Kind: Equatable { case serviceDown, serviceRecovered, failover, authorityProblem, authorityRecovered, test }
    enum Severity: Equatable { case critical, warning, resolved, info }

    let kind: Kind
    let key: String
    let title: String
    let detail: String

    var severity: Severity {
        switch kind {
        case .serviceDown, .authorityProblem: .critical
        case .failover: .warning
        case .serviceRecovered, .authorityRecovered: .resolved
        case .test: .info
        }
    }

    func isEnabled(in preferences: RuruAlertPreferences) -> Bool {
        switch kind {
        case .serviceDown, .serviceRecovered: preferences.serviceDown
        case .failover: preferences.failover
        case .authorityProblem, .authorityRecovered: preferences.authorityProblems
        case .test: true
        }
    }
}

/// Turns successive observations into alerts. Pure and deterministic: the
/// model feeds it once per poll, and tests feed it directly.
struct RuruAlertMonitor {
    struct Observation {
        var serviceRunning: Bool
        var recovering: Bool
        var serviceFailure: String?
        var tunnelError: String?
        var snapshotError: String?
        /// clusterID → current owner's display name, for services with a live owner.
        var owners: [String: String]
        /// clusterID → service name, for every configured service.
        var services: [String: String]
        /// IDs of release events, so planned hand-offs never alert.
        var releases: Set<String>
    }

    /// An owner that disappears without releasing is "down" if nobody takes
    /// over within this time; a takeover inside it is reported as a failover.
    var takeoverGrace: TimeInterval = 15

    private var owners: [String: String] = [:]
    private var lost: [String: (owner: String, since: Date)] = [:]
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
                if let loss = lost.removeValue(forKey: cluster), loss.owner != current, observation.services[cluster] != nil {
                    alerts.append(RuruAlert(kind: .failover, key: "failover|" + cluster, title: "\(name) failed over",
                                            detail: "Ownership moved from \(loss.owner) to \(current)."))
                } else if let previous = owners[cluster], previous != current, !released.contains(cluster) {
                    alerts.append(RuruAlert(kind: .failover, key: "failover|" + cluster, title: "\(name) failed over",
                                            detail: "Ownership moved from \(previous) to \(current)."))
                }
                if down.remove(cluster) != nil {
                    alerts.append(RuruAlert(kind: .serviceRecovered, key: "down|" + cluster, title: "\(name) is back",
                                            detail: "\(current) now owns \(name)."))
                }
            } else if let loss = lost[cluster], now.timeIntervalSince(loss.since) >= takeoverGrace, !down.contains(cluster) {
                lost[cluster] = nil
                down.insert(cluster)
                alerts.append(RuruAlert(kind: .serviceDown, key: "down|" + cluster, title: "\(name) is down",
                                        detail: "\(loss.owner) stopped renewing and no other server has taken over."))
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
        case .info: 0x6E7681
        }
        let body: [String: Any] = [
            "username": "Ruru",
            "allowed_mentions": ["parse": [String]()],
            "embeds": [[
                "title": String(alert.title.prefix(256)),
                "description": String(alert.detail.prefix(2_000)),
                "color": color,
                "timestamp": ISO8601DateFormatter().string(from: date)
            ]]
        ]
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
}
