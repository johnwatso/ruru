import Foundation
import UserNotifications

/// Sends alerts to macOS notifications and, when configured, a Discord webhook.
/// Repeats of the same alert within a minute are dropped so a flapping server
/// cannot flood a channel. The webhook URL is a secret and is never logged.
@MainActor
final class RuruAlertDelivery {
    private var lastSent: [String: Date] = [:]
    private var requestedAuthorization = false
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        return URLSession(configuration: configuration)
    }()

    /// Returns a description of the last Discord failure, if any.
    func deliver(_ alerts: [RuruAlert], preferences: RuruAlertPreferences, webhook: URL?) async -> String? {
        var failure: String?
        let now = Date()
        for alert in alerts where alert.isEnabled(in: preferences) {
            let identity = "\(alert.kind)|\(alert.key)"
            if alert.kind != .test, let previous = lastSent[identity], now.timeIntervalSince(previous) < 60 { continue }
            lastSent[identity] = now
            if preferences.notifications { await notify(alert) }
            if preferences.discord || alert.kind == .test, let webhook {
                do { try await post(alert, to: webhook, at: now) }
                catch { failure = error.localizedDescription }
            }
        }
        return failure
    }

    private func notify(_ alert: RuruAlert) async {
        let center = UNUserNotificationCenter.current()
        if !requestedAuthorization {
            requestedAuthorization = true
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.detail
        if alert.severity == .critical { content.sound = .default }
        try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func post(_ alert: RuruAlert, to webhook: URL, at date: Date) async throws {
        var request = URLRequest(url: webhook)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Ruru", forHTTPHeaderField: "User-Agent")
        request.httpBody = try RuruDiscordWebhook.payload(for: alert, at: date)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RuruBackup.Failure(status == 429
                ? "Discord is rate-limiting this webhook. Alerts will resume shortly."
                : "Discord rejected the alert (HTTP \(status)). Check the webhook still exists.")
        }
    }
}
