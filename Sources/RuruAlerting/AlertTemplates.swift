import Foundation

/// What a user has actually set up. Default rules follow these, not an install type.
public struct AlertCapabilities: Sendable, Equatable {
    public var monitoring: Bool
    public var guarding: Bool
    public var internetAccess: Bool

    public init(monitoring: Bool = false, guarding: Bool = false, internetAccess: Bool = false) {
        self.monitoring = monitoring; self.guarding = guarding; self.internetAccess = internetAccess
    }
}

/// The fixed alert toggles earlier versions of Ruru offered. They decide whether a
/// provisioned default starts on, so nobody loses or gains notifications by upgrading.
public enum LegacyAlertKey: String, Sendable, CaseIterable {
    case serviceDown, failover, authorityProblems, participantStatus, operationalStatus, monitoring
}

public struct LegacyAlertPreferences: Sendable, Equatable {
    public var values: [LegacyAlertKey: Bool]

    public init(_ values: [LegacyAlertKey: Bool] = [:]) { self.values = values }
    public static let defaults = LegacyAlertPreferences([
        .serviceDown: true, .failover: true, .authorityProblems: true,
        .participantStatus: false, .operationalStatus: true, .monitoring: true
    ])
    func isOn(_ key: LegacyAlertKey) -> Bool { values[key] ?? Self.defaults.values[key] ?? true }
}

public struct AlertTemplate: Identifiable, Sendable {
    public enum Requirement: Sendable { case always, monitoring, guarding, guardingOrInternet, internetAccess }

    public let id: String
    public let version: Int
    public let name: String
    public let summary: String
    public let trigger: TriggerID
    public let requirement: Requirement
    public let legacy: LegacyAlertKey?
    /// Used when there is no legacy preference to follow.
    public let startsEnabled: Bool
    public let threshold: Threshold?
    public let severity: AlertSeverity?

    public func isAvailable(for capabilities: AlertCapabilities) -> Bool {
        switch requirement {
        case .always: true
        case .monitoring: capabilities.monitoring
        case .guarding: capabilities.guarding
        case .guardingOrInternet: capabilities.guarding || capabilities.internetAccess
        case .internetAccess: capabilities.internetAccess
        }
    }

    public var descriptor: TriggerDescriptor? { TriggerCatalogue.descriptor(for: trigger) }

    public func makeRule(enabled: Bool) -> AlertRule {
        AlertRule(name: name, enabled: enabled, trigger: trigger, threshold: threshold, severity: severity,
                  templateID: id, templateVersion: version)
    }
}

public enum AlertTemplates {
    public static let all: [AlertTemplate] = [
        .init(id: "default.monitor.unavailable", version: 1, name: "Endpoint unavailable",
              summary: "Tells you when a monitored website, Mac or service stops answering, and when it recovers.",
              trigger: .monitorUnavailable, requirement: .monitoring, legacy: .monitoring, startsEnabled: true,
              threshold: .sourceDefault, severity: nil),
        .init(id: "default.monitor.slowResponse", version: 1, name: "Slow response",
              summary: "A monitor's response time stays above a limit. Off by default; choose the limit and monitors.",
              trigger: .monitorSlow, requirement: .monitoring, legacy: nil, startsEnabled: false,
              threshold: .failedChecks(3), severity: nil),
        .init(id: "default.guarding.primaryUnreachable", version: 1, name: "Primary unreachable",
              summary: "A guarded service lost its owner and no other server took over.",
              trigger: .primaryUnreachable, requirement: .guarding, legacy: .serviceDown, startsEnabled: true,
              threshold: .after(15), severity: nil),
        .init(id: "default.guarding.failoverCompleted", version: 1, name: "Failover completed",
              summary: "Another server took over a guarded service.",
              trigger: .failoverCompleted, requirement: .guarding, legacy: .failover, startsEnabled: true,
              threshold: nil, severity: nil),
        .init(id: "default.guarding.ownershipTransferred", version: 1, name: "Ownership transferred",
              summary: "Any change of owner, including planned hand-offs. Off by default; failovers are covered above.",
              trigger: .ownershipTransferred, requirement: .guarding, legacy: nil, startsEnabled: false,
              threshold: nil, severity: nil),
        .init(id: "default.operational.nodeDegraded", version: 1, name: "Server readiness degraded",
              summary: "A server that was ready, such as a standby, reports a problem or stops reporting.",
              trigger: .nodeDegraded, requirement: .guarding, legacy: .operationalStatus, startsEnabled: true,
              threshold: nil, severity: nil),
        .init(id: "default.operational.protectionImpaired", version: 1, name: "Failover protection impaired",
              summary: "The Primary owns the service but no previously ready standby is ready to take over.",
              trigger: .protectionImpaired, requirement: .guarding, legacy: .operationalStatus, startsEnabled: true,
              threshold: nil, severity: nil),
        .init(id: "default.authority.serviceStopped", version: 1, name: "Ruru service stopped",
              summary: "Ruru's listener is unavailable, so servers cannot take or renew ownership.",
              trigger: .serviceStopped, requirement: .guardingOrInternet, legacy: .authorityProblems, startsEnabled: true,
              threshold: nil, severity: nil),
        .init(id: "default.authority.snapshotFailed", version: 1, name: "Ruru snapshot failed",
              summary: "Ruru could not save its automatic ownership snapshot.",
              trigger: .snapshotFailed, requirement: .guardingOrInternet, legacy: .authorityProblems, startsEnabled: true,
              threshold: nil, severity: nil),
        .init(id: "default.authority.internetAccessDown", version: 1, name: "Ruru public connectivity lost",
              summary: "Ruru's public HTTPS endpoint is unreachable.",
              trigger: .internetAccessDown, requirement: .internetAccess, legacy: .authorityProblems, startsEnabled: true,
              threshold: nil, severity: nil),
        .init(id: "default.participant.onBattery", version: 1, name: "Server on battery",
              summary: "A server reports that its UPS is supplying power.",
              trigger: .participantOnBattery, requirement: .guarding, legacy: .participantStatus, startsEnabled: false,
              threshold: nil, severity: nil),
        .init(id: "default.participant.lowBattery", version: 1, name: "Server battery low",
              summary: "A server on battery power falls to 20% or less.",
              trigger: .participantLowBattery, requirement: .guarding, legacy: .participantStatus, startsEnabled: false,
              threshold: nil, severity: nil),
        .init(id: "default.participant.sessionEnding", version: 1, name: "Server session ending",
              summary: "A server reports a planned logout or power-off.",
              trigger: .participantSessionEnding, requirement: .guarding, legacy: .participantStatus, startsEnabled: false,
              threshold: nil, severity: nil),
        .init(id: "default.authority.restarted", version: 1, name: "Ruru restarted",
              summary: "Ruru launched and its authority started a new epoch. Off by default.",
              trigger: .authorityRestarted, requirement: .guarding, legacy: nil, startsEnabled: false,
              threshold: nil, severity: nil)
    ]

    public static func template(_ id: String) -> AlertTemplate? { all.first { $0.id == id } }

    /// Adds the default rules a user's configured capabilities call for, once each.
    /// Existing rules are never modified, and a template already provisioned is not
    /// offered again even if its rule was since deleted or disabled.
    @discardableResult
    public static func provision(into file: inout AlertRulesFile, capabilities: AlertCapabilities,
                                 legacy: LegacyAlertPreferences) -> [AlertRule] {
        var added: [AlertRule] = []
        for template in all where template.isAvailable(for: capabilities) && !file.provisioned.contains(template.id) {
            // A rule that already carries this template ID (restored or imported) counts as provisioned.
            file.provisioned.append(template.id)
            guard !file.rules.contains(where: { $0.templateID == template.id }), file.rules.count < AlertRule.maxRules else { continue }
            let enabled = template.legacy.map(legacy.isOn) ?? template.startsEnabled
            let rule = template.makeRule(enabled: enabled)
            file.rules.append(rule)
            added.append(rule)
        }
        return added
    }
}
