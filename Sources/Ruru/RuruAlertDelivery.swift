import Foundation
import RuruAlerting
import UserNotifications

/// Sends alerts to macOS notifications and optional external destinations.
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

    /// Returns destination-specific failures without preventing other deliveries.
    func deliver(_ alerts: [RuruAlert], preferences: RuruAlertPreferences, webhook: URL?, notifyID: String = "", notifyToken: String? = nil) async -> String? {
        var failures: [String] = []
        let now = Date()
        for alert in alerts where alert.isEnabled(in: preferences) {
            let identity = "\(alert.kind)|\(alert.key)"
            if alert.kind != .test, let previous = lastSent[identity], now.timeIntervalSince(previous) < 60 { continue }
            lastSent[identity] = now
            if preferences.notifications { await notify(alert) }
            if preferences.discord || alert.kind == .test, let webhook {
                do { try await post(alert, to: webhook, at: now) }
                catch { failures.append("Discord: \(error.localizedDescription)") }
            }
            if (preferences.notify || alert.kind == .test), let notifyToken, !notifyID.isEmpty {
                do { try await post(alert, toNotifyID: notifyID, token: notifyToken) }
                catch { failures.append("Notify!: \(error.localizedDescription)") }
            }
        }
        return failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Where an alert can go right now.
    struct Credentials: Sendable {
        var webhook: URL?
        var notifyID: String
        var notifyToken: String?
    }

    /// Delivers one alert to one destination for an alert rule and reports the outcome.
    /// Rules choose destinations themselves, so this applies no preference gate and no
    /// repeat suppression; the rule engine owns cooldowns. Nothing here throws.
    func send(_ alert: RuruAlert, to destination: AlertDestination, credentials: Credentials) async -> DeliveryOutcome {
        switch destination {
        case .macOS:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .denied {
                return DeliveryOutcome(destination: .macOS, ok: false,
                                       message: "macOS notifications are turned off for Ruru in System Settings → Notifications.")
            }
            await notify(alert)
            return DeliveryOutcome(destination: .macOS, ok: true)
        case .discord:
            guard let webhook = credentials.webhook else {
                return DeliveryOutcome(destination: .discord, ok: false, message: "Discord isn't set up.")
            }
            do { try await post(alert, to: webhook, at: Date()); return DeliveryOutcome(destination: .discord, ok: true) }
            catch { return failure(.discord, error) }
        case .notify:
            guard let token = credentials.notifyToken, !credentials.notifyID.isEmpty else {
                return DeliveryOutcome(destination: .notify, ok: false, message: "Notify! isn't set up.")
            }
            do { try await post(alert, toNotifyID: credentials.notifyID, token: token); return DeliveryOutcome(destination: .notify, ok: true) }
            catch { return failure(.notify, error) }
        }
    }

    private func failure(_ destination: AlertDestination, _ error: Error) -> DeliveryOutcome {
        let message = error.localizedDescription
        // Network problems and rate limits are worth one more try; a rejected webhook is not.
        let transient = error is URLError || message.contains("rate-limiting")
        return DeliveryOutcome(destination: destination, ok: false, message: message, retryable: transient)
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

    private func post(_ alert: RuruAlert, toNotifyID id: String, token: String) async throws {
        let request = try RuruNotify.request(for: alert, id: id, token: token)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw RuruBackup.Failure(status == 429
                ? "Notify! is rate-limiting alerts. They will resume shortly."
                : "Notify! rejected the alert (HTTP \(status)). Check the destination and token.")
        }
    }
}
