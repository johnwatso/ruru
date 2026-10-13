import Foundation

/// The alert decision logic. It is pure and deterministic: signals and the clock go
/// in, persistence and notification effects come out. It performs no I/O and never
/// calls back into a producer, so a slow or failing destination, store or rule can
/// never reach the code that produced the signal.
public struct AlertEngineCore: Sendable {
    public struct Policy: Sendable {
        /// An incident that recovers and returns within this window is the same
        /// incident, so a flapping endpoint does not create a new alert each time.
        public var reopenWindow: TimeInterval = 600
        /// Reopenings after which individual notifications stop.
        public var flapThreshold = 2
        /// How long a flapping incident must hold one state before notifications resume.
        public var stableAfter: TimeInterval = 600
        /// Minimum spacing of persisted evidence updates for one subject.
        public var evidenceWriteInterval: TimeInterval = 30
        public var calendar: Calendar = .current

        public init() {}
    }

    public enum Effect: Sendable {
        case incident(AlertIncident)
        /// A history entry and, when something should be delivered, its notification.
        case history(AlertHistoryEntry, OutgoingNotification?)
        case evidence(EvidenceRecord)
        case clearEvidence(ruleID: UUID, subjectKey: String)
    }

    private struct TrackKey: Hashable { let rule: UUID; let subject: String }
    private struct Run { var since: Date; var count: Int; var lastFreshAt: Date; var persistedAt: Date? }
    private struct Track {
        var subject: SubjectRef
        var run: Run?
        var incidentID: String?
        var lastOpenNoticeAt: Date?
        var lastEventNoticeAt: Date?
    }

    public var policy: Policy
    public private(set) var rules: [UUID: AlertRule] = [:]
    /// Open incidents and recently resolved ones that may still reopen.
    public private(set) var incidents: [String: AlertIncident] = [:]
    private var tracks: [TrackKey: Track] = [:]

    public init(policy: Policy = Policy()) { self.policy = policy }

    public var openIncidents: [AlertIncident] {
        incidents.values.filter(\.isOpen).sorted { ($0.openedAt, $0.id) > ($1.openedAt, $1.id) }
    }

    // MARK: Rules and restoration

    /// Replaces the rule set. Open incidents whose rule was removed, disabled or no
    /// longer applies are archived: closed without a recovery notification.
    public mutating func setRules(_ newRules: [AlertRule], now: Date) -> [Effect] {
        rules = Dictionary(newRules.map { ($0.id, $0.normalized()) }, uniquingKeysWith: { first, _ in first })
        var effects: [Effect] = []
        for incident in incidents.values.filter(\.isOpen).sorted(by: { $0.id < $1.id }) {
            guard let rule = rules[incident.ruleID] else {
                effects += archive(incident, .ruleRemoved, now: now); continue
            }
            if !rule.enabled { effects += archive(incident, .ruleDisabled, now: now) }
            else if rule.trigger != incident.trigger || !rule.scope.matches(incident.subject) {
                effects += archive(incident, .ruleChanged, now: now)
            }
        }
        for key in tracks.keys where rules[key.rule]?.enabled != true {
            if tracks[key]?.run != nil { effects.append(.clearEvidence(ruleID: key.rule, subjectKey: key.subject)) }
            tracks[key] = nil
        }
        return effects
    }

    /// Loads incidents and evidence saved before a restart. Open incidents come
    /// back **unverified**: they stay visible and unresolved, and only fresh
    /// observations can verify or recover them.
    public mutating func restore(incidents saved: [AlertIncident], evidence: [EvidenceRecord], now: Date) -> [Effect] {
        var effects: [Effect] = []
        for var incident in saved.sorted(by: { $0.id < $1.id }) {
            if incident.isOpen {
                guard rules[incident.ruleID]?.enabled == true else {
                    effects += archive(incident, rules[incident.ruleID] == nil ? .ruleRemoved : .ruleDisabled, now: now)
                    continue
                }
                incident.verification = .unverified
                incident.needsOpenNotice = incident.needsOpenNotice && !incident.flapping
                effects.append(.incident(incident))
            } else if let resolved = incident.resolvedAt, now.timeIntervalSince(resolved) <= policy.reopenWindow || incident.flapping {
                // Recently resolved: keep so a quick return is not a brand-new incident.
            } else { continue }
            incidents[incident.id] = incident
            let key = TrackKey(rule: incident.ruleID, subject: incident.subject.key)
            var track = tracks[key] ?? Track(subject: incident.subject)
            track.incidentID = incident.id
            tracks[key] = track
        }
        for record in evidence {
            guard rules[record.ruleID]?.enabled == true else {
                effects.append(.clearEvidence(ruleID: record.ruleID, subjectKey: record.subjectKey)); continue
            }
            let key = TrackKey(rule: record.ruleID, subject: record.subjectKey)
            guard var track = tracks[key] else {
                // Evidence can exist without an incident (a pending threshold). The
                // subject's identity is recovered from its key; display text arrives
                // with the next signal.
                let parts = record.subjectKey.split(separator: "|", maxSplits: 2).map(String.init)
                guard parts.count == 3, let source = AlertSource(rawValue: parts[0]) else { continue }
                var fresh = Track(subject: SubjectRef(source: source, kind: parts[1], id: parts[2], name: parts[2]))
                fresh.run = Run(since: record.since, count: record.count, lastFreshAt: record.lastFreshAt, persistedAt: record.lastFreshAt)
                tracks[key] = fresh
                continue
            }
            track.run = Run(since: record.since, count: record.count, lastFreshAt: record.lastFreshAt, persistedAt: record.lastFreshAt)
            tracks[key] = track
        }
        return effects
    }

    /// Archives open incidents for subjects of a source and kind that no longer
    /// exist (a deleted or paused monitor, a removed service).
    public mutating func removeSubjects(source: AlertSource, kind: String, keeping ids: Set<String>, now: Date) -> [Effect] {
        var effects: [Effect] = []
        for incident in incidents.values.filter({ $0.isOpen && $0.subject.source == source && $0.subject.kind == kind && !ids.contains($0.subject.id) })
            .sorted(by: { $0.id < $1.id }) {
            effects += archive(incident, .subjectRemoved, now: now)
        }
        for (key, track) in tracks where track.subject.source == source && track.subject.kind == kind && !ids.contains(track.subject.id) {
            if track.run != nil { effects.append(.clearEvidence(ruleID: key.rule, subjectKey: key.subject)) }
            tracks[key] = nil
        }
        return effects
    }

    /// Archives open incidents whose group (such as a guarded service) no longer exists.
    public mutating func removeGroups(source: AlertSource, keeping groupIDs: Set<String>, now: Date) -> [Effect] {
        var effects: [Effect] = []
        for incident in incidents.values.filter({ $0.isOpen && $0.subject.source == source
            && ($0.subject.groupID.map { !groupIDs.contains($0) } ?? false) }).sorted(by: { $0.id < $1.id }) {
            effects += archive(incident, .subjectRemoved, now: now)
        }
        for (key, track) in tracks where track.subject.source == source
            && (track.subject.groupID.map { !groupIDs.contains($0) } ?? false) {
            if track.run != nil { effects.append(.clearEvidence(ruleID: key.rule, subjectKey: key.subject)) }
            tracks[key] = nil
        }
        return effects
    }

    // MARK: Signals

    public mutating func ingest(_ signal: AlertSignal, now: Date) -> [Effect] {
        var effects: [Effect] = []
        for rule in rules.values.sorted(by: { $0.id.uuidString < $1.id.uuidString })
            where rule.enabled && rule.trigger == signal.trigger && rule.scope.matches(signal.subject) {
            guard let descriptor = rule.descriptor else { continue }
            switch (descriptor.lifecycle, signal.shape) {
            case (.event, .event): effects += handleEvent(rule, descriptor, signal, now)
            case (.condition, .condition(let state)): effects += handleCondition(rule, descriptor, signal, state, now)
            default: continue
            }
        }
        return effects
    }

    /// Time-driven work: reminders, notices held back by a cooldown or quiet hours,
    /// flapping stabilisation, and forgetting finished incidents.
    public mutating func tick(now: Date) -> [Effect] {
        var effects: [Effect] = []
        for var incident in incidents.values.sorted(by: { $0.id < $1.id }) {
            guard let rule = rules[incident.ruleID], rule.enabled, let descriptor = rule.descriptor else { continue }
            let original = incident
            let key = TrackKey(rule: incident.ruleID, subject: incident.subject.key)
            var track = tracks[key] ?? Track(subject: incident.subject)
            defer { tracks[key] = track }
            let severity = incident.severity
            let quiet = isQuiet(rule, severity, now)

            if incident.isOpen {
                if incident.flapping {
                    if now.timeIntervalSince(incident.stateChangedAt) >= policy.stableAfter, incident.verification == .verified {
                        // Held one state long enough: resume normal notifications.
                        incident.flapping = false; incident.flapCount = 0
                        incident.needsOpenNotice = true
                    }
                } else if incident.flapCount > 0, now.timeIntervalSince(incident.stateChangedAt) >= policy.reopenWindow {
                    incident.flapCount = 0
                }
                guard incident.verification == .verified else {
                    if incident != original { incidents[incident.id] = incident; effects.append(.incident(incident)) }
                    continue
                }
                if incident.needsOpenNotice, !incident.flapping, !quiet,
                   cooldownElapsed(rule, track.lastOpenNoticeAt, now) {
                    effects += notify(.opened, rule, descriptor, &incident, severity: severity, now: now,
                                      title: incident.title, body: incident.detail + " It is still unresolved.", track: &track)
                    incident.needsOpenNotice = false
                } else if incident.noticeOutstanding, !incident.flapping, !quiet, let interval = rule.repeatSeconds,
                          now.timeIntervalSince(incident.lastNotifiedAt ?? incident.openedAt) >= TimeInterval(interval) {
                    let elapsed = Threshold.durationText(Int(now.timeIntervalSince(incident.openedAt)))
                    effects += notify(.reminder, rule, descriptor, &incident, severity: severity, now: now,
                                      title: "Still: " + incident.title, body: "\(incident.detail) Open for \(elapsed).", track: &track)
                }
                if incident != original { incidents[incident.id] = incident; effects.append(.incident(incident)) }
            } else {
                if incident.flapping, let resolved = incident.resolvedAt,
                   now.timeIntervalSince(resolved) >= policy.stableAfter {
                    incident.flapping = false; incident.flapCount = 0
                    if incident.noticeOutstanding, rule.notifyOnRecovery, !quiet {
                        effects += notify(.stable, rule, descriptor, &incident, severity: .info, now: now,
                                          title: "\(incident.subject.name) has been stable", body: "It stopped changing state and has recovered.", track: &track)
                    }
                    incident.noticeOutstanding = false
                    incidents[incident.id] = incident
                    effects.append(.incident(incident))
                } else if !incident.flapping, let resolved = incident.resolvedAt,
                          now.timeIntervalSince(resolved) > policy.reopenWindow {
                    incidents[incident.id] = nil
                }
            }
        }
        // Idle tracks only matter for cooldown spacing, which is bounded by a day.
        for (key, track) in tracks where track.run == nil && track.incidentID.flatMap({ incidents[$0] }) == nil {
            let latest = max(track.lastOpenNoticeAt ?? .distantPast, track.lastEventNoticeAt ?? .distantPast)
            if now.timeIntervalSince(latest) > 86_400 { tracks[key] = nil }
        }
        return effects
    }

    // MARK: Events

    private mutating func handleEvent(_ rule: AlertRule, _ descriptor: TriggerDescriptor,
                                      _ signal: AlertSignal, _ now: Date) -> [Effect] {
        let key = TrackKey(rule: rule.id, subject: signal.subject.key)
        var track = tracks[key] ?? Track(subject: signal.subject)
        defer { tracks[key] = track }
        let severity = rule.effectiveSeverity(descriptor)
        var entry = makeEntry(.event, rule, signal.subject, incident: nil, title: signal.title, detail: signal.detail,
                              severity: severity, now: now)
        if rule.cooldownSeconds > 0, let last = track.lastEventNoticeAt, now.timeIntervalSince(last) < TimeInterval(rule.cooldownSeconds) {
            entry.suppressedReason = "cooldown"
            return [.history(entry, nil)]
        }
        if isQuiet(rule, severity, now) {
            entry.suppressedReason = "quiet hours"
            return [.history(entry, nil)]
        }
        track.lastEventNoticeAt = now
        return [.history(entry, makeNotification(.event, rule, signal.subject, title: signal.title, body: signal.detail,
                                                 severity: severity, basis: signal.basis))]
    }

    // MARK: Conditions

    private mutating func handleCondition(_ rule: AlertRule, _ descriptor: TriggerDescriptor, _ signal: AlertSignal,
                                          _ state: ConditionState, _ now: Date) -> [Effect] {
        let key = TrackKey(rule: rule.id, subject: signal.subject.key)
        var track = tracks[key] ?? Track(subject: signal.subject)
        track.subject = signal.subject
        defer { tracks[key] = track }
        var effects: [Effect] = []
        var state = state, signal = signal

        // A measurement is judged against this rule's own limit.
        if case .measurement(let value, let maxGap) = state {
            guard let spec = descriptor.limit, let limit = rule.limit ?? Optional(spec.defaultValue) else { return [] }
            if value > Double(limit) {
                state = .active(.init(confirmed: true, maxGap: maxGap))
                signal = AlertSignal(trigger: signal.trigger, subject: signal.subject, shape: signal.shape, title: signal.title,
                                     detail: "\(signal.detail) (limit \(limit) \(spec.unit))", basis: signal.basis,
                                     observedAt: signal.observedAt, recoveryTitle: signal.recoveryTitle, recoveryDetail: signal.recoveryDetail)
            } else {
                state = .clear
                signal = AlertSignal(trigger: signal.trigger, subject: signal.subject, shape: signal.shape,
                                     title: signal.recoveryTitle ?? signal.title, detail: signal.recoveryDetail ?? signal.detail,
                                     basis: signal.basis, observedAt: signal.observedAt)
            }
        }

        switch state {
        case .inconclusive:
            // No evidence either way: keep pending evidence and unverified incidents as they are.
            return []

        case .measurement:
            return []   // already resolved to active or clear above

        case .clear:
            if track.run != nil {
                track.run = nil
                effects.append(.clearEvidence(ruleID: rule.id, subjectKey: signal.subject.key))
            }
            if var incident = openIncident(track) {
                effects += recover(&incident, rule, descriptor, signal, now: now, track: &track)
            }

        case .active(let evidence):
            var run: Run
            if var current = track.run, now >= current.lastFreshAt, now.timeIntervalSince(current.lastFreshAt) <= evidence.maxGap {
                current.count += 1; current.lastFreshAt = now; run = current
            } else {
                // A gap longer than the producer trusts (sleep, restart, outage of the
                // producer itself) means earlier evidence is stale: start a new run.
                run = Run(since: evidence.since ?? now, count: 1, lastFreshAt: now, persistedAt: nil)
            }
            if let hint = evidence.since, hint < run.since { run.since = hint }

            if var incident = openIncident(track) {
                var changed = false
                if incident.verification == .unverified { incident.verification = .verified; changed = true }
                if incident.detail != signal.detail || incident.title != signal.title {
                    incident.title = signal.title; incident.detail = signal.detail; changed = true
                }
                // The kind of evidence can change while an incident is open, for example a
                // reported fault becoming a report that stopped arriving.
                if incident.basis != signal.basis { incident.basis = signal.basis; changed = true }
                if incident.subject.name != signal.subject.name || incident.subject.groupName != signal.subject.groupName {
                    incident.subject = signal.subject; changed = true
                }
                if changed { incidents[incident.id] = incident; effects.append(.incident(incident)) }
                track.run = run
                return effects
            }

            track.run = run
            if thresholdMet(rule.threshold, run, evidence, now) {
                effects += open(rule, descriptor, signal, run: run, now: now, track: &track)
                // The run is now an incident; its evidence no longer needs to be persisted.
                if track.run?.persistedAt != nil { effects.append(.clearEvidence(ruleID: rule.id, subjectKey: signal.subject.key)) }
                track.run?.persistedAt = nil
            } else {
                effects += persistEvidence(&track.run, rule, signal.subject, now)
            }
        }
        return effects
    }

    private func thresholdMet(_ threshold: Threshold, _ run: Run, _ evidence: ConditionEvidence, _ now: Date) -> Bool {
        switch threshold.kind {
        case .immediately: true
        case .sourceDefault: evidence.confirmed
        case .afterSeconds: now.timeIntervalSince(run.since) >= TimeInterval(threshold.value)
        case .failedChecks: max(run.count, evidence.failures ?? 0) >= threshold.value
        }
    }

    private func persistEvidence(_ run: inout Run?, _ rule: AlertRule, _ subject: SubjectRef, _ now: Date) -> [Effect] {
        guard var current = run else { return [] }
        if let last = current.persistedAt, now.timeIntervalSince(last) < policy.evidenceWriteInterval { return [] }
        current.persistedAt = now
        run = current
        return [.evidence(EvidenceRecord(ruleID: rule.id, subjectKey: subject.key, since: current.since,
                                         lastFreshAt: current.lastFreshAt, count: current.count))]
    }

    private mutating func open(_ rule: AlertRule, _ descriptor: TriggerDescriptor, _ signal: AlertSignal,
                               run: Run, now: Date, track: inout Track) -> [Effect] {
        let severity = rule.effectiveSeverity(descriptor)
        var incident: AlertIncident
        var effects: [Effect] = []
        if let previous = track.incidentID.flatMap({ incidents[$0] }), previous.state == .resolved,
           previous.resolution == .recovered,
           let resolved = previous.resolvedAt, now.timeIntervalSince(resolved) <= policy.reopenWindow || previous.flapping {
            incident = previous
            incident.state = .open; incident.resolution = nil; incident.resolvedAt = nil
            incident.flapCount += 1
        } else {
            incident = AlertIncident(
                id: UUID().uuidString.lowercased(), ruleID: rule.id, ruleName: rule.name, trigger: rule.trigger,
                subject: signal.subject, severity: severity, basis: signal.basis, state: .open, resolution: nil,
                verification: .verified, title: signal.title, detail: signal.detail,
                openedAt: run.since <= now ? min(run.since, now) : now, stateChangedAt: now, resolvedAt: nil,
                lastNotifiedAt: nil, notificationCount: 0, flapCount: 0, flapping: false,
                noticeOutstanding: false, needsOpenNotice: false)
        }
        incident.ruleName = rule.name; incident.severity = severity; incident.basis = signal.basis
        incident.title = signal.title; incident.detail = signal.detail; incident.subject = signal.subject
        incident.verification = .verified; incident.stateChangedAt = now

        if incident.flapCount >= policy.flapThreshold {
            if !incident.flapping {
                incident.flapping = true
                effects += notify(.flapping, rule, descriptor, &incident, severity: severity, now: now,
                                  title: "\(signal.subject.name) keeps changing state",
                                  body: "It has gone down and recovered repeatedly. Ruru will pause individual notifications until it holds one state for \(Threshold.durationText(Int(policy.stableAfter))).",
                                  track: &track)
            } else {
                effects.append(.history(makeEntry(.opened, rule, signal.subject, incident: incident, title: signal.title,
                                                  detail: signal.detail, severity: severity, now: now, suppressed: "flapping"), nil))
            }
            incident.needsOpenNotice = false
        } else if !cooldownElapsed(rule, track.lastOpenNoticeAt, now) {
            incident.needsOpenNotice = true
            effects.append(.history(makeEntry(.opened, rule, signal.subject, incident: incident, title: signal.title,
                                              detail: signal.detail, severity: severity, now: now, suppressed: "cooldown"), nil))
        } else if isQuiet(rule, severity, now) {
            incident.needsOpenNotice = true
            effects.append(.history(makeEntry(.opened, rule, signal.subject, incident: incident, title: signal.title,
                                              detail: signal.detail, severity: severity, now: now, suppressed: "quiet hours"), nil))
        } else {
            effects += notify(.opened, rule, descriptor, &incident, severity: severity, now: now,
                              title: signal.title, body: signal.detail, track: &track)
            incident.needsOpenNotice = false
        }
        incidents[incident.id] = incident
        track.incidentID = incident.id
        effects.append(.incident(incident))
        return effects
    }

    private mutating func recover(_ incident: inout AlertIncident, _ rule: AlertRule, _ descriptor: TriggerDescriptor,
                                  _ signal: AlertSignal, now: Date, track: inout Track) -> [Effect] {
        var effects: [Effect] = []
        let severity = incident.severity
        incident.state = .resolved; incident.resolution = .recovered; incident.resolvedAt = now
        incident.stateChangedAt = now; incident.verification = .verified
        let hadOutstanding = incident.noticeOutstanding
        incident.needsOpenNotice = false

        func record(_ reason: String?, notification: OutgoingNotification?) -> Effect {
            .history(makeEntry(.recovered, rule, incident.subject, incident: incident, title: signal.title,
                               detail: signal.detail, severity: .info, now: now, suppressed: reason), notification)
        }
        if incident.flapping {
            // Stabilisation in tick() sends one "stable again" notice later.
            effects.append(record("flapping", notification: nil))
        } else if !rule.notifyOnRecovery {
            effects.append(record(nil, notification: nil))
            incident.noticeOutstanding = false
        } else if !hadOutstanding {
            // Nothing was ever sent for this outage, so there is nothing to recover from.
            effects.append(record("no earlier notification", notification: nil))
        } else if isQuiet(rule, severity, now) {
            effects.append(record("quiet hours", notification: nil))
            incident.noticeOutstanding = false
        } else {
            let note = makeNotification(.recovered, rule, incident.subject, title: signal.title, body: signal.detail,
                                        severity: .info, basis: signal.basis)
            effects.append(record(nil, notification: note))
            incident.noticeOutstanding = false
            incident.lastNotifiedAt = now; incident.notificationCount += 1
        }
        incidents[incident.id] = incident
        effects.append(.incident(incident))
        return effects
    }

    private mutating func archive(_ incident: AlertIncident, _ reason: IncidentResolution, now: Date) -> [Effect] {
        var closed = incident
        closed.state = .resolved; closed.resolution = reason; closed.resolvedAt = now; closed.stateChangedAt = now
        closed.noticeOutstanding = false; closed.needsOpenNotice = false; closed.flapping = false
        incidents[closed.id] = nil
        let key = TrackKey(rule: incident.ruleID, subject: incident.subject.key)
        if tracks[key]?.run != nil { tracks[key]?.run = nil }
        tracks[key]?.incidentID = nil
        let entry = AlertHistoryEntry(
            id: 0, time: now, ruleID: incident.ruleID, ruleName: incident.ruleName, incidentID: incident.id,
            trigger: incident.trigger, subjectName: incident.subject.name, kind: .archived, title: incident.title,
            detail: reason.title + ". Ruru did not observe a recovery.", severity: .info,
            showInActivity: rules[incident.ruleID]?.recordActivity ?? false, suppressedReason: nil, deliveries: [])
        return [.incident(closed), .history(entry, nil), .clearEvidence(ruleID: incident.ruleID, subjectKey: incident.subject.key)]
    }

    // MARK: Helpers

    private func openIncident(_ track: Track) -> AlertIncident? {
        guard let id = track.incidentID, let incident = incidents[id], incident.isOpen else { return nil }
        return incident
    }

    private func cooldownElapsed(_ rule: AlertRule, _ last: Date?, _ now: Date) -> Bool {
        guard rule.cooldownSeconds > 0, let last else { return true }
        return now.timeIntervalSince(last) >= TimeInterval(rule.cooldownSeconds)
    }

    private func isQuiet(_ rule: AlertRule, _ severity: AlertSeverity, _ now: Date) -> Bool {
        guard let quiet = rule.quietHours else { return false }
        if quiet.allowCritical, severity == .critical { return false }
        return quiet.contains(now, calendar: policy.calendar)
    }

    private mutating func notify(_ kind: AlertHistoryEntry.Kind, _ rule: AlertRule, _ descriptor: TriggerDescriptor,
                                 _ incident: inout AlertIncident, severity: AlertSeverity, now: Date,
                                 title: String, body: String, track: inout Track) -> [Effect] {
        incident.lastNotifiedAt = now
        incident.notificationCount += 1
        if kind == .opened || kind == .flapping { incident.noticeOutstanding = true }
        if kind == .opened { track.lastOpenNoticeAt = now }
        let entry = makeEntry(kind, rule, incident.subject, incident: incident, title: title, detail: body,
                              severity: severity, now: now)
        return [.history(entry, makeNotification(kind, rule, incident.subject, title: title, body: body,
                                                 severity: severity, basis: incident.basis))]
    }

    private func makeEntry(_ kind: AlertHistoryEntry.Kind, _ rule: AlertRule, _ subject: SubjectRef,
                           incident: AlertIncident?, title: String, detail: String, severity: AlertSeverity,
                           now: Date, suppressed: String? = nil) -> AlertHistoryEntry {
        AlertHistoryEntry(id: 0, time: now, ruleID: rule.id, ruleName: rule.name, incidentID: incident?.id,
                          trigger: rule.trigger, subjectName: subject.name, kind: kind, title: title, detail: detail,
                          severity: severity, showInActivity: rule.recordActivity, suppressedReason: suppressed, deliveries: [])
    }

    private func makeNotification(_ kind: AlertHistoryEntry.Kind, _ rule: AlertRule, _ subject: SubjectRef,
                                  title: String, body: String, severity: AlertSeverity, basis: AlertBasis) -> OutgoingNotification {
        OutgoingNotification(entryID: 0, ruleID: rule.id, ruleName: rule.name, trigger: rule.trigger, kind: kind,
                             title: title, body: body, severity: severity, basis: basis, subjectName: subject.name,
                             groupName: subject.groupName, choice: rule.delivery)
    }
}
