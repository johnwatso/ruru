import Foundation
import XCTest

final class AlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func observe(_ owners: [String: String], running: Bool = true, recovering: Bool = false,
                         releases: Set<String> = [], tunnel: String? = nil) -> RuruAlertMonitor.Observation {
        .init(serviceRunning: running, recovering: recovering, serviceFailure: nil, tunnelError: tunnel,
              snapshotError: nil, owners: owners, services: ["bot": "SwiftBot", "media": "Media"], releases: releases)
    }

    func testAnOwnerThatStopsRenewingIsDownAfterTheGraceAndBackWhenOwnershipReturns() {
        var monitor = RuruAlertMonitor()
        XCTAssertTrue(monitor.observe(observe(["bot": "Home Mac"]), at: start).isEmpty)
        XCTAssertTrue(monitor.observe(observe([:]), at: start + 1).isEmpty)
        XCTAssertTrue(monitor.observe(observe([:]), at: start + 10).isEmpty)
        let down = monitor.observe(observe([:]), at: start + 16)
        XCTAssertEqual(down.map(\.kind), [.serviceDown])
        XCTAssertEqual(down.first?.title, "SwiftBot is down")
        XCTAssertTrue(down.first?.detail.contains("Home Mac") == true)
        XCTAssertTrue(monitor.observe(observe([:]), at: start + 60).isEmpty, "Down is reported once")
        XCTAssertEqual(monitor.observe(observe(["bot": "Home Mac"]), at: start + 70).map(\.kind), [.serviceRecovered])
    }

    func testATakeoverWithinTheGraceIsAFailoverNotAnOutage() {
        var monitor = RuruAlertMonitor()
        _ = monitor.observe(observe(["bot": "Home Mac"]), at: start)
        _ = monitor.observe(observe([:]), at: start + 1)
        let failover = monitor.observe(observe(["bot": "Backup Mac"]), at: start + 5)
        XCTAssertEqual(failover.map(\.kind), [.failover])
        XCTAssertEqual(failover.first?.detail, "Ownership moved from Home Mac to Backup Mac.")
        XCTAssertTrue(monitor.observe(observe(["bot": "Backup Mac"]), at: start + 30).isEmpty)
    }

    func testPlannedReleasesStopsAndRestartsNeverAlert() {
        var monitor = RuruAlertMonitor()
        _ = monitor.observe(observe(["bot": "Home Mac"], releases: ["bot|1"]), at: start)
        XCTAssertTrue(monitor.observe(observe(["bot": "Backup Mac"], releases: ["bot|1", "bot|2"]), at: start + 1).isEmpty)
        _ = monitor.observe(observe([:], releases: ["bot|1", "bot|2", "bot|3"]), at: start + 2)
        XCTAssertTrue(monitor.observe(observe([:], releases: ["bot|1", "bot|2", "bot|3"]), at: start + 60).isEmpty)

        _ = monitor.observe(observe(["media": "Server"]), at: start + 61)
        XCTAssertTrue(monitor.observe(observe([:], running: false), at: start + 62).isEmpty)
        XCTAssertTrue(monitor.observe(observe([:], recovering: true), at: start + 90).isEmpty)
        XCTAssertTrue(monitor.observe(observe([:]), at: start + 200).isEmpty)
    }

    func testAuthorityProblemsAlertOnceAndResolve() {
        var monitor = RuruAlertMonitor()
        let failing = monitor.observe(observe([:], tunnel: "Cloudflare is unreachable."), at: start)
        XCTAssertEqual(failing.map(\.kind), [.authorityProblem])
        XCTAssertEqual(failing.first?.detail, "Cloudflare is unreachable.")
        XCTAssertTrue(monitor.observe(observe([:], tunnel: "Cloudflare is unreachable."), at: start + 1).isEmpty)
        let resolved = monitor.observe(observe([:]), at: start + 2)
        XCTAssertEqual(resolved.map(\.kind), [.authorityRecovered])
        XCTAssertEqual(resolved.first?.title, "Ruru's Internet Access is back")
    }

    func testPreferencesFilterAlertKinds() {
        var preferences = RuruAlertPreferences()
        preferences.failover = false
        let failover = RuruAlert(kind: .failover, key: "k", title: "t", detail: "d")
        let down = RuruAlert(kind: .serviceDown, key: "k", title: "t", detail: "d")
        XCTAssertFalse(failover.isEnabled(in: preferences))
        XCTAssertTrue(down.isEnabled(in: preferences))
        let decoded = try? JSONDecoder().decode(RuruAlertPreferences.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, RuruAlertPreferences())
    }

    func testOnlyGenuineDiscordWebhookURLsAreAccepted() {
        let secret = String(repeating: "aB3_-", count: 13)
        XCTAssertNotNil(RuruDiscordWebhook.validated("https://discord.com/api/webhooks/123456789012345678/\(secret)"))
        XCTAssertNotNil(RuruDiscordWebhook.validated(" https://canary.discord.com/api/webhooks/1/\(secret) "))
        for invalid in [
            "http://discord.com/api/webhooks/1/\(secret)",
            "https://discord.com.evil.example/api/webhooks/1/\(secret)",
            "https://evil.example/api/webhooks/1/\(secret)",
            "https://user@discord.com/api/webhooks/1/\(secret)",
            "https://discord.com/api/webhooks/not-a-number/\(secret)",
            "https://discord.com/api/webhooks/1/short",
            "https://discord.com/api/webhooks/1/\(secret)/slack",
            "https://discord.com:8443/api/webhooks/1/\(secret)"
        ] {
            XCTAssertNil(RuruDiscordWebhook.validated(invalid), invalid)
        }
    }

    func testDiscordPayloadIsAnEmbedThatCannotMentionAnyone() throws {
        let alert = RuruAlert(kind: .serviceDown, key: "down|bot", title: "SwiftBot is down", detail: "@everyone Home Mac stopped renewing.")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: RuruDiscordWebhook.payload(for: alert, at: start)) as? [String: Any])
        XCTAssertEqual(json["username"] as? String, "Ruru")
        XCTAssertEqual((json["allowed_mentions"] as? [String: [String]])?["parse"], [])
        let embed = try XCTUnwrap((json["embeds"] as? [[String: Any]])?.first)
        XCTAssertEqual(embed["title"] as? String, "SwiftBot is down")
        XCTAssertEqual(embed["color"] as? Int, 0xE5484D)
        XCTAssertNil(json["content"])
    }
}
