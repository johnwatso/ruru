import Foundation

// Application-neutral alert vocabulary. Nothing here knows about leases, SwiftBot
// or any producer's internals: producers publish `AlertSignal`s and this module
// decides what deserves a notification.

public enum AlertSource: String, Codable, CaseIterable, Sendable {
    case monitoring, guarding, coordination, authority, operationalStatus

    public var title: String {
        switch self {
        case .monitoring: "Monitoring"
        case .guarding: "Guarding"
        case .coordination: "Coordination"
        case .authority: "Ruru authority"
        case .operationalStatus: "Application status"
        }
    }

    public var symbol: String {
        switch self {
        case .monitoring: "waveform.path.ecg"
        case .guarding: "checkmark.shield"
        case .coordination: "square.stack.3d.up"
        case .authority: "server.rack"
        case .operationalStatus: "stethoscope"
        }
    }
}

/// What kind of evidence supports a signal. Ruru states only what it knows:
/// a lease record, its own observation, or an application's self-report.
public enum AlertBasis: String, Codable, Sendable {
    case authoritativeLease, ruruObserved, applicationReported

    public var label: String {
        switch self {
        case .authoritativeLease: "Authoritative lease record"
        case .ruruObserved: "Observed by Ruru"
        case .applicationReported: "Reported by the application"
        }
    }
}

public enum AlertSeverity: String, Codable, CaseIterable, Comparable, Sendable {
    case info, warning, critical

    private var rank: Int { switch self { case .info: 0; case .warning: 1; case .critical: 2 } }
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    public var title: String { rawValue.capitalized }
}

public enum AlertDestination: String, Codable, CaseIterable, Sendable {
    case macOS, discord, notify

    public var title: String {
        switch self {
        case .macOS: "macOS notifications"
        case .discord: "Discord"
        case .notify: "Notify!"
        }
    }
}

/// A stable reference to what a signal is about. Identity is source, kind and ID;
/// names are display-only and may change without creating a new subject.
public struct SubjectRef: Codable, Hashable, Sendable {
    public let source: AlertSource
    public let kind: String
    public let id: String
    public var name: String
    /// An optional grouping such as the guarded service a node belongs to, so a
    /// rule can target "everything in this service".
    public var groupID: String?
    public var groupName: String?

    public init(source: AlertSource, kind: String, id: String, name: String, groupID: String? = nil, groupName: String? = nil) {
        self.source = source; self.kind = kind; self.id = id; self.name = name
        self.groupID = groupID; self.groupName = groupName
    }

    public var key: String { "\(source.rawValue)|\(kind)|\(id)" }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key }
    public func hash(into hasher: inout Hasher) { hasher.combine(key) }
}

public struct TriggerID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// What a producer currently knows about a persistent condition.
public enum ConditionState: Sendable, Equatable {
    /// Fresh evidence that the condition holds.
    case active(ConditionEvidence)
    /// Fresh evidence that the condition does not hold.
    case clear
    /// Ruru could not tell (no network, check delayed, authority recovering). This
    /// neither confirms nor clears anything.
    case inconclusive
    /// A fresh measurement, such as a response time in milliseconds. Each rule
    /// compares it with its own limit: above is active evidence, at or below clears.
    case measurement(Double, maxGap: TimeInterval)
}

public struct ConditionEvidence: Sendable, Equatable {
    /// When the producer first observed this run of evidence, if it knows.
    public var since: Date?
    /// The producer's own consecutive-failure count, if it keeps one.
    public var failures: Int?
    /// The producer's own judgement that the condition is confirmed (for example a
    /// monitor that reached its configured failure threshold).
    public var confirmed: Bool
    /// The longest silence after which earlier evidence is no longer trusted.
    public var maxGap: TimeInterval

    public init(since: Date? = nil, failures: Int? = nil, confirmed: Bool = true, maxGap: TimeInterval = 30) {
        self.since = since; self.failures = failures; self.confirmed = confirmed; self.maxGap = maxGap
    }
}

public struct AlertSignal: Sendable, Equatable {
    public enum Shape: Sendable, Equatable {
        /// Something happened at a point in time.
        case event
        /// The latest reading of a persistent condition.
        case condition(ConditionState)
    }

    public let trigger: TriggerID
    public let subject: SubjectRef
    public let shape: Shape
    /// For an active condition or event, the problem. For a clear condition, the recovery.
    public let title: String
    public let detail: String
    public let basis: AlertBasis
    public let observedAt: Date
    /// For a measurement that falls within a rule's limit: the text of the recovery.
    public let recoveryTitle: String?
    public let recoveryDetail: String?

    public init(trigger: TriggerID, subject: SubjectRef, shape: Shape, title: String, detail: String,
                basis: AlertBasis, observedAt: Date, recoveryTitle: String? = nil, recoveryDetail: String? = nil) {
        self.trigger = trigger; self.subject = subject; self.shape = shape
        self.title = title; self.detail = detail; self.basis = basis; self.observedAt = observedAt
        self.recoveryTitle = recoveryTitle; self.recoveryDetail = recoveryDetail
    }
}

// MARK: Trigger catalogue

/// A numeric limit a trigger compares measurements against.
public struct LimitSpec: Sendable {
    public let title: String
    public let unit: String
    public let range: ClosedRange<Int>
    public let defaultValue: Int
    public let step: Int
}

public struct TriggerDescriptor: Sendable, Identifiable {
    public enum Lifecycle: Sendable { case event, condition }

    public let id: TriggerID
    public let source: AlertSource
    public let lifecycle: Lifecycle
    public let title: String
    public let summary: String
    public let symbol: String
    /// What a rule's target picks from, for example "monitor" or "service".
    public let subjectNoun: String
    public let thresholds: [Threshold.Kind]
    public let defaultThreshold: Threshold
    public let defaultSeverity: AlertSeverity
    public let basis: AlertBasis
    public let sampleTitle: String
    public let sampleDetail: String
    public let sampleRecoveryTitle: String
    /// Present for triggers that watch a measurement against a limit.
    public var limit: LimitSpec? = nil
    /// What the threshold counts: "failed" checks, or "slow" ones.
    public var checkAdjective: String { limit == nil ? "failed" : "slow" }

    public var supportsRecovery: Bool { lifecycle == .condition }
    public var supportsThreshold: Bool { lifecycle == .condition && !thresholds.isEmpty }
}

public extension TriggerID {
    static let monitorUnavailable: TriggerID = "monitor.unavailable"
    static let monitorSlow: TriggerID = "monitor.slowResponse"
    static let primaryUnreachable: TriggerID = "guarding.primaryUnreachable"
    static let failoverCompleted: TriggerID = "guarding.failoverCompleted"
    static let ownershipTransferred: TriggerID = "guarding.ownershipTransferred"
    static let nodeDegraded: TriggerID = "operational.nodeDegraded"
    static let protectionImpaired: TriggerID = "operational.failoverProtectionImpaired"
    static let participantOnBattery: TriggerID = "coordination.participantOnBattery"
    static let participantLowBattery: TriggerID = "coordination.participantLowBattery"
    static let participantSessionEnding: TriggerID = "coordination.participantSessionEnding"
    static let serviceStopped: TriggerID = "authority.serviceStopped"
    static let snapshotFailed: TriggerID = "authority.snapshotFailed"
    static let internetAccessDown: TriggerID = "authority.internetAccessDown"
    static let authorityRestarted: TriggerID = "authority.restarted"
}

public enum TriggerCatalogue {
    public static let all: [TriggerDescriptor] = [
        .init(id: .monitorUnavailable, source: .monitoring, lifecycle: .condition,
              title: "Monitor becomes unavailable", summary: "A website, Mac or network service stops answering its checks.",
              symbol: "waveform.path.ecg", subjectNoun: "monitor",
              thresholds: [.sourceDefault, .immediately, .failedChecks, .afterSeconds], defaultThreshold: .sourceDefault,
              defaultSeverity: .critical, basis: .ruruObserved,
              sampleTitle: "Company website is unreachable", sampleDetail: "https://example.com: HTTP 503",
              sampleRecoveryTitle: "Company website is reachable again"),
        .init(id: .monitorSlow, source: .monitoring, lifecycle: .condition,
              title: "Monitor responds slowly", summary: "A monitor's response time stays above a limit you choose. Response time is how long the check took to connect or to receive headers, not an ICMP ping.",
              symbol: "gauge.with.dots.needle.67percent", subjectNoun: "monitor",
              thresholds: [.failedChecks, .immediately, .afterSeconds], defaultThreshold: .failedChecks(3),
              defaultSeverity: .warning, basis: .ruruObserved,
              sampleTitle: "NAS is responding slowly", sampleDetail: "192.168.1.20:445 responded in 182 ms (limit 30 ms)",
              sampleRecoveryTitle: "NAS is responding normally",
              limit: LimitSpec(title: "Response time above", unit: "ms", range: 1...60_000, defaultValue: 100, step: 10)),
        .init(id: .primaryUnreachable, source: .guarding, lifecycle: .condition,
              title: "Primary becomes unreachable", summary: "The owner of a guarded service stops renewing and nobody takes over.",
              symbol: "bolt.horizontal.circle", subjectNoun: "service",
              thresholds: [.immediately, .afterSeconds], defaultThreshold: .after(15),
              defaultSeverity: .critical, basis: .authoritativeLease,
              sampleTitle: "SwiftBot is down", sampleDetail: "Home Mac stopped renewing and no other server has taken over.",
              sampleRecoveryTitle: "SwiftBot is back"),
        .init(id: .failoverCompleted, source: .guarding, lifecycle: .event,
              title: "Failover completed", summary: "Another server took over a guarded service after its owner stopped renewing.",
              symbol: "arrow.triangle.swap", subjectNoun: "service",
              thresholds: [], defaultThreshold: .immediately, defaultSeverity: .warning, basis: .authoritativeLease,
              sampleTitle: "SwiftBot failed over", sampleDetail: "Ownership moved from Home Mac to Backup Mac.",
              sampleRecoveryTitle: ""),
        .init(id: .ownershipTransferred, source: .guarding, lifecycle: .event,
              title: "Ownership transferred", summary: "A guarded service changes owner, including planned hand-offs.",
              symbol: "arrow.left.arrow.right", subjectNoun: "service",
              thresholds: [], defaultThreshold: .immediately, defaultSeverity: .info, basis: .authoritativeLease,
              sampleTitle: "SwiftBot is now owned by Backup Mac", sampleDetail: "Previously Home Mac.",
              sampleRecoveryTitle: ""),
        .init(id: .nodeDegraded, source: .operationalStatus, lifecycle: .condition,
              title: "Server readiness degrades", summary: "A server that was ready reports a problem, or stops reporting.",
              symbol: "stethoscope", subjectNoun: "server",
              thresholds: [.immediately, .afterSeconds], defaultThreshold: .immediately,
              defaultSeverity: .warning, basis: .applicationReported,
              sampleTitle: "Backup Mac needs attention", sampleDetail: "SwiftBot · SwiftBot reported a degraded operational condition.",
              sampleRecoveryTitle: "Backup Mac is operationally ready"),
        .init(id: .protectionImpaired, source: .operationalStatus, lifecycle: .condition,
              title: "Failover protection is impaired", summary: "The Primary owns the service but no previously ready standby is ready.",
              symbol: "shield.slash", subjectNoun: "service",
              thresholds: [.immediately, .afterSeconds], defaultThreshold: .immediately,
              defaultSeverity: .critical, basis: .ruruObserved,
              sampleTitle: "SwiftBot failover protection is impaired",
              sampleDetail: "The Primary still owns the service, but no previously-ready standby is operationally ready.",
              sampleRecoveryTitle: "SwiftBot failover protection is restored"),
        .init(id: .participantOnBattery, source: .coordination, lifecycle: .condition,
              title: "Server runs on battery", summary: "A server reports that its UPS is supplying power.",
              symbol: "bolt.trianglebadge.exclamationmark", subjectNoun: "server",
              thresholds: [.immediately, .afterSeconds], defaultThreshold: .immediately,
              defaultSeverity: .warning, basis: .applicationReported,
              sampleTitle: "Home Mac: UPS on battery", sampleDetail: "The UPS is supplying power.",
              sampleRecoveryTitle: "Home Mac: Power restored"),
        .init(id: .participantLowBattery, source: .coordination, lifecycle: .event,
              title: "Server battery is low", summary: "A server's battery falls to 20% or less on battery power.",
              symbol: "battery.0percent", subjectNoun: "server",
              thresholds: [], defaultThreshold: .immediately, defaultSeverity: .critical, basis: .applicationReported,
              sampleTitle: "Home Mac: Battery low", sampleDetail: "Battery is at 18%.", sampleRecoveryTitle: ""),
        .init(id: .participantSessionEnding, source: .coordination, lifecycle: .event,
              title: "Server session is ending", summary: "A server reports a planned logout or power-off.",
              symbol: "bolt.shield", subjectNoun: "server",
              thresholds: [], defaultThreshold: .immediately, defaultSeverity: .warning, basis: .applicationReported,
              sampleTitle: "Home Mac: Session ending soon", sampleDetail: "The participant reports a planned session end.",
              sampleRecoveryTitle: ""),
        .init(id: .serviceStopped, source: .authority, lifecycle: .condition,
              title: "Ruru's service stops", summary: "Ruru's listener is unavailable, so servers cannot renew.",
              symbol: "stop.circle", subjectNoun: "Ruru",
              thresholds: [.immediately, .afterSeconds], defaultThreshold: .immediately,
              defaultSeverity: .critical, basis: .ruruObserved,
              sampleTitle: "Ruru's service stopped", sampleDetail: "The ownership database is unavailable.",
              sampleRecoveryTitle: "Ruru's service is running again"),
        .init(id: .snapshotFailed, source: .authority, lifecycle: .condition,
              title: "Ruru cannot save a snapshot", summary: "Ruru's automatic ownership snapshot failed.",
              symbol: "externaldrive.badge.exclamationmark", subjectNoun: "Ruru",
              thresholds: [.immediately, .afterSeconds], defaultThreshold: .immediately,
              defaultSeverity: .critical, basis: .ruruObserved,
              sampleTitle: "Ruru could not save a snapshot", sampleDetail: "The backup folder is unavailable.",
              sampleRecoveryTitle: "Ruru saved a snapshot"),
        .init(id: .internetAccessDown, source: .authority, lifecycle: .condition,
              title: "Ruru loses public connectivity", summary: "Ruru's public HTTPS endpoint is not reachable from the internet.",
              symbol: "globe.badge.chevron.backward", subjectNoun: "Ruru",
              thresholds: [.immediately, .afterSeconds], defaultThreshold: .after(30),
              defaultSeverity: .critical, basis: .ruruObserved,
              sampleTitle: "Ruru's Internet Access is down", sampleDetail: "The connector could not register.",
              sampleRecoveryTitle: "Ruru's Internet Access is back"),
        .init(id: .authorityRestarted, source: .authority, lifecycle: .event,
              title: "Ruru restarts", summary: "Ruru launched and its authority started a new epoch.",
              symbol: "arrow.clockwise.circle", subjectNoun: "Ruru",
              thresholds: [], defaultThreshold: .immediately, defaultSeverity: .info, basis: .ruruObserved,
              sampleTitle: "Ruru restarted", sampleDetail: "Ruru started and is waiting out any earlier leases.",
              sampleRecoveryTitle: "")
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
    public static func descriptor(for id: TriggerID) -> TriggerDescriptor? { byID[id] }
    public static func triggers(for source: AlertSource) -> [TriggerDescriptor] { all.filter { $0.source == source } }
}

// MARK: Rules

public struct Threshold: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        /// On the first fresh evidence.
        case immediately
        /// The producer's own confirmation (for a monitor, its failure threshold).
        case sourceDefault
        /// After the condition has held, with fresh evidence, for this many seconds.
        case afterSeconds
        /// After this many consecutive failing observations.
        case failedChecks

        public var title: String {
            switch self {
            case .immediately: "Immediately"
            case .sourceDefault: "Use the monitor's setting"
            case .afterSeconds: "After a duration"
            case .failedChecks: "After consecutive failed checks"
            }
        }
    }

    public static let secondsRange = 5...86_400
    public static let checksRange = 1...100

    public var kind: Kind
    public var value: Int

    public init(kind: Kind, value: Int = 0) { self.kind = kind; self.value = value }
    public static let immediately = Threshold(kind: .immediately)
    public static let sourceDefault = Threshold(kind: .sourceDefault)
    public static func after(_ seconds: Int) -> Threshold { .init(kind: .afterSeconds, value: seconds) }
    public static func failedChecks(_ count: Int) -> Threshold { .init(kind: .failedChecks, value: count) }

    public var isValid: Bool {
        switch kind {
        case .immediately, .sourceDefault: true
        case .afterSeconds: Self.secondsRange.contains(value)
        case .failedChecks: Self.checksRange.contains(value)
        }
    }

    public var label: String {
        switch kind {
        case .immediately: "Immediately"
        case .sourceDefault: "Using the monitor's own setting"
        case .afterSeconds: "After \(Self.durationText(value))"
        case .failedChecks: "After \(value) consecutive failed \(value == 1 ? "check" : "checks")"
        }
    }

    public static func durationText(_ seconds: Int) -> String {
        if seconds % 3600 == 0, seconds >= 3600 { let h = seconds / 3600; return "\(h) \(h == 1 ? "hour" : "hours")" }
        if seconds % 60 == 0, seconds >= 60 { let m = seconds / 60; return "\(m) \(m == 1 ? "minute" : "minutes")" }
        return "\(seconds) \(seconds == 1 ? "second" : "seconds")"
    }
}

/// Which subjects a rule applies to. Empty means every matching subject.
public struct AlertScope: Codable, Hashable, Sendable {
    public static let maxIDs = 64
    public var ids: Set<String>

    public init(ids: Set<String> = []) { self.ids = ids }
    public static let all = AlertScope()
    public var isAll: Bool { ids.isEmpty }

    public func matches(_ subject: SubjectRef) -> Bool {
        isAll || ids.contains(subject.id) || (subject.groupID.map(ids.contains) ?? false)
    }
}

/// Where a rule's notifications go. By default a rule follows the destinations
/// enabled in Settings, so enabling Discord later also covers existing rules.
public struct DeliveryChoice: Codable, Hashable, Sendable {
    public var useAllEnabled: Bool
    public var destinations: Set<AlertDestination>

    public init(useAllEnabled: Bool = true, destinations: Set<AlertDestination> = []) {
        self.useAllEnabled = useAllEnabled; self.destinations = destinations
    }
    public static let followSettings = DeliveryChoice()
}

public struct QuietHours: Codable, Hashable, Sendable {
    /// Minutes after local midnight, 0..<1440. A window may cross midnight.
    public var startMinute: Int
    public var endMinute: Int
    /// Critical alerts are still delivered during quiet hours.
    public var allowCritical: Bool

    public init(startMinute: Int, endMinute: Int, allowCritical: Bool = true) {
        self.startMinute = startMinute; self.endMinute = endMinute; self.allowCritical = allowCritical
    }

    public var isValid: Bool {
        (0..<1440).contains(startMinute) && (0..<1440).contains(endMinute) && startMinute != endMinute
    }

    public func contains(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return startMinute < endMinute
            ? (startMinute..<endMinute).contains(minute)
            : (minute >= startMinute || minute < endMinute)
    }
}

public struct AlertRule: Codable, Identifiable, Equatable, Sendable {
    public static let maxRules = 64
    public static let cooldownRange = 0...86_400
    public static let repeatRange = 60...86_400
    public static let currentSchema = 1

    public var id: UUID
    public var name: String
    public var enabled: Bool
    public var trigger: TriggerID
    public var scope: AlertScope
    public var threshold: Threshold
    /// For triggers that compare a measurement (such as response time) with a limit.
    public var limit: Int?
    public var delivery: DeliveryChoice
    /// Show this rule's activity in the Activity page. Alert history is always kept.
    public var recordActivity: Bool
    public var notifyOnRecovery: Bool
    /// Overrides the trigger's default severity.
    public var severity: AlertSeverity?
    public var cooldownSeconds: Int
    public var repeatSeconds: Int?
    public var quietHours: QuietHours?
    /// Identifies a rule Ruru provisioned from a template; nil for user-created rules.
    public var templateID: String?
    public var templateVersion: Int?
    public var schemaVersion: Int

    public init(id: UUID = UUID(), name: String, enabled: Bool = true, trigger: TriggerID, scope: AlertScope = .all,
                threshold: Threshold? = nil, limit: Int? = nil, delivery: DeliveryChoice = .followSettings, recordActivity: Bool = true,
                notifyOnRecovery: Bool? = nil, severity: AlertSeverity? = nil, cooldownSeconds: Int = 0,
                repeatSeconds: Int? = nil, quietHours: QuietHours? = nil, templateID: String? = nil,
                templateVersion: Int? = nil) {
        let descriptor = TriggerCatalogue.descriptor(for: trigger)
        self.id = id; self.name = name; self.enabled = enabled; self.trigger = trigger; self.scope = scope
        self.threshold = threshold ?? descriptor?.defaultThreshold ?? .immediately
        self.limit = descriptor?.limit == nil ? nil : (limit ?? descriptor?.limit?.defaultValue)
        self.delivery = delivery; self.recordActivity = recordActivity
        self.notifyOnRecovery = notifyOnRecovery ?? (descriptor?.supportsRecovery ?? false)
        self.severity = severity; self.cooldownSeconds = cooldownSeconds; self.repeatSeconds = repeatSeconds
        self.quietHours = quietHours; self.templateID = templateID; self.templateVersion = templateVersion
        self.schemaVersion = Self.currentSchema
    }

    public var descriptor: TriggerDescriptor? { TriggerCatalogue.descriptor(for: trigger) }

    public func effectiveSeverity(_ descriptor: TriggerDescriptor) -> AlertSeverity { severity ?? descriptor.defaultSeverity }

    /// A rule is valid when its trigger exists and every option suits that trigger.
    public var validationProblem: String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, name.utf8.count <= 120, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            return "Give the rule a short name on one line."
        }
        guard let descriptor else { return "This rule's trigger is not available in this version of Ruru." }
        guard threshold.isValid else { return "Choose a valid threshold." }
        if let spec = descriptor.limit {
            guard let limit, spec.range.contains(limit) else {
                return "Choose a limit between \(spec.range.lowerBound) and \(spec.range.upperBound) \(spec.unit)."
            }
        } else if limit != nil { return "This trigger has no limit." }
        if descriptor.lifecycle == .condition {
            guard descriptor.thresholds.contains(threshold.kind) else { return "That threshold doesn't apply to this trigger." }
        } else if threshold != .immediately {
            return "Event triggers fire immediately."
        }
        guard Self.cooldownRange.contains(cooldownSeconds) else { return "Choose a cooldown up to 24 hours." }
        if let repeatSeconds {
            guard descriptor.lifecycle == .condition, Self.repeatRange.contains(repeatSeconds) else {
                return "Repeat reminders apply to conditions, every 1 minute to 24 hours."
            }
        }
        if let quietHours, !quietHours.isValid { return "Choose different start and end times for quiet hours." }
        guard scope.ids.count <= AlertScope.maxIDs, scope.ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            return "Choose fewer targets."
        }
        return nil
    }

    public var isValid: Bool { validationProblem == nil }

    /// Removes options that cannot apply to the trigger's lifecycle, so an event
    /// rule never carries a recovery or threshold setting.
    public func normalized() -> AlertRule {
        var rule = self
        rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let descriptor else { return rule }
        rule.limit = descriptor.limit == nil ? nil : (rule.limit ?? descriptor.limit?.defaultValue)
        if descriptor.lifecycle == .event {
            rule.threshold = .immediately; rule.notifyOnRecovery = false; rule.repeatSeconds = nil
        } else if !descriptor.thresholds.contains(rule.threshold.kind) {
            rule.threshold = descriptor.defaultThreshold
        }
        return rule
    }
}

// MARK: Incidents and history

public enum IncidentResolution: String, Codable, Sendable {
    /// Fresh observations established that the condition ended.
    case recovered
    /// Closed without evidence of recovery; never produces a recovery notification.
    case ruleDisabled, ruleRemoved, ruleChanged, subjectRemoved

    public var isRecovery: Bool { self == .recovered }
    public var title: String {
        switch self {
        case .recovered: "Recovered"
        case .ruleDisabled: "Archived — rule disabled"
        case .ruleRemoved: "Archived — rule removed"
        case .ruleChanged: "Archived — rule no longer applies"
        case .subjectRemoved: "Archived — target removed or paused"
        }
    }
}

public struct AlertIncident: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case open, resolved }
    public enum Verification: String, Codable, Sendable {
        /// Fresh evidence in this run supports the incident.
        case verified
        /// Carried over from before a restart; nothing fresh has confirmed it yet.
        case unverified
    }

    public var id: String
    public var ruleID: UUID
    public var ruleName: String
    public var trigger: TriggerID
    public var subject: SubjectRef
    public var severity: AlertSeverity
    public var basis: AlertBasis
    public var state: State
    public var resolution: IncidentResolution?
    public var verification: Verification
    public var title: String
    public var detail: String
    public var openedAt: Date
    public var stateChangedAt: Date
    public var resolvedAt: Date?
    public var lastNotifiedAt: Date?
    public var notificationCount: Int
    public var flapCount: Int
    public var flapping: Bool
    /// A down notice was delivered and no recovery notice has followed.
    public var noticeOutstanding: Bool
    /// The open notice was held back (cooldown or quiet hours) and is still owed.
    public var needsOpenNotice: Bool

    public var isOpen: Bool { state == .open }

    public init(id: String = UUID().uuidString.lowercased(), ruleID: UUID, ruleName: String, trigger: TriggerID,
                subject: SubjectRef, severity: AlertSeverity, basis: AlertBasis, state: State = .open,
                resolution: IncidentResolution? = nil, verification: Verification = .verified, title: String,
                detail: String, openedAt: Date, stateChangedAt: Date? = nil, resolvedAt: Date? = nil,
                lastNotifiedAt: Date? = nil, notificationCount: Int = 0, flapCount: Int = 0, flapping: Bool = false,
                noticeOutstanding: Bool = false, needsOpenNotice: Bool = false) {
        self.id = id; self.ruleID = ruleID; self.ruleName = ruleName; self.trigger = trigger; self.subject = subject
        self.severity = severity; self.basis = basis; self.state = state; self.resolution = resolution
        self.verification = verification; self.title = title; self.detail = detail; self.openedAt = openedAt
        self.stateChangedAt = stateChangedAt ?? openedAt; self.resolvedAt = resolvedAt; self.lastNotifiedAt = lastNotifiedAt
        self.notificationCount = notificationCount; self.flapCount = flapCount; self.flapping = flapping
        self.noticeOutstanding = noticeOutstanding; self.needsOpenNotice = needsOpenNotice
    }
}

public struct DeliveryOutcome: Codable, Equatable, Sendable {
    public var destination: AlertDestination
    public var ok: Bool
    public var message: String?
    public var time: Date
    public var retryable: Bool

    public init(destination: AlertDestination, ok: Bool, message: String? = nil, time: Date = Date(), retryable: Bool = false) {
        self.destination = destination; self.ok = ok; self.message = message; self.time = time; self.retryable = retryable
    }
}

public struct AlertHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case opened, recovered, event, reminder, flapping, stable, archived, suppressed

        public var title: String {
            switch self {
            case .opened: "Opened"
            case .recovered: "Recovered"
            case .event: "Triggered"
            case .reminder: "Reminder"
            case .flapping: "Flapping"
            case .stable: "Stable again"
            case .archived: "Archived"
            case .suppressed: "Suppressed"
            }
        }
    }

    public var id: Int64
    public var time: Date
    public var ruleID: UUID
    public var ruleName: String
    public var incidentID: String?
    public var trigger: TriggerID
    public var subjectName: String
    public var kind: Kind
    public var title: String
    public var detail: String
    public var severity: AlertSeverity
    public var showInActivity: Bool
    /// Why a notification was withheld, such as "cooldown" or "quiet hours".
    public var suppressedReason: String?
    public var deliveries: [DeliveryOutcome]

    public init(id: Int64, time: Date, ruleID: UUID, ruleName: String, incidentID: String? = nil, trigger: TriggerID,
                subjectName: String, kind: Kind, title: String, detail: String, severity: AlertSeverity,
                showInActivity: Bool = true, suppressedReason: String? = nil, deliveries: [DeliveryOutcome] = []) {
        self.id = id; self.time = time; self.ruleID = ruleID; self.ruleName = ruleName; self.incidentID = incidentID
        self.trigger = trigger; self.subjectName = subjectName; self.kind = kind; self.title = title; self.detail = detail
        self.severity = severity; self.showInActivity = showInActivity; self.suppressedReason = suppressedReason
        self.deliveries = deliveries
    }
}

/// A notification ready for the dispatcher.
public struct OutgoingNotification: Sendable, Equatable {
    public var entryID: Int64
    public var ruleID: UUID
    public var ruleName: String
    public var trigger: TriggerID
    public var kind: AlertHistoryEntry.Kind
    public var title: String
    public var body: String
    public var severity: AlertSeverity
    public var basis: AlertBasis
    public var subjectName: String
    public var groupName: String?
    public var choice: DeliveryChoice
}

/// Evidence that a condition has held, persisted so a restart does not discard it.
public struct EvidenceRecord: Codable, Equatable, Sendable {
    public var ruleID: UUID
    public var subjectKey: String
    public var since: Date
    public var lastFreshAt: Date
    public var count: Int
}

// MARK: Monitoring rollups

public struct UptimeSummary: Equatable, Sendable {
    public var checks: Int
    public var ok: Int
    public var inconclusive: Int
    public var averageLatencyMilliseconds: Int?

    public static let empty = UptimeSummary(checks: 0, ok: 0, inconclusive: 0, averageLatencyMilliseconds: nil)
    /// Share of conclusive checks that succeeded, or nil when there are none.
    public var ratio: Double? { checks == 0 ? nil : Double(ok) / Double(checks) }
}

public struct RollupSample: Sendable, Equatable {
    public var targetID: String
    public var time: Date
    public var ok: Bool
    public var inconclusive: Bool
    public var latencyMilliseconds: Int?

    public init(targetID: String, time: Date, ok: Bool, inconclusive: Bool, latencyMilliseconds: Int?) {
        self.targetID = targetID; self.time = time; self.ok = ok
        self.inconclusive = inconclusive; self.latencyMilliseconds = latencyMilliseconds
    }
}

