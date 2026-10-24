import Foundation
import XCTest
@testable import RuruAlerting
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
        XCTAssertTrue(result.alerts.isEmpty, "Staleness is recorded immediately but notifications wait for confirmation")
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

// MARK: Signals for the rule engine

final class AlertSignalTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let service = GuardedService(id: "11111111-1111-4111-8111-111111111111", name: "SwiftBot", clusterID: "bot", kind: .swiftBot)

    private var subjects: RuruAlertSubjects { RuruAlertSubjects(services: [service]) }

    private func observe(_ owners: [String: String], running: Bool = true, recovering: Bool = false,
                         tunnel: String? = nil) -> RuruAlertMonitor.Observation {
        .init(serviceRunning: running, recovering: recovering, serviceFailure: nil, tunnelError: tunnel, snapshotError: nil,
              owners: owners.mapValues { .init(nodeID: $0, name: $0) }, services: ["bot": "SwiftBot"], releases: [])
    }

    private func unreachable(_ signals: [AlertSignal]) -> AlertSignal? { signals.first { $0.trigger == .primaryUnreachable } }

    func testOwnerLossIsAConditionThatStartsAtTheLossNotAtTheGracePeriod() {
        var monitor = RuruAlertMonitor()
        _ = monitor.observe(observe(["bot": "Home Mac"]), at: start)
        _ = monitor.observe(observe([:]), at: start + 1)
        let signal = unreachable(monitor.conditionSignals(subjects: subjects, at: start + 5))
        guard case .condition(.active(let evidence)) = signal?.shape else { return XCTFail("Expected an active condition") }
        XCTAssertEqual(evidence.since, start + 1, "The rule's own duration, not a fixed grace period, decides when to alert")
        XCTAssertEqual(signal?.basis, .authoritativeLease)
        XCTAssertEqual(signal?.subject.id, service.id, "Rules target the stable service ID")
        XCTAssertEqual(signal?.subject.kind, "service")
        // A takeover within the grace period clears the condition and is a failover.
        let alerts = monitor.observe(observe(["bot": "Backup Mac"]), at: start + 8)
        XCTAssertEqual(alerts.map(\.kind), [.failover])
        guard case .condition(.clear) = unreachable(monitor.conditionSignals(subjects: subjects, at: start + 8))?.shape else {
            return XCTFail("Expected the condition to clear")
        }
        let failover = RuruAlertSignals.failover(alerts[0], subjects: subjects, at: start + 8)
        XCTAssertEqual(failover?.trigger, .failoverCompleted)
        XCTAssertEqual(failover?.subject.id, service.id)
        XCTAssertEqual(failover?.shape, .event)
    }

    func testOwnershipIsNeverJudgedWhileStoppedOrInRestartQuarantine() {
        var monitor = RuruAlertMonitor()
        _ = monitor.observe(observe(["bot": "Home Mac"]), at: start)
        _ = monitor.observe(observe([:], recovering: true), at: start + 1)
        guard case .condition(.inconclusive) = unreachable(monitor.conditionSignals(subjects: subjects, at: start + 2))?.shape else {
            return XCTFail("Quarantine is not evidence about ownership")
        }
        _ = monitor.observe(observe([:], running: false), at: start + 3)
        guard case .condition(.inconclusive) = unreachable(monitor.conditionSignals(subjects: subjects, at: start + 4))?.shape else {
            return XCTFail("A stopped service is not evidence about ownership")
        }
    }

    func testAServiceWithNoOwnerIsNeverReportedAsRecovered() {
        var monitor = RuruAlertMonitor()
        // After a restart quarantine the loss history is gone and nobody owns the lease.
        _ = monitor.observe(observe([:], recovering: true), at: start)
        _ = monitor.observe(observe([:]), at: start + 1)
        guard case .condition(.inconclusive) = unreachable(monitor.conditionSignals(subjects: subjects, at: start + 2))?.shape else {
            return XCTFail("An unowned service must not clear an open down incident")
        }
        _ = monitor.observe(observe(["bot": "Home Mac"]), at: start + 3)
        let signal = unreachable(monitor.conditionSignals(subjects: subjects, at: start + 4))
        guard case .condition(.clear) = signal?.shape else { return XCTFail("A live owner clears the condition") }
        XCTAssertEqual(signal?.detail, "Home Mac now owns SwiftBot.")
    }

    func testAuthorityProblemsAreContinuousReadingsThatClearWhenResolved() {
        var monitor = RuruAlertMonitor()
        _ = monitor.observe(observe([:], tunnel: "Connector exited"), at: start)
        var signals = monitor.conditionSignals(subjects: subjects, at: start + 1)
        let tunnel = signals.first { $0.trigger == .internetAccessDown }
        guard case .condition(.active(let evidence)) = tunnel?.shape else { return XCTFail() }
        XCTAssertEqual(evidence.since, start)
        XCTAssertEqual(tunnel?.detail, "Connector exited")
        XCTAssertEqual(tunnel?.basis, .ruruObserved)
        guard case .condition(.clear) = signals.first(where: { $0.trigger == .serviceStopped })?.shape else { return XCTFail() }
        _ = monitor.observe(observe([:]), at: start + 30)
        signals = monitor.conditionSignals(subjects: subjects, at: start + 31)
        guard case .condition(.clear) = signals.first(where: { $0.trigger == .internetAccessDown })?.shape else { return XCTFail() }
    }

    func testReadinessConditionsDistinguishReportedFromObservedAndIgnoreNodesThatNeverWereReady() {
        var monitor = OperationalAlertMonitor()
        func report(_ state: OperationalState, fresh: Bool = true) -> OperationalStatusObservation {
            OperationalStatusObservation(clusterID: "bot", nodeID: "backup", nodeName: "Backup Mac", state: state,
                                         components: [], ageSeconds: fresh ? 1 : 100, fresh: fresh)
        }
        let standby = ParticipantObservation(clusterID: "bot", nodeID: "backup", nodeName: "Backup Mac", role: .standby, ageSeconds: 1, fresh: true)
        _ = monitor.observe([report(.synchronizing)], participants: [standby], owners: [], serviceNames: ["bot": "SwiftBot"], at: start)
        XCTAssertTrue(monitor.conditionSignals(subjects: subjects, at: start).filter { $0.trigger == .nodeDegraded }.isEmpty,
                      "A node that was never ready is not a degradation")
        _ = monitor.observe([report(.ready)], participants: [standby], owners: ["bot"], serviceNames: ["bot": "SwiftBot"], at: start + 10)
        _ = monitor.observe([report(.degraded)], participants: [standby], owners: ["bot"], serviceNames: ["bot": "SwiftBot"], at: start + 20)
        var signals = monitor.conditionSignals(subjects: subjects, at: start + 21)
        let degraded = signals.first { $0.trigger == .nodeDegraded }
        XCTAssertEqual(degraded?.basis, .applicationReported)
        XCTAssertEqual(degraded?.subject.groupID, service.id)
        XCTAssertFalse(degraded?.detail.contains("SwiftBot reported") == true, "Generic signals carry application-neutral wording")
        let impaired = signals.first { $0.trigger == .protectionImpaired }
        guard case .condition(.active) = impaired?.shape else { return XCTFail("Primary owns, no ready standby") }
        XCTAssertEqual(impaired?.basis, .ruruObserved)
        // The report goes stale: Ruru's own observation, not the application's claim.
        _ = monitor.observe([report(.ready, fresh: false)], participants: [standby], owners: ["bot"], serviceNames: ["bot": "SwiftBot"], at: start + 90)
        signals = monitor.conditionSignals(subjects: subjects, at: start + 91)
        XCTAssertEqual(signals.first { $0.trigger == .nodeDegraded }?.basis, .ruruObserved)
        _ = monitor.observe([report(.ready)], participants: [standby], owners: ["bot"], serviceNames: ["bot": "SwiftBot"], at: start + 100)
        signals = monitor.conditionSignals(subjects: subjects, at: start + 101)
        guard case .condition(.clear) = signals.first(where: { $0.trigger == .nodeDegraded })?.shape else { return XCTFail() }
        guard case .condition(.clear) = signals.first(where: { $0.trigger == .protectionImpaired })?.shape else { return XCTFail() }
    }

    func testTransientStalenessDoesNotNotifyAndSustainedStalenessNotifiesOnce() {
        for missing in [false, true] {
            var monitor = OperationalAlertMonitor()
            var engine = AlertEngineCore()
            _ = engine.setRules([
                AlertRule(name: "Readiness", trigger: .nodeDegraded, cooldownSeconds: 0),
                AlertRule(name: "Protection", trigger: .protectionImpaired, cooldownSeconds: 0)
            ], now: start)
            let standby = ParticipantObservation(clusterID: "bot", nodeID: "backup", nodeName: "Backup",
                                                 role: .standby, ageSeconds: 0, fresh: true)
            func report(_ state: OperationalState = .ready, fresh: Bool = true) -> OperationalStatusObservation {
                .init(clusterID: "bot", nodeID: "backup", nodeName: "Backup", state: state,
                      components: [], ageSeconds: fresh ? 0 : 46, fresh: fresh)
            }
            func poll(_ reports: [OperationalStatusObservation], uptime: TimeInterval, wall: TimeInterval? = nil)
                -> ([RuruAlert.Kind], [AlertHistoryEntry.Kind]) {
                let now = start + (wall ?? uptime)
                let result = monitor.observe(reports, participants: [standby], owners: ["bot"],
                                             serviceNames: ["bot": "SwiftBot"], at: now, uptime: uptime)
                let notes = monitor.conditionSignals(subjects: subjects, at: now).flatMap { signal in
                    engine.ingest(signal, now: now).compactMap { effect -> OutgoingNotification? in
                        if case .history(_, let note) = effect { return note }; return nil
                    }
                }
                return (result.alerts.map(\.kind), notes.map(\.kind))
            }
            let absent = missing ? [] : [report(fresh: false)]
            XCTAssertTrue(poll([report()], uptime: 0).1.isEmpty)
            XCTAssertTrue(poll(absent, uptime: 46).0.isEmpty)
            XCTAssertTrue(poll(absent, uptime: 70, wall: 10_000).1.isEmpty, "Wall-clock changes cannot bypass grace")
            let transientRecovery = poll([report()], uptime: 80)
            XCTAssertTrue(transientRecovery.0.isEmpty)
            XCTAssertTrue(transientRecovery.1.isEmpty, "No recovery notice for a suppressed outage")
            XCTAssertTrue(poll(absent, uptime: 100).1.isEmpty)
            XCTAssertTrue(poll(absent, uptime: 159).1.isEmpty)
            let sustained = poll(absent, uptime: 160)
            XCTAssertEqual(sustained.0, [.operationalDegraded, .failoverProtectionImpaired])
            XCTAssertEqual(sustained.1, [.opened, .opened])
            XCTAssertTrue(poll(absent, uptime: 161).1.isEmpty)
            let recovery = poll([report()], uptime: 170)
            XCTAssertEqual(recovery.0.count, 2)
            XCTAssertEqual(recovery.1, [.recovered, .recovered])
            XCTAssertTrue(poll([report()], uptime: 171).1.isEmpty)
        }
    }

    func testReportedFaultDuringStaleGraceStillNotifiesAndStalenessCannotRecoverIt() {
        var monitor = OperationalAlertMonitor()
        let standby = ParticipantObservation(clusterID: "bot", nodeID: "backup", nodeName: nil,
                                             role: .standby, ageSeconds: 0, fresh: true)
        func poll(_ state: OperationalState, fresh: Bool = true, uptime: TimeInterval)
            -> [RuruAlert] {
            monitor.observe([.init(clusterID: "bot", nodeID: "backup", nodeName: nil, state: state,
                                   components: [], ageSeconds: fresh ? 0 : 46, fresh: fresh)],
                            participants: [standby], owners: ["bot"], serviceNames: ["bot": "SwiftBot"],
                            at: start + uptime, uptime: uptime).alerts
        }
        _ = poll(.ready, uptime: 0)
        XCTAssertTrue(poll(.ready, fresh: false, uptime: 46).isEmpty)
        XCTAssertEqual(poll(.degraded, uptime: 50).map(\.kind), [.operationalDegraded, .failoverProtectionImpaired])
        XCTAssertTrue(poll(.degraded, fresh: false, uptime: 96).isEmpty)
        let signals = monitor.conditionSignals(subjects: subjects, at: start + 96)
        XCTAssertEqual(signals.first { $0.trigger == .nodeDegraded }?.shape, .condition(.inconclusive))
        guard case .condition(.active) = signals.first(where: { $0.trigger == .protectionImpaired })?.shape else {
            return XCTFail("Staleness must not recover an existing protection incident")
        }
        XCTAssertEqual(poll(.ready, uptime: 100).map(\.kind), [.operationalRecovered, .failoverProtectionRestored])
    }

    func testOwnershipTransfersIncludePlannedHandoffsButNotRestartsOrQuarantine() {
        var monitor = OwnershipTransferMonitor()
        let home = RuruAlertMonitor.Owner(nodeID: "home", name: "Home Mac"), backup = RuruAlertMonitor.Owner(nodeID: "backup", name: "Backup Mac")
        XCTAssertTrue(monitor.observe(owners: ["bot": home], serving: true, services: ["bot"]).isEmpty, "The first observation is a baseline")
        XCTAssertTrue(monitor.observe(owners: [:], serving: true, services: ["bot"]).isEmpty, "Released")
        XCTAssertTrue(monitor.observe(owners: ["bot": backup], serving: false, services: ["bot"]).isEmpty, "Quarantine says nothing")
        let transfer = monitor.observe(owners: ["bot": backup], serving: true, services: ["bot"])
        XCTAssertEqual(transfer, [.init(clusterID: "bot", from: "Home Mac", to: "Backup Mac")])
        let signals = RuruAlertSignals.ownership(transfer, subjects: subjects, at: start)
        XCTAssertEqual(signals.first?.trigger, .ownershipTransferred)
        XCTAssertEqual(signals.first?.basis, .authoritativeLease)
        XCTAssertTrue(monitor.observe(owners: ["bot": backup], serving: true, services: ["bot"]).isEmpty, "Once per transfer")
    }

    func testMonitorObservationsBecomeEvidenceNeverGuesses() {
        let target = MonitorTarget(name: "Site", kind: .http, url: "https://example.com", failureThreshold: 3)
        func observation(_ result: MonitorResult, status: MonitorStatus, failures: Int) -> MonitorObservation {
            MonitorObservation(targetID: target.id, name: target.name, address: target.address, kind: .http, result: result,
                               status: status, consecutiveFailures: failures, failureThreshold: 3, intervalSeconds: 60,
                               timeoutSeconds: 10, change: nil)
        }
        let failing = RuruAlertSignals.monitor(observation(MonitorResult(ok: false, detail: "HTTP 503"), status: .up, failures: 1), at: start)
        guard case .condition(.active(let evidence)) = failing.shape else { return XCTFail() }
        XCTAssertFalse(evidence.confirmed, "One failure is below the monitor's own threshold")
        XCTAssertEqual(evidence.failures, 1)
        XCTAssertGreaterThanOrEqual(evidence.maxGap, 190)
        let confirmed = RuruAlertSignals.monitor(observation(MonitorResult(ok: false, detail: "HTTP 503"), status: .down, failures: 3), at: start)
        guard case .condition(.active(let sure)) = confirmed.shape else { return XCTFail() }
        XCTAssertTrue(sure.confirmed)
        let unknown = RuruAlertSignals.monitor(observation(MonitorResult(ok: false, detail: "No network", inconclusive: true), status: .down, failures: 3), at: start)
        XCTAssertEqual(unknown.shape, .condition(.inconclusive))
        let healthy = RuruAlertSignals.monitor(observation(MonitorResult(ok: true, latencyMilliseconds: 12, detail: "HTTP 200"), status: .up, failures: 0), at: start)
        XCTAssertEqual(healthy.shape, .condition(.clear))
        XCTAssertEqual(healthy.subject.id, target.id)
        XCTAssertEqual(healthy.trigger, .monitorUnavailable)
    }

    func testRuleNotificationsCarrySeverityAndEvidenceIntoEveryDestination() throws {
        let note = OutgoingNotification(entryID: 7, ruleID: UUID(), ruleName: "R", trigger: .primaryUnreachable, kind: .recovered,
                                        title: "SwiftBot is back", body: "Backup Mac now owns SwiftBot.", severity: .critical,
                                        basis: .authoritativeLease, subjectName: "SwiftBot", groupName: nil, choice: .followSettings)
        let alert = RuruAlertTransport.alert(for: note)
        XCTAssertEqual(alert.severity, .resolved, "A recovery is green whatever the rule's severity")
        XCTAssertTrue(alert.isEnabled(in: RuruAlertPreferences()), "Rules, not fixed toggles, decide")
        let json = try JSONSerialization.jsonObject(with: RuruDiscordWebhook.payload(for: alert, at: start)) as? [String: Any]
        let embed = (json?["embeds"] as? [[String: Any]])?.first
        XCTAssertEqual((embed?["footer"] as? [String: String])?["text"], "Ruru • Alerts • Authoritative lease record")
        XCTAssertEqual(embed?["color"] as? Int, 0x30A46C)
        XCTAssertNotNil(try? RuruNotify.payload(for: alert))
    }
}

final class AlertAuthorityFailureTests: XCTestCase {
    func testAnAuthorityThatCannotOpenIsReportedAsAConditionWithoutJudgingOwnership() {
        var monitor = RuruAlertMonitor()
        let service = GuardedService(name: "SwiftBot", clusterID: "bot", kind: .swiftBot)
        let observation = RuruAlertMonitor.Observation(
            serviceRunning: false, recovering: false, serviceFailure: "The ownership database is unavailable.", tunnelError: nil,
            snapshotError: nil, owners: [:], services: ["bot": "SwiftBot"], releases: [])
        let alerts = monitor.observe(observation, at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(alerts.map(\.kind), [.authorityProblem], "The earlier alert path also reports it")
        let signals = monitor.conditionSignals(subjects: RuruAlertSubjects(services: [service]), at: Date(timeIntervalSince1970: 1_800_000_001))
        let stopped = signals.first { $0.trigger == .serviceStopped }
        guard case .condition(.active) = stopped?.shape else { return XCTFail("Expected an active authority condition") }
        XCTAssertEqual(stopped?.detail, "The ownership database is unavailable.")
        XCTAssertEqual(stopped?.subject.source, .authority)
        guard case .condition(.inconclusive) = signals.first(where: { $0.trigger == .primaryUnreachable })?.shape else {
            return XCTFail("Ownership can't be judged without the authority")
        }
    }
}

final class IncidentGuidanceTests: XCTestCase {
    private func incident(_ trigger: TriggerID, source: AlertSource, group: String? = nil,
                          verification: AlertIncident.Verification = .verified) -> AlertIncident {
        AlertIncident(ruleID: UUID(), ruleName: "Example", trigger: trigger,
                      subject: SubjectRef(source: source, kind: "example", id: "subject", name: "Example", groupID: group),
                      severity: .warning, basis: .ruruObserved, verification: verification,
                      title: "Example", detail: "", openedAt: Date())
    }

    func testUnverifiedReadinessGuidanceKeepsEvidenceAndOwnershipSeparate() {
        let guidance = RuruIncidentGuidance(incident(.nodeDegraded, source: .operationalStatus,
                                                   group: "service", verification: .unverified))
        XCTAssertEqual(guidance.destination, .service("service"))
        XCTAssertTrue(guidance.detail.contains("Awaiting fresh evidence"))
        XCTAssertTrue(guidance.detail.contains("Presence alone does not confirm readiness or grant ownership"))
    }

    func testSlowMonitorGuidanceRequiresSuccessfulMeasurementBelowLimit() {
        let guidance = RuruIncidentGuidance(incident(.monitorSlow, source: .monitoring))
        XCTAssertEqual(guidance.destination, .monitor("subject"))
        XCTAssertTrue(guidance.detail.contains("below the rule's limit"))
        XCTAssertTrue(guidance.detail.contains("failed or inconclusive check does not"))
    }

    func testAuthorityAndTunnelFailuresHaveDifferentRecoveryActions() {
        XCTAssertEqual(RuruIncidentGuidance(incident(.internetAccessDown, source: .authority)).destination, .internet)
        let storage = RuruIncidentGuidance(incident(.serviceStopped, source: .authority))
        XCTAssertEqual(storage.destination, .overview)
        XCTAssertTrue(storage.detail.contains("preserve the database and safety markers"))
    }
}
