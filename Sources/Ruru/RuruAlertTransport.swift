import Foundation
import RuruAlerting

/// Connects the alert engine's dispatcher to Ruru's existing macOS, Discord and
/// Notify! delivery. Credentials are read at send time, so a webhook replaced in
/// Settings applies immediately and no secret is held by the alert engine.
struct RuruAlertTransport: AlertTransport {
    let delivery: RuruAlertDelivery
    let credentials: @Sendable @MainActor () -> RuruAlertDelivery.Credentials

    func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome {
        let credentials = await credentials()
        return await delivery.send(Self.alert(for: notification), to: destination, credentials: credentials)
    }

    static func alert(for notification: OutgoingNotification) -> RuruAlert {
        let severity: RuruAlert.Severity
        switch notification.kind {
        case .recovered, .stable: severity = .resolved
        default:
            switch notification.severity {
            case .critical: severity = .critical
            case .warning: severity = .warning
            case .info: severity = .info
            }
        }
        return RuruAlert(kind: .rule, key: "\(notification.ruleID.uuidString)|\(notification.entryID)",
                         title: notification.title, detail: notification.body,
                         context: notification.groupName.map { .init(service: $0, server: notification.subjectName) },
                         severityOverride: severity, basisLabel: notification.basis.label)
    }
}
