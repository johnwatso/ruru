import Foundation
import XCTest
@testable import RuruAlerting

final class AlertEngineTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC
    private let site = SubjectRef(source: .monitoring, kind: "monitor", id: "site", name: "Website")
    private let nas = SubjectRef(source: .monitoring, kind: "monitor", id: "nas", name: "NAS")

    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func core(_ rules: [AlertRule], now: Date? = nil) -> AlertEngineCore {
        var policy = AlertEngineCore.Policy(); policy.calendar = utc
        var core = AlertEngineCore(policy: policy)
        _ = core.setRules(rules, now: now ?? base)
        return core
    }

    private func rule(_ threshold: Threshold = .immediately, recovery: Bool = true, cooldown: Int = 0,
                      repeat repeatSeconds: Int? = nil, quiet: QuietHours? = nil, severity: AlertSeverity? = nil,
                      scope: AlertScope = .all, enabled: Bool = true) -> AlertRule {
        AlertRule(name: "Site down", enabled: enabled, trigger: .monitorUnavailable, scope: scope, threshold: threshold,
                  notifyOnRecovery: recovery, severity: severity, cooldownSeconds: cooldown, repeatSeconds: repeatSeconds,
                  quietHours: quiet)
    }

    private func down(_ subject: SubjectRef? = nil, at time: Date, failures: Int? = nil, confirmed: Bool = true,
                      maxGap: TimeInterval = 120, detail: String = "HTTP 503") -> AlertSignal {
        AlertSignal(trigger: .monitorUnavailable, subject: subject ?? site,
                    shape: .condition(.active(.init(failures: failures, confirmed: confirmed, maxGap: maxGap))),
                    title: "\((subject ?? site).name) is unreachable", detail: detail, basis: .ruruObserved, observedAt: time)
    }
    private func up(_ subject: SubjectRef? = nil, at time: Date) -> AlertSignal {
        AlertSignal(trigger: .monitorUnavailable, subject: subject ?? site, shape: .condition(.clear),
                    title: "\((subject ?? site).name) is reachable again", detail: "HTTP 200", basis: .ruruObserved, observedAt: time)
    }
    private func unknown(_ time: Date) -> AlertSignal {
        AlertSignal(trigger: .monitorUnavailable, subject: site, shape: .condition(.inconclusive),
                    title: "", detail: "", basis: .ruruObserved, observedAt: time)
    }

    private func notes(_ effects: [AlertEngineCore.Effect]) -> [OutgoingNotification] {
        effects.compactMap { if case .history(_, let n) = $0 { n } else { nil } }
    }
    private func entries(_ effects: [AlertEngineCore.Effect]) -> [AlertHistoryEntry] {
        effects.compactMap { if case .history(let e, _) = $0 { e } else { nil } }
    }

    // MARK: Lifecycle, deduplication, recovery

    func testConditionOpensOnceDeduplicatesAndRecoversWithOneNotification() {
        var engine = core([rule()])
        let open = engine.ingest(down(at: base), now: base)
        XCTAssertEqual(notes(open).map(\.kind), [.opened])
        XCTAssertEqual(notes(open).first?.title, "Website is unreachable")
        XCTAssertEqual(engine.openIncidents.count, 1)
        for second in 1...5 {
            let again = engine.ingest(down(at: base + Double(second)), now: base + Double(second))
            XCTAssertTrue(notes(again).isEmpty, "Repeated observations never create duplicate notifications")
        }
        XCTAssertEqual(engine.openIncidents.count, 1)
        let recovered = engine.ingest(up(at: base + 60), now: base + 60)
        XCTAssertEqual(notes(recovered).map(\.kind), [.recovered])
        XCTAssertTrue(engine.openIncidents.isEmpty)
        XCTAssertTrue(notes(engine.ingest(up(at: base + 61), now: base + 61)).isEmpty, "Recovery is sent once")
    }

    func testRecoveryNotificationIsOptionalAndNeverSentWithoutAnEarlierNotice() {
        var quiet = core([rule(recovery: false)])
        _ = quiet.ingest(down(at: base), now: base)
        XCTAssertTrue(notes(quiet.ingest(up(at: base + 5), now: base + 5)).isEmpty)
        // An outage whose open notice was held back must not announce a recovery.
        var held = core([rule(cooldown: 600)])
        _ = held.ingest(down(at: base), now: base)
        _ = held.ingest(up(at: base + 10), now: base + 10)
        let second = held.ingest(down(at: base + 20), now: base + 20)
        XCTAssertTrue(notes(second).isEmpty, "Held back by the cooldown")
        let recovered = held.ingest(up(at: base + 30), now: base + 30)
        XCTAssertTrue(notes(recovered).isEmpty, "No prior alert, so no recovery notification")
        XCTAssertEqual(entries(recovered).first?.suppressedReason, "no earlier notification")
    }

    func testEventRulesNeverCarryRecoveryOrThresholds() {
        let event = AlertRule(name: "Failover", trigger: .failoverCompleted, notifyOnRecovery: true, repeatSeconds: 300)
        XCTAssertNotNil(event.validationProblem, "A repeat interval makes no sense for an event")
        let normalized = event.normalized()
        XCTAssertFalse(normalized.notifyOnRecovery)
        XCTAssertNil(normalized.repeatSeconds)
        XCTAssertEqual(normalized.threshold, .immediately)
        XCTAssertNil(normalized.validationProblem)
        XCTAssertFalse(TriggerCatalogue.descriptor(for: .failoverCompleted)!.supportsRecovery)
        XCTAssertTrue(TriggerCatalogue.descriptor(for: .monitorUnavailable)!.supportsThreshold)
    }

    func testEventNotifiesWithCooldownAndQuietHours() {
        let transfer = AlertRule(name: "Failover", trigger: .failoverCompleted, cooldownSeconds: 300)
        var engine = core([transfer])
        let service = SubjectRef(source: .guarding, kind: "service", id: "swiftbot", name: "SwiftBot")
        func event(_ time: Date) -> AlertSignal {
            AlertSignal(trigger: .failoverCompleted, subject: service, shape: .event, title: "SwiftBot failed over",
                        detail: "Home → Backup", basis: .authoritativeLease, observedAt: time)
        }
        XCTAssertEqual(notes(engine.ingest(event(base), now: base)).count, 1)
        let within = engine.ingest(event(base + 60), now: base + 60)
        XCTAssertTrue(notes(within).isEmpty)
        XCTAssertEqual(entries(within).first?.suppressedReason, "cooldown")
        XCTAssertEqual(notes(engine.ingest(event(base + 400), now: base + 400)).count, 1)

        let quiet = AlertRule(name: "Failover", trigger: .failoverCompleted, severity: .warning,
                              quietHours: QuietHours(startMinute: 7 * 60, endMinute: 9 * 60, allowCritical: true))
        var quietEngine = core([quiet])
        XCTAssertTrue(notes(quietEngine.ingest(event(base), now: base)).isEmpty, "08:00 is inside quiet hours")
        XCTAssertEqual(notes(quietEngine.ingest(event(base + 3 * 3600), now: base + 3 * 3600)).count, 1)
        var critical = quiet; critical.severity = .critical
        var criticalEngine = core([critical])
        XCTAssertEqual(notes(criticalEngine.ingest(event(base), now: base)).count, 1, "Critical alerts bypass quiet hours")
    }

    // MARK: Thresholds

    func testDurationThresholdNeedsFreshEvidenceForTheWholePeriod() {
        var engine = core([rule(.after(300))])
        XCTAssertTrue(notes(engine.ingest(down(at: base), now: base)).isEmpty)
        for second in stride(from: 60, through: 240, by: 60) {
            XCTAssertTrue(notes(engine.ingest(down(at: base + Double(second)), now: base + Double(second))).isEmpty)
        }
        XCTAssertEqual(notes(engine.ingest(down(at: base + 300), now: base + 300)).map(\.kind), [.opened])
    }

    func testRecoveryBeforeTheThresholdNeverAlerts() {
        var engine = core([rule(.after(300))])
        _ = engine.ingest(down(at: base), now: base)
        _ = engine.ingest(down(at: base + 200), now: base + 200)
        _ = engine.ingest(up(at: base + 210), now: base + 210)
        XCTAssertTrue(notes(engine.ingest(down(at: base + 250), now: base + 250)).isEmpty, "The clock restarts after recovery")
        XCTAssertTrue(engine.openIncidents.isEmpty)
    }

    func testConsecutiveFailedChecksAndTheMonitorsOwnSetting() {
        var counted = core([rule(.failedChecks(3))])
        XCTAssertTrue(notes(counted.ingest(down(at: base), now: base)).isEmpty)
        XCTAssertTrue(notes(counted.ingest(down(at: base + 60), now: base + 60)).isEmpty)
        XCTAssertEqual(notes(counted.ingest(down(at: base + 120), now: base + 120)).count, 1)

        var sourceDefault = core([rule(.sourceDefault)])
        XCTAssertTrue(notes(sourceDefault.ingest(down(at: base, failures: 1, confirmed: false), now: base)).isEmpty)
        XCTAssertEqual(notes(sourceDefault.ingest(down(at: base + 60, failures: 3, confirmed: true), now: base + 60)).count, 1)
    }

    func testInconclusiveChecksNeitherConfirmNorClearAndAGapDiscardsStaleEvidence() {
        var engine = core([rule(.failedChecks(2))])
        _ = engine.ingest(down(at: base, maxGap: 120), now: base)
        XCTAssertTrue(engine.ingest(unknown(base + 30), now: base + 30).isEmpty)
        XCTAssertEqual(notes(engine.ingest(down(at: base + 60, maxGap: 120), now: base + 60)).count, 1,
                       "A short inconclusive spell keeps earlier evidence")
        // After a long silence the earlier failure is no longer evidence.
        var stale = core([rule(.failedChecks(2))])
        _ = stale.ingest(down(at: base, maxGap: 120), now: base)
        XCTAssertTrue(notes(stale.ingest(down(at: base + 3600, maxGap: 120), now: base + 3600)).isEmpty,
                      "A wake-from-sleep gap restarts the count")
        XCTAssertEqual(notes(stale.ingest(down(at: base + 3660, maxGap: 120), now: base + 3660)).count, 1)

        var open = core([rule()])
        _ = open.ingest(down(at: base), now: base)
        XCTAssertTrue(open.ingest(unknown(base + 10), now: base + 10).isEmpty)
        XCTAssertEqual(open.openIncidents.count, 1, "An inconclusive check never recovers an incident")
    }

    // MARK: Restart behaviour

    func testPendingEvidenceSurvivesARestartButNeverFiresFromStaleData() {
        let pending = rule(.after(300))
        var before = core([pending])
        var saved: [EvidenceRecord] = []
        for second in stride(from: 0, through: 240, by: 60) {
            for case .evidence(let record) in before.ingest(down(at: base + Double(second)), now: base + Double(second)) { saved.append(record) }
        }
        let record = try! XCTUnwrap(saved.last)
        // Ruru restarts after 20 seconds: four minutes of evidence are kept.
        var after = core([pending], now: base + 260)
        _ = after.restore(incidents: [], evidence: [record], now: base + 260)
        XCTAssertEqual(notes(after.ingest(down(at: base + 301), now: base + 301)).count, 1,
                       "The first fresh failing check completes the five minutes")
        // Restarted after a long absence: the old failures are not evidence.
        var late = core([pending], now: base + 7200)
        _ = late.restore(incidents: [], evidence: [record], now: base + 7200)
        for second in stride(from: 1, through: 240, by: 60) {
            XCTAssertTrue(notes(late.ingest(down(at: base + 7200 + Double(second)), now: base + 7200 + Double(second))).isEmpty,
                          "Evidence from before the long absence is not counted")
        }
        XCTAssertTrue(notes(late.ingest(down(at: base + 7440), now: base + 7440)).isEmpty)
        XCTAssertEqual(notes(late.ingest(down(at: base + 7501), now: base + 7501)).count, 1, "Five fresh minutes are needed")
    }

    func testOpenIncidentsReturnUnverifiedAndNeverDuplicateOrAgeOut() {
        let tracked = rule()
        var before = core([tracked])
        _ = before.ingest(down(at: base), now: base)
        let saved = before.openIncidents

        var after = core([tracked], now: base + 30)
        let restored = after.restore(incidents: saved, evidence: [], now: base + 30)
        XCTAssertTrue(notes(restored).isEmpty, "Restoring never notifies")
        XCTAssertEqual(after.openIncidents.first?.verification, .unverified)
        // A day without any fresh observation: still open, still unverified, nothing sent.
        for hour in 1...24 {
            XCTAssertTrue(notes(after.tick(now: base + Double(hour) * 3600)).isEmpty)
        }
        XCTAssertEqual(after.openIncidents.count, 1, "An unresolved incident is never expired by age")
        XCTAssertEqual(after.openIncidents.first?.verification, .unverified)
        // Fresh evidence verifies it quietly; it does not notify again.
        let verified = after.ingest(down(at: base + 90_000), now: base + 90_000)
        XCTAssertTrue(notes(verified).isEmpty)
        XCTAssertEqual(after.openIncidents.first?.verification, .verified)
    }

    func testAnUnverifiedIncidentRecoversOnlyFromFreshEvidence() {
        let tracked = rule()
        var before = core([tracked])
        _ = before.ingest(down(at: base), now: base)
        var after = core([tracked], now: base + 30)
        _ = after.restore(incidents: before.openIncidents, evidence: [], now: base + 30)
        XCTAssertTrue(notes(after.ingest(unknown(base + 40), now: base + 40)).isEmpty)
        XCTAssertEqual(after.openIncidents.count, 1)
        let recovered = after.ingest(up(at: base + 50), now: base + 50)
        XCTAssertEqual(notes(recovered).map(\.kind), [.recovered])
        XCTAssertTrue(after.openIncidents.isEmpty)
    }

    func testIncidentsForRemovedOrDisabledRulesAreArchivedNotRecovered() {
        let original = rule()
        var engine = core([original])
        _ = engine.ingest(down(at: base), now: base)
        var disabled = original; disabled.enabled = false
        let effects = engine.setRules([disabled], now: base + 10)
        XCTAssertTrue(notes(effects).isEmpty, "Archiving never sends a recovery notification")
        XCTAssertTrue(engine.openIncidents.isEmpty)
        var archived: AlertIncident?
        for case .incident(let closed) in effects { archived = closed }
        XCTAssertEqual(archived?.resolution, .ruleDisabled)
        XCTAssertEqual(archived?.resolution?.isRecovery, false)

        var removed = core([original])
        _ = removed.ingest(down(at: base), now: base)
        let gone = removed.removeSubjects(source: .monitoring, kind: "monitor", keeping: [], now: base + 5)
        XCTAssertTrue(notes(gone).isEmpty)
        var resolutions: [IncidentResolution] = []
        for case .incident(let closed) in gone { if let resolution = closed.resolution { resolutions.append(resolution) } }
        XCTAssertEqual(resolutions, [.subjectRemoved])
    }

    // MARK: Flapping, cooldown, quiet hours, repeat

    func testFlappingEndpointSendsOneFlappingNoticeThenStaysQuietUntilStable() {
        var engine = core([rule()])
        var sent: [AlertHistoryEntry.Kind] = []
        var time = base
        for _ in 0..<5 {
            sent += notes(engine.ingest(down(at: time), now: time)).map(\.kind); time += 20
            sent += notes(engine.ingest(up(at: time), now: time)).map(\.kind); time += 20
        }
        XCTAssertEqual(sent.filter { $0 == .flapping }.count, 1)
        XCTAssertLessThanOrEqual(sent.count, 6, "Ruru does not flood: \(sent)")
        XCTAssertEqual(engine.incidents.count, 1, "One incident, however many times it flaps")
        // Stable and recovered for ten minutes: one "stable again" notice.
        let stable = notes(engine.tick(now: time + 601))
        XCTAssertEqual(stable.map(\.kind), [.stable])
        XCTAssertTrue(notes(engine.tick(now: time + 700)).isEmpty)
    }

    func testRecoveryDuringACooldownIsStillAnnouncedAndALaterReopenWaitsOutTheCooldown() {
        var engine = core([rule(cooldown: 300)])
        XCTAssertEqual(notes(engine.ingest(down(at: base), now: base)).count, 1)
        XCTAssertEqual(notes(engine.ingest(up(at: base + 30), now: base + 30)).map(\.kind), [.recovered],
                       "The earlier alert deserves its recovery")
        let again = engine.ingest(down(at: base + 60), now: base + 60)
        XCTAssertTrue(notes(again).isEmpty)
        XCTAssertEqual(entries(again).first?.suppressedReason, "cooldown")
        XCTAssertTrue(notes(engine.tick(now: base + 120)).isEmpty)
        _ = engine.ingest(down(at: base + 330), now: base + 330)
        let delayed = notes(engine.tick(now: base + 331))
        XCTAssertEqual(delayed.map(\.kind), [.opened])
        XCTAssertTrue(delayed.first?.body.contains("still unresolved") == true)
        XCTAssertTrue(notes(engine.tick(now: base + 332)).isEmpty, "Only once")
    }

    func testAnOutageStartingInQuietHoursIsAnnouncedWhenTheyEnd() {
        let quiet = QuietHours(startMinute: 7 * 60, endMinute: 9 * 60, allowCritical: false)
        var engine = core([rule(quiet: quiet)])
        XCTAssertTrue(notes(engine.ingest(down(at: base), now: base)).isEmpty)
        XCTAssertTrue(notes(engine.ingest(down(at: base + 1800), now: base + 1800)).isEmpty)
        _ = engine.ingest(down(at: base + 7200), now: base + 7200)
        XCTAssertEqual(notes(engine.tick(now: base + 7201)).map(\.kind), [.opened], "09:00 has passed and it is still down")
    }

    func testRepeatRemindersWhileUnresolvedButNotWhenUnverified() {
        let reminding = rule(repeat: 600)
        var engine = core([reminding])
        _ = engine.ingest(down(at: base), now: base)
        XCTAssertTrue(notes(engine.tick(now: base + 300)).isEmpty)
        let reminder = notes(engine.tick(now: base + 601))
        XCTAssertEqual(reminder.map(\.kind), [.reminder])
        XCTAssertTrue(reminder.first?.title.hasPrefix("Still: ") == true)
        XCTAssertTrue(notes(engine.tick(now: base + 700)).isEmpty)

        var restarted = core([reminding], now: base + 5000)
        _ = restarted.restore(incidents: engine.openIncidents, evidence: [], now: base + 5000)
        XCTAssertTrue(notes(restarted.tick(now: base + 9000)).isEmpty, "No reminders about a condition Ruru can't currently verify")
    }

    func testSimultaneousIncidentsAreIndependentAndRulesCanBeScoped() {
        var engine = core([rule(scope: AlertScope(ids: ["site"]))])
        XCTAssertEqual(notes(engine.ingest(down(site, at: base), now: base)).count, 1)
        XCTAssertTrue(notes(engine.ingest(down(nas, at: base), now: base)).isEmpty, "Not in this rule's scope")

        var both = core([rule()])
        _ = both.ingest(down(site, at: base), now: base)
        _ = both.ingest(down(nas, at: base), now: base)
        XCTAssertEqual(both.openIncidents.count, 2)
        _ = both.ingest(up(site, at: base + 10), now: base + 10)
        XCTAssertEqual(both.openIncidents.map(\.subject.id), ["nas"])
    }

    func testDisabledRulesAreInert() {
        var engine = core([rule(enabled: false)])
        XCTAssertTrue(engine.ingest(down(at: base), now: base).isEmpty)
        XCTAssertTrue(engine.openIncidents.isEmpty)
    }

    func testSeverityOverrideAndBasisCarryIntoTheNotification() {
        var engine = core([rule(severity: .info)])
        let note = notes(engine.ingest(down(at: base), now: base)).first
        XCTAssertEqual(note?.severity, .info)
        XCTAssertEqual(note?.basis, .ruruObserved)
    }

    // MARK: Rule validation

    func testRuleValidation() {
        XCTAssertNil(rule().validationProblem)
        var bad = rule(); bad.name = "  "
        XCTAssertNotNil(bad.validationProblem)
        bad = rule(.after(1)); XCTAssertNotNil(bad.validationProblem)
        bad = rule(cooldown: -1); XCTAssertNotNil(bad.validationProblem)
        bad = rule(repeat: 5); XCTAssertNotNil(bad.validationProblem)
        bad = rule(quiet: QuietHours(startMinute: 60, endMinute: 60)); XCTAssertNotNil(bad.validationProblem)
        var unknown = rule(); unknown.trigger = "future.trigger"
        XCTAssertNotNil(unknown.validationProblem)
        let wrongThreshold = AlertRule(name: "x", trigger: .primaryUnreachable, threshold: .failedChecks(3))
        XCTAssertNotNil(wrongThreshold.validationProblem, "Guarding has no consecutive checks")
        XCTAssertEqual(wrongThreshold.normalized().threshold, TriggerCatalogue.descriptor(for: .primaryUnreachable)!.defaultThreshold)
    }

    func testQuietHoursCrossMidnight() {
        let night = QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertTrue(night.contains(base - 9 * 3600, calendar: utc))   // 23:00
        XCTAssertTrue(night.contains(base - 2 * 3600, calendar: utc))   // 06:00
        XCTAssertFalse(night.contains(base + 3600, calendar: utc))      // 09:00
    }
}

// MARK: Response-time rules

final class AlertLatencyTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let nas = SubjectRef(source: .monitoring, kind: "monitor", id: "nas", name: "NAS")

    private func slow(_ milliseconds: Double, at time: Date) -> AlertSignal {
        AlertSignal(trigger: .monitorSlow, subject: nas, shape: .condition(.measurement(milliseconds, maxGap: 120)),
                    title: "NAS is responding slowly", detail: "nas:445 responded in \(Int(milliseconds)) ms", basis: .ruruObserved,
                    observedAt: time, recoveryTitle: "NAS is responding normally", recoveryDetail: "nas:445 responded in \(Int(milliseconds)) ms")
    }
    private func notes(_ effects: [AlertEngineCore.Effect]) -> [OutgoingNotification] {
        effects.compactMap { if case .history(_, let n) = $0 { n } else { nil } }
    }

    func testEachRuleJudgesTheMeasurementAgainstItsOwnLimit() {
        let strict = AlertRule(name: "Strict", trigger: .monitorSlow, threshold: .immediately, limit: 30)
        let lenient = AlertRule(name: "Lenient", trigger: .monitorSlow, threshold: .immediately, limit: 200)
        var engine = AlertEngineCore()
        _ = engine.setRules([strict, lenient], now: base)
        let sent = notes(engine.ingest(slow(80, at: base), now: base))
        XCTAssertEqual(sent.map(\.ruleName), ["Strict"], "80 ms breaks only the 30 ms limit")
        XCTAssertTrue(sent[0].body.contains("(limit 30 ms)"))
        XCTAssertEqual(engine.openIncidents.count, 1)
    }

    func testConsecutiveSlowChecksOpenAndAFastCheckRecoversOnce() {
        let rule = AlertRule(name: "NAS latency", trigger: .monitorSlow, threshold: .failedChecks(3), limit: 30)
        var engine = AlertEngineCore()
        _ = engine.setRules([rule], now: base)
        XCTAssertTrue(notes(engine.ingest(slow(50, at: base), now: base)).isEmpty)
        XCTAssertTrue(notes(engine.ingest(slow(10, at: base + 60), now: base + 60)).isEmpty, "A fast check resets the count")
        for step in 2...3 { XCTAssertTrue(notes(engine.ingest(slow(60, at: base + Double(step) * 60), now: base + Double(step) * 60)).isEmpty) }
        XCTAssertEqual(notes(engine.ingest(slow(70, at: base + 240), now: base + 240)).map(\.kind), [.opened])
        XCTAssertTrue(notes(engine.ingest(slow(90, at: base + 300), now: base + 300)).isEmpty, "No duplicates while still slow")
        let recovered = notes(engine.ingest(slow(12, at: base + 360), now: base + 360))
        XCTAssertEqual(recovered.map(\.kind), [.recovered])
        XCTAssertEqual(recovered.first?.title, "NAS is responding normally")
    }

    func testInconclusiveChecksNeverClearASlowIncidentAndLimitIsValidated() {
        let rule = AlertRule(name: "NAS latency", trigger: .monitorSlow, threshold: .immediately, limit: 30)
        var engine = AlertEngineCore()
        _ = engine.setRules([rule], now: base)
        _ = engine.ingest(slow(80, at: base), now: base)
        let none = AlertSignal(trigger: .monitorSlow, subject: nas, shape: .condition(.inconclusive), title: "", detail: "",
                               basis: .ruruObserved, observedAt: base + 30)
        XCTAssertTrue(engine.ingest(none, now: base + 30).isEmpty)
        XCTAssertEqual(engine.openIncidents.count, 1)

        XCTAssertNil(rule.validationProblem)
        var bad = rule; bad.limit = 0
        XCTAssertNotNil(bad.validationProblem)
        bad.limit = nil
        XCTAssertNotNil(bad.validationProblem)
        XCTAssertEqual(bad.normalized().limit, 100, "A missing limit takes the trigger's default")
        var other = AlertRule(name: "Down", trigger: .monitorUnavailable); other.limit = 50
        XCTAssertNotNil(other.validationProblem, "Triggers without a limit reject one")
        XCTAssertNil(other.normalized().limit)
        XCTAssertFalse(TriggerCatalogue.descriptor(for: .monitorSlow)!.thresholds.contains(.sourceDefault))
    }
}
