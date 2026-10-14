import Foundation
import XCTest
@testable import RuruAlerting
@testable import WitnessKit

private final class FakeTransport: AlertTransport, @unchecked Sendable {
    struct Sent: Equatable { let destination: AlertDestination; let title: String; let kind: AlertHistoryEntry.Kind }
    private let lock = NSLock()
    private var log: [Sent] = []
    private var failing: Set<AlertDestination> = []
    private var delay: Duration = .zero
    private var attempts = 0

    func set(delay: Duration) { lock.withLock { self.delay = delay } }
    func set(failing: Set<AlertDestination>) { lock.withLock { self.failing = failing } }
    var sent: [Sent] { lock.withLock { log } }
    var attemptCount: Int { lock.withLock { attempts } }

    func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome {
        let (wait, fails) = lock.withLock { () -> (Duration, Bool) in attempts += 1; return (delay, failing.contains(destination)) }
        if wait > .zero { try? await Task.sleep(for: wait) }
        if fails { return DeliveryOutcome(destination: destination, ok: false, message: "Rejected", retryable: false) }
        lock.withLock { log.append(Sent(destination: destination, title: notification.title, kind: notification.kind)) }
        return DeliveryOutcome(destination: destination, ok: true)
    }
}

private final class AlertTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { lock.withLock { now += seconds } }
    var date: Date { lock.withLock { now } }
}

final class AlertServiceTests: XCTestCase {
    private var directory: URL!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let site = SubjectRef(source: .monitoring, kind: "monitor", id: "site", name: "Website")

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ruru-alerts-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: directory) }

    private var rulesURL: URL { directory.appendingPathComponent("alert-rules.json") }
    private var databaseURL: URL { directory.appendingPathComponent("alerts.duckdb") }

    private func makeService(transport: FakeTransport, clock: AlertTestClock, database: URL? = nil,
                             enabled: Set<AlertDestination> = [.macOS, .discord]) -> AlertService {
        AlertService(.init(rulesURL: rulesURL, databaseURL: database ?? databaseURL, transport: transport,
                           enabledDestinations: { enabled }, clock: { clock.date }, retryDelay: .milliseconds(30)))
    }

    private func down(_ time: Date, detail: String = "HTTP 503") -> AlertSignal {
        AlertSignal(trigger: .monitorUnavailable, subject: site,
                    shape: .condition(.active(.init(failures: 3, confirmed: true, maxGap: 600))),
                    title: "Website is unreachable", detail: detail, basis: .ruruObserved, observedAt: time)
    }
    private func up(_ time: Date) -> AlertSignal {
        AlertSignal(trigger: .monitorUnavailable, subject: site, shape: .condition(.clear),
                    title: "Website is reachable again", detail: "HTTP 200", basis: .ruruObserved, observedAt: time)
    }

    private func eventually(_ message: String = "", timeout: TimeInterval = 4, _ condition: () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if await condition() { return }; try? await Task.sleep(for: .milliseconds(20)) }
        XCTFail("Timed out: \(message)", file: file, line: line)
    }

    // MARK: Capability-aware defaults

    func testMonitoringDefaultsAreProvisionedBeforeGuardingArrives() async throws {
        let service = makeService(transport: FakeTransport(), clock: AlertTestClock(start))
        let report = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        XCTAssertTrue(report.rulesActive)
        XCTAssertEqual(report.provisioned, ["Endpoint unavailable", "Slow response"])
        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.rules.map(\.trigger), [.monitorUnavailable, .monitorSlow])
        XCTAssertTrue(snapshot.rules[0].enabled)
        XCTAssertFalse(snapshot.rules[1].enabled, "Latency alerts are offered but off until chosen")
        XCTAssertEqual(snapshot.rules[1].limit, 100)
        XCTAssertTrue(snapshot.rules[0].notifyOnRecovery, "One rule covers both unavailable and recovered")
        XCTAssertEqual(snapshot.rules[0].templateID, "default.monitor.unavailable")

        // Guarding is added later: its defaults appear, nothing is duplicated.
        let added = await service.provision(capabilities: .init(monitoring: true, guarding: true), legacy: .defaults)
        XCTAssertTrue(added.map(\.name).contains("Primary unreachable"))
        XCTAssertTrue(added.map(\.name).contains("Failover completed"))
        XCTAssertTrue(added.map(\.name).contains("Failover protection impaired"))
        XCTAssertTrue(added.map(\.name).contains("Server readiness degraded"))
        XCTAssertFalse(added.map(\.name).contains("Ruru public connectivity lost"), "No Internet Access configured yet")
        snapshot = await service.snapshot()
        let before = snapshot.rules.count
        let again = await service.provision(capabilities: .init(monitoring: true, guarding: true), legacy: .defaults)
        XCTAssertTrue(again.isEmpty)
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.rules.count, before)
        XCTAssertEqual(Set(snapshot.rules.compactMap(\.templateID)).count, snapshot.rules.count, "No duplicate templates")
    }

    func testProvisioningNeverRevivesDeletedRulesOverwritesCustomisationsOrReenablesDisabledOnes() async throws {
        let service = makeService(transport: FakeTransport(), clock: AlertTestClock(start))
        _ = await service.start(capabilities: .init(monitoring: true, guarding: true), legacy: .defaults)
        var rules = await service.snapshot().rules
        let failover = try XCTUnwrap(rules.first { $0.trigger == .failoverCompleted })
        let primary = try XCTUnwrap(rules.first { $0.trigger == .primaryUnreachable })
        let monitor = try XCTUnwrap(rules.first { $0.trigger == .monitorUnavailable })
        try await service.deleteRule(failover.id)
        try await service.setRuleEnabled(primary.id, false)
        var custom = monitor; custom.name = "My own name"; custom.threshold = .failedChecks(5); custom.cooldownSeconds = 600
        _ = try await service.saveRule(custom)

        await service.provision(capabilities: .init(monitoring: true, guarding: true, internetAccess: true), legacy: .defaults)
        rules = await service.snapshot().rules
        XCTAssertNil(rules.first { $0.trigger == .failoverCompleted }, "A deleted default stays deleted")
        XCTAssertEqual(rules.first { $0.id == primary.id }?.enabled, false, "A deliberately disabled rule stays disabled")
        let kept = try XCTUnwrap(rules.first { $0.id == monitor.id })
        XCTAssertEqual(kept.name, "My own name"); XCTAssertEqual(kept.threshold, .failedChecks(5)); XCTAssertEqual(kept.cooldownSeconds, 600)
        XCTAssertNotNil(rules.first { $0.trigger == .internetAccessDown }, "Newly available capability adds its rule")
    }

    func testExistingNotificationPreferencesDecideWhichDefaultsStartEnabled() async throws {
        var legacy = LegacyAlertPreferences.defaults
        legacy.values[.failover] = false
        legacy.values[.monitoring] = false
        legacy.values[.participantStatus] = true
        let service = makeService(transport: FakeTransport(), clock: AlertTestClock(start))
        _ = await service.start(capabilities: .init(monitoring: true, guarding: true, internetAccess: true), legacy: legacy)
        let rules = await service.snapshot().rules
        func enabled(_ trigger: TriggerID) -> Bool? { rules.first { $0.trigger == trigger }?.enabled }
        XCTAssertEqual(enabled(.failoverCompleted), false, "A user who turned failover alerts off is not re-subscribed")
        XCTAssertEqual(enabled(.monitorUnavailable), false)
        XCTAssertEqual(enabled(.primaryUnreachable), true)
        XCTAssertEqual(enabled(.participantOnBattery), true)
        XCTAssertEqual(enabled(.ownershipTransferred), false, "New optional rules start off")
        XCTAssertEqual(enabled(.serviceStopped), true)
        XCTAssertEqual(enabled(.internetAccessDown), true)
    }

    // MARK: End to end

    func testOutageDeliversOnceAndRecoveryOnceAndRecordsHistory() async throws {
        let transport = FakeTransport(), clock = AlertTestClock(start)
        let service = makeService(transport: transport, clock: clock)
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        for second in 0..<5 {
            await service.ingest([down(clock.date)]); clock.advance(Double(second) + 1)
        }
        await eventually("one macOS and one Discord notification") { transport.sent.count == 2 }
        XCTAssertEqual(Set(transport.sent.map(\.destination)), [.macOS, .discord])
        await service.ingest([up(clock.date)])
        await eventually("recovery") { transport.sent.count == 4 }
        XCTAssertEqual(transport.sent.suffix(2).map(\.kind), [.recovered, .recovered])
        let snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.openIncidents.isEmpty)
        XCTAssertEqual(Array(snapshot.history.map(\.kind).prefix(2)), [.recovered, .opened])
        await eventually("deliveries recorded") { await service.snapshot().history.first?.deliveries.count == 2 }
        let rule = try XCTUnwrap(snapshot.rules.first)
        XCTAssertNotNil(snapshot.lastTriggered[rule.id])
        let incidents = await service.incidents(subjectKey: site.key)
        XCTAssertEqual(incidents.first?.resolution, .recovered)
    }

    func testARestartDuringAnIncidentKeepsItUnverifiedWithoutDuplicateNotifications() async throws {
        let transport = FakeTransport(), clock = AlertTestClock(start)
        var service: AlertService? = makeService(transport: transport, clock: clock)
        _ = await service!.start(capabilities: .init(monitoring: true), legacy: .defaults)
        await service!.ingest([down(clock.date)])
        await eventually("first notification") { transport.sent.count == 2 }
        await service!.shutdown()
        service = nil
        try await Task.sleep(for: .milliseconds(200))

        clock.advance(30)
        let restarted = makeService(transport: transport, clock: clock)
        let report = await restarted.start(capabilities: .init(monitoring: true), legacy: .defaults)
        XCTAssertTrue(report.provisioned.isEmpty, "Defaults aren't provisioned twice across launches")
        var snapshot = await restarted.snapshot()
        XCTAssertEqual(snapshot.openIncidents.count, 1)
        XCTAssertEqual(snapshot.openIncidents.first?.verification, .unverified)
        for hours in 1...3 { clock.advance(3600 * Double(hours)); await restarted.tick() }
        snapshot = await restarted.snapshot()
        XCTAssertEqual(snapshot.openIncidents.count, 1, "Not expired for lack of information")
        await restarted.ingest([down(clock.date)])
        snapshot = await restarted.snapshot()
        XCTAssertEqual(snapshot.openIncidents.first?.verification, .verified)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(transport.sent.count, 2, "No duplicate notification after the restart")
        await restarted.ingest([up(clock.date)])
        await eventually("recovery after restart") { transport.sent.count == 4 }
    }

    func testAPendingThresholdSurvivesARestart() async throws {
        let transport = FakeTransport(), clock = AlertTestClock(start)
        var service: AlertService? = makeService(transport: transport, clock: clock)
        _ = await service!.start(capabilities: .init(monitoring: true), legacy: .defaults)
        let initial = await service!.snapshot()
        var rule = try XCTUnwrap(initial.rules.first)
        rule.threshold = .after(300)
        _ = try await service!.saveRule(rule)
        for _ in 0..<5 {
            await service!.ingest([down(clock.date)]); clock.advance(60)    // four minutes of failing checks
        }
        XCTAssertEqual(transport.sent.count, 0)
        await service!.shutdown(); service = nil
        try await Task.sleep(for: .milliseconds(200))
        clock.advance(20)
        let restarted = makeService(transport: transport, clock: clock)
        _ = await restarted.start(capabilities: .init(monitoring: true), legacy: .defaults)
        await restarted.ingest([down(clock.date)])
        await eventually("threshold completes using persisted evidence") { transport.sent.count == 2 }
    }

    // MARK: Failure isolation

    func testASlowDestinationNeverDelaysIngestingSignals() async throws {
        let transport = FakeTransport(); transport.set(delay: .seconds(3))
        let clock = AlertTestClock(start)
        let service = makeService(transport: transport, clock: clock)
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        let began = Date()
        for index in 0..<20 {
            var other = site; other = SubjectRef(source: .monitoring, kind: "monitor", id: "m\(index)", name: "Monitor \(index)")
            await service.ingest([AlertSignal(trigger: .monitorUnavailable, subject: other,
                shape: .condition(.active(.init(confirmed: true))), title: "\(other.name) is unreachable", detail: "x",
                basis: .ruruObserved, observedAt: clock.date)])
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.0, "Producers never wait for notification delivery")
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.openIncidents.count, 20)
        await service.shutdown()
    }

    func testAFailingDestinationIsRecordedWithoutAffectingTheOthers() async throws {
        let transport = FakeTransport(); transport.set(failing: [.discord])
        let clock = AlertTestClock(start)
        let service = makeService(transport: transport, clock: clock)
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        await service.ingest([down(clock.date)])
        await eventually("macOS delivered") { transport.sent.map(\.destination) == [.macOS] }
        await eventually("failure recorded") { await service.snapshot().deliveryProblems[.discord] == "Rejected" }
        let outcomes = await service.snapshot().history.first?.deliveries
        XCTAssertEqual(outcomes?.first { $0.destination == .discord }?.ok, false)
        XCTAssertEqual(outcomes?.first { $0.destination == .macOS }?.ok, true)
        let kept = await service.snapshot()
        XCTAssertEqual(kept.openIncidents.count, 1, "A failed notification never loses the incident")
    }

    func testARuleCanTargetOnlySpecificDestinationsAndReportsOnesThatAreNotSetUp() async throws {
        let transport = FakeTransport(), clock = AlertTestClock(start)
        let service = makeService(transport: transport, clock: clock, enabled: [.macOS])
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        let initial = await service.snapshot()
        var rule = try XCTUnwrap(initial.rules.first)
        rule.delivery = DeliveryChoice(useAllEnabled: false, destinations: [.discord, .macOS])
        _ = try await service.saveRule(rule)
        await service.ingest([down(clock.date)])
        await eventually("macOS delivered") { transport.sent.map(\.destination) == [.macOS] }
        await eventually("discord reported unavailable") {
            await service.snapshot().history.first?.deliveries.contains { $0.destination == .discord && !$0.ok } == true
        }
    }

    // MARK: Storage resilience

    func testDamagedAlertHistoryIsSetAsideAndAlertsKeepWorking() async throws {
        try Data("this is not a database".utf8).write(to: databaseURL)
        let transport = FakeTransport(), clock = AlertTestClock(start)
        let service = makeService(transport: transport, clock: clock)
        let report = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        guard case .recovered(let moved) = report.storage else { return XCTFail("Expected recovery, got \(report.storage)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(moved).path),
                      "The damaged file is kept, never deleted")
        XCTAssertNotNil(report.notice)
        await service.ingest([down(clock.date)])
        await eventually("notification still delivered") { transport.sent.count == 2 }
        let after = await service.snapshot()
        XCTAssertEqual(after.storage, report.storage)
    }

    func testUnavailableStorageDegradesToInMemoryAlertingWithAVisibleWarning() async throws {
        let blocker = directory.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let unusable = blocker.appendingPathComponent("alerts.duckdb")     // its parent is a regular file
        let transport = FakeTransport(), clock = AlertTestClock(start)
        let service = makeService(transport: transport, clock: clock, database: unusable)
        let report = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        guard case .unavailable = report.storage else { return XCTFail("Expected unavailable, got \(report.storage)") }
        XCTAssertTrue(report.rulesActive)
        XCTAssertNotNil(report.notice)
        await service.ingest([down(clock.date)])
        await eventually("still notifies") { transport.sent.count == 2 }
        let snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.openIncidents.count, 1)
        XCTAssertFalse(snapshot.storage.isUsable)
    }

    func testDamagedRulesFileIsKeptAndDefaultsAreRestoredWithANotice() async throws {
        try Data("{ not json".utf8).write(to: rulesURL)
        let service = makeService(transport: FakeTransport(), clock: AlertTestClock(start))
        let report = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        XCTAssertTrue(report.rulesActive)
        XCTAssertTrue(report.notice?.contains("kept as") == true)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("alert-rules-damaged-") })
        let restored = await service.snapshot()
        XCTAssertEqual(restored.rules.count, 2)
    }

    func testRuleEditsPersistAcrossRestartsAndInvalidRulesAreRejected() async throws {
        let transport = FakeTransport(), clock = AlertTestClock(start)
        var service: AlertService? = makeService(transport: transport, clock: clock)
        _ = await service!.start(capabilities: .init(monitoring: true), legacy: .defaults)
        var bad = AlertRule(name: "", trigger: .monitorUnavailable)
        do { _ = try await service!.saveRule(bad); XCTFail("An empty name must be rejected") } catch {}
        bad.name = "Valid"; bad.threshold = .after(1)
        do { _ = try await service!.saveRule(bad); XCTFail("An invalid threshold must be rejected") } catch {}
        let made = try await service!.saveRule(AlertRule(name: "NAS offline", trigger: .monitorUnavailable,
                                                         scope: AlertScope(ids: ["nas"]), threshold: .after(120),
                                                         cooldownSeconds: 900, quietHours: QuietHours(startMinute: 60, endMinute: 420)))
        await service!.shutdown(); service = nil
        try await Task.sleep(for: .milliseconds(150))
        let reloaded = makeService(transport: transport, clock: clock)
        _ = await reloaded.start(capabilities: .init(monitoring: true), legacy: .defaults)
        let reloadedRules = await reloaded.snapshot().rules
        XCTAssertEqual(reloadedRules.first { $0.id == made.id }, made)
    }

    func testRestoringBackedUpRulesKeepsCustomisationsAndDoesNotRecreateDeletedDefaults() async throws {
        let service = makeService(transport: FakeTransport(), clock: AlertTestClock(start))
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        var backup = AlertRulesFile()
        backup.rules = [AlertRule(name: "NAS latency", trigger: .monitorSlow, threshold: .failedChecks(4), limit: 30)]
        // The backup's owner had already been offered, and deleted, both monitoring defaults.
        backup.provisioned = ["default.monitor.unavailable", "default.monitor.slowResponse"]
        try await service.restoreRules(backup)
        var snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.rules.map(\.name), ["NAS latency"])
        XCTAssertEqual(snapshot.rules.first?.limit, 30)
        let added = await service.provision(capabilities: .init(monitoring: true), legacy: .defaults)
        XCTAssertTrue(added.isEmpty, "Deleted defaults stay deleted after a restore")
        snapshot = await service.snapshot()
        XCTAssertEqual(snapshot.rules.count, 1)
    }

    func testTooManyRulesAreRefused() async throws {
        let service = makeService(transport: FakeTransport(), clock: AlertTestClock(start))
        _ = await service.start(capabilities: .init(), legacy: .defaults)
        for index in 0..<AlertRule.maxRules {
            _ = try await service.saveRule(AlertRule(name: "Rule \(index)", trigger: .monitorUnavailable))
        }
        do { _ = try await service.saveRule(AlertRule(name: "One more", trigger: .monitorUnavailable)); XCTFail() }
        catch AlertServiceError.tooManyRules {}
    }

    func testDisablingOrDeletingARuleArchivesItsOpenIncidentWithoutARecoveryNotice() async throws {
        let transport = FakeTransport(), clock = AlertTestClock(start)
        let service = makeService(transport: transport, clock: clock)
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        await service.ingest([down(clock.date)])
        await eventually("opened") { transport.sent.count == 2 }
        let current = await service.snapshot()
        let rule = try XCTUnwrap(current.rules.first)
        try await service.setRuleEnabled(rule.id, false)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(transport.sent.count, 2, "Archiving is not recovery")
        let snapshot = await service.snapshot()
        XCTAssertTrue(snapshot.openIncidents.isEmpty)
        XCTAssertEqual(snapshot.history.first?.kind, .archived)
        let stored = await service.incidents(subjectKey: site.key)
        XCTAssertEqual(stored.first?.resolution, .ruleDisabled)
    }

    // MARK: Monitoring rollups

    func testUptimeIsDerivedFromConclusiveChecksOnly() async throws {
        let clock = AlertTestClock(start)
        let service = makeService(transport: FakeTransport(), clock: clock)
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        var samples: [RollupSample] = []
        for index in 0..<10 {
            samples.append(RollupSample(targetID: "site", time: clock.date - Double(index) * 60, ok: index != 3,
                                        inconclusive: false, latencyMilliseconds: index == 3 ? nil : 100))
        }
        samples.append(RollupSample(targetID: "site", time: clock.date, ok: false, inconclusive: true, latencyMilliseconds: nil))
        samples.append(RollupSample(targetID: "other", time: clock.date, ok: true, inconclusive: false, latencyMilliseconds: 5))
        await service.recordMonitoring(samples)
        let windows = await service.uptime(targetID: "site")
        XCTAssertEqual(windows.map(\.label), ["24 hours", "7 days", "30 days"])
        let day = try XCTUnwrap(windows.first).summary
        XCTAssertEqual(day.checks, 10); XCTAssertEqual(day.ok, 9); XCTAssertEqual(day.inconclusive, 1)
        XCTAssertEqual(day.ratio ?? 0, 0.9, accuracy: 0.0001)
        XCTAssertEqual(day.averageLatencyMilliseconds, 100)
        let none = await service.uptime(targetID: "unknown")
        XCTAssertNil(none.first?.summary.ratio)
    }
}

final class AlertDispatcherTests: XCTestCase {
    private func note(_ title: String = "T") -> OutgoingNotification {
        OutgoingNotification(entryID: 1, ruleID: UUID(), ruleName: "R", trigger: .monitorUnavailable, kind: .opened, title: title,
                             body: "B", severity: .critical, basis: .ruruObserved, subjectName: "S", groupName: nil, choice: .followSettings)
    }

    func testEachDestinationHasItsOwnLane() async throws {
        let transport = SlowDiscord()
        let results = ResultBox()
        let dispatcher = AlertDispatcher(transport: transport) { _, outcome in await results.add(outcome) }
        await dispatcher.enqueue(note(), to: [.discord, .macOS])
        let began = Date()
        while await results.outcomes.first(where: { $0.destination == .macOS }) == nil, Date().timeIntervalSince(began) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let macOS = await results.outcomes.first { $0.destination == .macOS }
        XCTAssertEqual(macOS?.ok, true, "macOS delivery is not held up by a slow Discord")
        let discordDone = await results.outcomes.contains { $0.destination == .discord }
        XCTAssertFalse(discordDone)
        await dispatcher.shutdown()
    }

    func testTransientFailuresRetryOnceAndQueuesAreBounded() async throws {
        let flaky = Flaky()
        let results = ResultBox()
        let dispatcher = AlertDispatcher(transport: flaky, queueLimit: 3, retryDelay: .milliseconds(20)) { _, outcome in await results.add(outcome) }
        await dispatcher.enqueue(note("first"), to: [.notify])
        let began = Date()
        while await results.outcomes.isEmpty, Date().timeIntervalSince(began) < 2 { try await Task.sleep(for: .milliseconds(10)) }
        let first = await results.outcomes.first
        XCTAssertEqual(first?.ok, true, "Succeeded on the retry")
        XCTAssertEqual(flaky.calls, 2)

        let blocked = Blocker()
        let bounded = AlertDispatcher(transport: blocked, queueLimit: 3) { _, outcome in await results.add(outcome) }
        for index in 0..<8 { await bounded.enqueue(note("n\(index)"), to: [.discord]) }
        try await Task.sleep(for: .milliseconds(100))
        let stats = await bounded.stats
        XCTAssertGreaterThanOrEqual(stats.dropped, 4, "The queue is bounded; overflow is reported, not accumulated")
        await bounded.shutdown()
        await dispatcher.shutdown()
    }
}

private actor ResultBox {
    private(set) var outcomes: [DeliveryOutcome] = []
    func add(_ outcome: DeliveryOutcome) { outcomes.append(outcome) }
}
private struct SlowDiscord: AlertTransport {
    func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome {
        if destination == .discord { try? await Task.sleep(for: .seconds(5)) }
        return DeliveryOutcome(destination: destination, ok: true)
    }
}
private final class Flaky: AlertTransport, @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    var calls: Int { lock.withLock { count } }
    func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome {
        let n = lock.withLock { () -> Int in count += 1; return count }
        return n == 1 ? DeliveryOutcome(destination: destination, ok: false, message: "429", retryable: true)
                      : DeliveryOutcome(destination: destination, ok: true)
    }
}
private struct Blocker: AlertTransport {
    func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome {
        try? await Task.sleep(for: .seconds(30))
        return DeliveryOutcome(destination: destination, ok: true)
    }
}

/// The lease authority must be unaffected by anything the alert system does.
final class AlertLeaseIsolationTests: XCTestCase {
    private struct HangingTransport: AlertTransport {
        func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome {
            try? await Task.sleep(for: .seconds(30))
            return DeliveryOutcome(destination: destination, ok: false, message: "never")
        }
    }

    func testAHungDestinationAndAStormOfAlertsDoNotSlowLeaseRenewals() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("RuruIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let leases = try LeaseStore(databaseURL: folder.appendingPathComponent("leases.duckdb"))
        let service = AlertService(.init(rulesURL: folder.appendingPathComponent("alert-rules.json"),
                                         databaseURL: folder.appendingPathComponent("alerts.duckdb"),
                                         transport: HangingTransport(), enabledDestinations: { [.macOS, .discord, .notify] }))
        _ = await service.start(capabilities: .init(monitoring: true), legacy: .defaults)
        let first = await leases.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 0))
        XCTAssertEqual(first.status, 200)

        // Alerts fire continuously while every destination hangs.
        let storm = Task {
            for index in 0..<150 {
                let subject = SubjectRef(source: .monitoring, kind: "monitor", id: "m\(index)", name: "Monitor \(index)")
                await service.ingest([AlertSignal(trigger: .monitorUnavailable, subject: subject,
                    shape: .condition(.active(.init(confirmed: true))), title: "down", detail: "x",
                    basis: .ruruObserved, observedAt: Date())])
                await service.tick()
            }
        }
        var worst: TimeInterval = 0
        for _ in 0..<40 {
            let began = Date()
            let renewal = await leases.apply(.renew, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 1))
            worst = max(worst, Date().timeIntervalSince(began))
            XCTAssertEqual(renewal.status, 200, "Renewals keep succeeding")
            try await Task.sleep(for: .milliseconds(5))
        }
        await storm.value
        XCTAssertLessThan(worst, 0.5, "Alert work never queues in front of a renewal (worst \(worst) s)")
        await service.shutdown()
    }
}
