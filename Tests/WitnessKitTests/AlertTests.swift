import Foundation
import XCTest
@testable import WitnessKit

final class AlertTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func observe(_ owners: [String: String], running: Bool = true, recovering: Bool = false,
                         releases: Set<String> = [], tunnel: String? = nil) -> RuruAlertMonitor.Observation {
        .init(serviceRunning: running, recovering: recovering, serviceFailure: nil, tunnelError: tunnel,
              snapshotError: nil, owners: owners.mapValues { .init(nodeID: $0, name: $0) },
              services: ["bot": "SwiftBot", "media": "Media"], releases: releases)
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
        XCTAssertEqual(down.first?.context, .init(service: "SwiftBot", previousOwner: "Home Mac"))
        XCTAssertTrue(monitor.observe(observe([:]), at: start + 60).isEmpty, "Down is reported once")
        let recovered = monitor.observe(observe(["bot": "Home Mac"]), at: start + 70)
        XCTAssertEqual(recovered.map(\.kind), [.serviceRecovered])
        XCTAssertEqual(recovered.first?.context, .init(service: "SwiftBot", currentOwner: "Home Mac"))
    }

    func testATakeoverWithinTheGraceIsAFailoverNotAnOutage() throws {
        var monitor = RuruAlertMonitor()
        _ = monitor.observe(observe(["bot": "Home Mac"]), at: start)
        _ = monitor.observe(observe([:]), at: start + 1)
        let failover = monitor.observe(observe(["bot": "Backup Mac"]), at: start + 5)
        XCTAssertEqual(failover.map(\.kind), [.failover])
        XCTAssertEqual(failover.first?.detail, "Ownership moved from Home Mac to Backup Mac.")
        let alert = try XCTUnwrap(failover.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: RuruDiscordWebhook.payload(for: alert, at: start)) as? [String: Any])
        let embed = try XCTUnwrap((json["embeds"] as? [[String: Any]])?.first)
        XCTAssertEqual(embed["description"] as? String, "Another server has taken over ownership.")
        let fields = try XCTUnwrap(embed["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.compactMap { $0["name"] as? String }, ["Service", "Previous owner", "Current owner"])
        XCTAssertEqual(fields.compactMap { $0["value"] as? String }, ["SwiftBot", "Home Mac", "Backup Mac"])
        XCTAssertEqual(fields.compactMap { $0["inline"] as? Bool }, [false, true, true])
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

    func testOperationalStandbyDegradationAlertsAndRestoresFailoverProtection() {
        var monitor = OperationalAlertMonitor()
        let participant = ParticipantObservation(clusterID: "bot", nodeID: "backup", nodeName: "Backup Mac",
                                                 role: .standby, ageSeconds: 0, fresh: true)
        func status(_ state: OperationalState) -> OperationalStatusObservation {
            .init(clusterID: "bot", nodeID: "backup", nodeName: "Backup Mac", state: state,
                  components: [], ageSeconds: 0, fresh: true)
        }
        let first = monitor.observe([status(.ready)], participants: [participant], owners: ["bot"],
                                    serviceNames: ["bot": "SwiftBot"], at: start)
        XCTAssertTrue(first.alerts.isEmpty, "The first report establishes the baseline")
        XCTAssertEqual(first.events.map(\.kind), [.operationalReady])

        let degraded = monitor.observe([status(.degraded)], participants: [participant], owners: ["bot"],
                                       serviceNames: ["bot": "SwiftBot"], at: start + 15)
        XCTAssertEqual(degraded.alerts.map(\.kind), [.operationalDegraded, .failoverProtectionImpaired])
        XCTAssertEqual(degraded.events.map(\.kind), [.operationalDegraded, .failoverProtectionImpaired])
        XCTAssertTrue(degraded.alerts.last?.detail.contains("Primary still owns") == true)

        let recovered = monitor.observe([status(.ready)], participants: [participant], owners: ["bot"],
                                        serviceNames: ["bot": "SwiftBot"], at: start + 30)
        XCTAssertEqual(recovered.alerts.map(\.kind), [.operationalRecovered, .failoverProtectionRestored])
        XCTAssertEqual(recovered.events.map(\.kind), [.operationalReady, .failoverProtectionRestored])
    }

    func testOperationalStatusStalenessIsRecordedAsRuruObservedNotClientReported() {
        var monitor = OperationalAlertMonitor()
        let participant = ParticipantObservation(clusterID: "bot", nodeID: "backup", nodeName: "Backup Mac",
                                                 role: .standby, ageSeconds: 0, fresh: true)
        let ready = OperationalStatusObservation(clusterID: "bot", nodeID: "backup", nodeName: "Backup Mac",
                                                 state: .ready, components: [], ageSeconds: 0, fresh: true)
        _ = monitor.observe([ready], participants: [participant], owners: ["bot"],
                            serviceNames: ["bot": "SwiftBot"], at: start)
        let stale = OperationalStatusObservation(clusterID: "bot", nodeID: "backup", nodeName: "Backup Mac",
                                                 state: .ready, components: [], ageSeconds: 46, fresh: false)
        let result = monitor.observe([stale], participants: [participant], owners: ["bot"],
                                     serviceNames: ["bot": "SwiftBot"], at: start + 46)
        XCTAssertEqual(result.events.first?.kind, .operationalUnavailable)
        XCTAssertEqual(result.events.first?.detail, "Ruru observed that the operational report is stale or unavailable.")
        XCTAssertEqual(result.alerts.map(\.kind), [.operationalDegraded, .failoverProtectionImpaired])
    }

    func testFailoverUsesNodeIdentityAndTheNewOwnersWebsite() throws {
        var monitor = RuruAlertMonitor()
        var observation = observe([:])
        observation.owners = ["bot": .init(nodeID: "primary", name: "Mac", webUIURL: "https://primary.example.com")]
        _ = monitor.observe(observation, at: start)
        observation.owners = ["bot": .init(nodeID: "backup", name: "Mac", webUIURL: "https://failover.example.com")]
        let alert = try XCTUnwrap(monitor.observe(observation, at: start + 1).first)
        XCTAssertEqual(alert.kind, .failover, "Different nodes may have the same display name")
        XCTAssertEqual(alert.context?.webUIURL, "https://failover.example.com")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: RuruDiscordWebhook.payload(for: alert, at: start)) as? [String: Any])
        let embed = try XCTUnwrap((json["embeds"] as? [[String: Any]])?.first)
        let field = try XCTUnwrap((embed["fields"] as? [[String: Any]])?.last)
        XCTAssertEqual(field["name"] as? String, "Web UI")
        XCTAssertEqual(field["value"] as? String, "[failover.example.com](https://failover.example.com)")
        XCTAssertFalse(String(decoding: try RuruDiscordWebhook.payload(for: alert, at: start), as: UTF8.self).contains("primary.example.com"))
        observation.owners = ["bot": .init(nodeID: "backup", name: "Renamed Mac", webUIURL: "https://new.example.com")]
        XCTAssertTrue(monitor.observe(observation, at: start + 2).isEmpty, "Renaming or changing URL alone is not failover")
    }

    func testRecoveryLinksOnlyTheCurrentOwnerAndUnsafeWebsitesAreOmitted() throws {
        var monitor = RuruAlertMonitor()
        var observation = observe([:])
        observation.owners = ["bot": .init(nodeID: "primary", name: "Home Mac", webUIURL: "https://primary.example.com")]
        _ = monitor.observe(observation, at: start)
        observation.owners = [:]
        _ = monitor.observe(observation, at: start + 1)
        let down = try XCTUnwrap(monitor.observe(observation, at: start + 16).first)
        XCTAssertNil(down.context?.webUIURL)
        observation.owners = ["bot": .init(nodeID: "backup", name: "Backup Mac", webUIURL: "https://failover.example.com")]
        let recovered = try XCTUnwrap(monitor.observe(observation, at: start + 17).first)
        XCTAssertEqual(recovered.context?.webUIURL, "https://failover.example.com")
        for url in ["https://example.com?token=secret", "http://example.com"] {
            let unsafe = RuruAlert(kind: .failover, key: "k", title: "Failover", detail: "Changed owner.",
                                   context: .init(service: "App", webUIURL: url))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: RuruDiscordWebhook.payload(for: unsafe, at: start)) as? [String: Any])
            let embed = try XCTUnwrap((json["embeds"] as? [[String: Any]])?.first)
            XCTAssertFalse(((embed["fields"] as? [[String: Any]]) ?? []).contains { $0["name"] as? String == "Web UI" })
        }
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
        XCTAssertEqual(embed["title"] as? String, "⛔ SwiftBot is down")
        XCTAssertEqual(embed["color"] as? Int, 0xE5484D)
        XCTAssertEqual((embed["footer"] as? [String: String])?["text"], "Ruru • Guarding")
        XCTAssertEqual(embed["timestamp"] as? String, ISO8601DateFormatter().string(from: start))
        XCTAssertNil(embed["fields"], "Alerts without structured context still work")
        XCTAssertNil(json["content"])
    }

    func testDiscordFieldsKeepNamesLiteralAndOmitEmptyValuesAndInternalKeys() throws {
        let alert = RuruAlert(kind: .pairingRequest, key: "pair|private-request-id", title: "Pairing request",
                              detail: "Approve in Ruru.",
                              context: .init(service: "Media_*", server: "[Home](https://example.com)"))
        let data = try RuruDiscordWebhook.payload(for: alert, at: start)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let embed = try XCTUnwrap((json["embeds"] as? [[String: Any]])?.first)
        let fields = try XCTUnwrap(embed["fields"] as? [[String: Any]])
        XCTAssertEqual(fields.compactMap { $0["value"] as? String }, ["Media\\_\\*", "\\[Home\\](https://example.com)"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(alert.key))

        let empty = RuruAlert(kind: .test, key: "test", title: "Test", detail: "Connected.",
                              context: .init(service: " ", server: "\n"))
        let emptyJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: RuruDiscordWebhook.payload(for: empty, at: start)) as? [String: Any])
        XCTAssertNil((emptyJSON["embeds"] as? [[String: Any]])?.first?["fields"])
    }

    func testDiscordPayloadBoundsLongUnicodeNamesAndDetails() throws {
        let long = String(repeating: "👩🏽‍💻_*", count: 2_000)
        let alert = RuruAlert(kind: .authorityProblem, key: "k", title: long, detail: long,
                              context: .init(service: long, previousOwner: long, currentOwner: long, server: long))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: RuruDiscordWebhook.payload(for: alert, at: start)) as? [String: Any])
        let embed = try XCTUnwrap((json["embeds"] as? [[String: Any]])?.first)
        let title = try XCTUnwrap(embed["title"] as? String)
        let detail = try XCTUnwrap(embed["description"] as? String)
        let footer = try XCTUnwrap((embed["footer"] as? [String: String])?["text"])
        XCTAssertLessThanOrEqual(title.utf16.count, 256)
        XCTAssertLessThanOrEqual(detail.utf16.count, 2_000)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertTrue(detail.hasSuffix("…"))
        var total = title.utf16.count + detail.utf16.count + footer.utf16.count
        for field in try XCTUnwrap(embed["fields"] as? [[String: Any]]) {
            let name = try XCTUnwrap(field["name"] as? String)
            let value = try XCTUnwrap(field["value"] as? String)
            XCTAssertLessThanOrEqual(value.utf16.count, 512)
            XCTAssertFalse(value.contains("�"))
            total += name.utf16.count + value.utf16.count
        }
        XCTAssertLessThanOrEqual(total, 6_000)
    }
}
