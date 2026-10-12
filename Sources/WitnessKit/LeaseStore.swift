import DuckDB
import Foundation

/// A serialized, durable authority. All live deadlines use one monotonic epoch.
public actor LeaseStore {
    /// Default grant length. Each service may choose its own within `leaseDurationRange`.
    public static let leaseDuration: Double = 30
    public static let leaseDurationRange: ClosedRange<Double> = 10...300
    /// Per-service ownership history kept on disk, and the newest shown per service.
    static let eventsKeptPerService = 256
    static let eventsShownPerService = 64
    /// Informational participant activity is retained separately from ownership.
    public static let participantEventsKeptPerService = 256
    private let database: DuckDBDatabase
    private let instanceLock: DatabaseInstanceLock
    private let legacyLock: DatabaseInstanceLock
    private let clock: @Sendable () -> Double
    private let recoveringUntil: Double
    private var currentClusters: Set<String> = []

    public init(databaseURL: URL, clock: (@Sendable () -> Double)? = nil) throws {
        guard databaseURL.pathExtension == "duckdb" else { throw WitnessError.invalidConfiguration }
        let directory = databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let legacyURL = databaseURL.deletingPathExtension().appendingPathExtension("sqlite")
        // Retain the original lock throughout this process, so an older app
        // cannot run concurrently while we set up or serve the new authority.
        let legacyLock = try DatabaseInstanceLock(url: legacyURL.appendingPathExtension("lock"))
        let instanceLock = try DatabaseInstanceLock(url: databaseURL.appendingPathExtension("lock"))
        let database = try LeaseDatabaseSetup.prepare(url: databaseURL, legacyURL: legacyURL)
        let origin = ContinuousClock.now
        let monotonic = clock ?? {
            let elapsed = origin.duration(to: ContinuousClock.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
        let quarantine = try database.open { connection in
            // Additive, non-authoritative activity history migration. It must
            // never change lease rows, terms, or restart quarantine.
            try database.execute(connection, "CREATE TABLE IF NOT EXISTS participant_events (id BIGINT PRIMARY KEY, time DOUBLE NOT NULL, kind VARCHAR NOT NULL, cluster VARCHAR NOT NULL, node VARCHAR NOT NULL, node_name VARCHAR NOT NULL, detail VARCHAR NOT NULL)")
            // Databases created before per-service lease lengths granted 30 seconds.
            try database.execute(connection, "ALTER TABLE leases ADD COLUMN IF NOT EXISTS duration DOUBLE DEFAULT 30")
            let leases = try connection.query("SELECT cluster, owner, term, expires, duration FROM leases")
            var longest: Double = 0
            for row in 0..<leases.rowCount {
                let term = try leases.integer(2, row: row), expiry = try leases.number(3, row: row)
                let duration = try leases.number(4, row: row)
                guard LeaseDatabaseSetup.validTerm(term), expiry >= 0,
                      Self.leaseDurationRange.contains(duration) else { throw Self.damagedLease() }
                // Released leases store expiry 0. A non-zero expiry is a live or
                // restored lease (restores are ownerless); wait out the longest.
                if expiry > 0 { longest = max(longest, duration) }
            }
            // Missing tables also fail startup. Ordinary startup never creates
            // empty replacements for missing durable state.
            _ = try connection.query("SELECT id, time, action, cluster, node, term FROM events LIMIT 0")
            _ = try connection.query("SELECT cluster, node, name FROM node_names LIMIT 0")
            _ = try connection.query("SELECT id, time, kind, cluster, node, node_name, detail FROM participant_events LIMIT 0")
            return longest
        }
        self.database = database
        self.instanceLock = instanceLock
        self.legacyLock = legacyLock
        self.clock = monotonic
        // Never clear the durable expiry on restart: a repeated crash must wait
        // the full lease again. Prior-process leases are never marked current.
        recoveringUntil = quarantine > 0 ? monotonic() + quarantine : 0
    }

    public func apply(_ action: LeaseAction, request: LeaseRequest,
                      leaseDuration duration: Double = LeaseStore.leaseDuration) -> LeaseReply {
        guard Self.leaseDurationRange.contains(duration), !request.clusterID.isEmpty, request.clusterID.utf8.count <= 128,
              !request.nodeID.isEmpty, request.nodeID.utf8.count <= 128,
              request.term >= 0, request.term < (1 << 62) else {
            return .error("invalid_request", status: 400)
        }
        let now = clock()
        guard now >= recoveringUntil else { return .error("authority_recovering", status: 503) }
        do {
            return try database.open { connection in
                try database.execute(connection, "BEGIN TRANSACTION")
                do {
                    let previous = try readLease(connection, clusterID: request.clusterID)
                    let live = previous.map { $0.epochIsCurrent && $0.expiry > now } ?? false
                    let reply: LeaseReply
                    switch action {
                    case .acquire:
                        if live, let previous {
                            guard previous.owner == request.nodeID, request.term <= previous.term else {
                                try database.execute(connection, "ROLLBACK")
                                return .error("ownership_held", status: 409)
                            }
                            reply = try .grant(LeaseGrant(ownerNodeID: previous.owner, term: previous.term,
                                                        expiresInSeconds: previous.expiry - now))
                        } else {
                            guard max(previous?.term ?? 0, request.term) < (1 << 62) - 1 else {
                                try database.execute(connection, "ROLLBACK")
                                return .error("authority_term_exhausted", status: 503)
                            }
                            let term = max(previous?.term ?? 0, request.term) + 1
                            try writeLease(connection, clusterID: request.clusterID, owner: request.nodeID,
                                           term: term, expiry: now + duration, duration: duration)
                            try log(connection, action: "Acquired", request: request, term: term)
                            reply = try .grant(LeaseGrant(ownerNodeID: request.nodeID, term: term,
                                                        expiresInSeconds: duration))
                        }
                    case .renew, .release:
                        guard live, let previous, previous.owner == request.nodeID, previous.term == request.term else {
                            try database.execute(connection, "ROLLBACK")
                            return .error("ownership_expired_or_changed", status: 409)
                        }
                        if action == .release {
                            try writeLease(connection, clusterID: request.clusterID, owner: "", term: request.term,
                                           expiry: 0, duration: duration)
                            try log(connection, action: "Released", request: request, term: request.term)
                            reply = .released
                        } else {
                            // A lost renewal response leaves the owner trusting its
                            // earlier grant. Never shorten that outstanding permission
                            // when the operator reduces the configured lease length.
                            let remaining = max(duration, previous.expiry - now)
                            try writeLease(connection, clusterID: request.clusterID, owner: request.nodeID,
                                           term: request.term, expiry: now + remaining, duration: remaining)
                            reply = try .grant(LeaseGrant(ownerNodeID: request.nodeID, term: request.term,
                                                        expiresInSeconds: remaining))
                        }
                    }
                    try writeNodeName(connection, request: request)
                    try database.execute(connection, "COMMIT")
                    // Nothing becomes live in this epoch until durable COMMIT.
                    currentClusters.insert(request.clusterID)
                    return reply
                } catch {
                    try? database.execute(connection, "ROLLBACK")
                    throw error
                }
            }
        } catch { return .error("authority_unavailable", status: 503) }
    }

    public func snapshot() throws -> WitnessSnapshot {
        let now = clock()
        return try database.open { connection in
            let result = try connection.query("SELECT l.cluster, l.owner, l.term, l.expires, n.name FROM leases l LEFT JOIN node_names n ON n.cluster=l.cluster AND n.node=l.owner ORDER BY l.cluster")
            var leases: [LeaseStatus] = []
            for row in 0..<result.rowCount {
                let cluster = try result.string(0, row: row)
                let term = try result.integer(2, row: row), expiry = try result.number(3, row: row)
                try validateStoredTerm(term, expiry: expiry)
                leases.append(LeaseStatus(clusterID: cluster, ownerNodeID: try result.string(1, row: row), term: term,
                    remainingSeconds: currentClusters.contains(cluster) ? max(0, expiry - now) : 0,
                    ownerNodeName: WitnessNodeName.normalized(result[4].cast(to: String.self)[row])))
            }
            // The newest events per service, so a busy service cannot hide others.
            let history = try connection.query("SELECT e.id, e.time, e.action, e.node, e.term, n.name, e.cluster FROM (SELECT *, row_number() OVER (PARTITION BY cluster ORDER BY id DESC) AS position FROM events) e LEFT JOIN node_names n ON n.cluster=e.cluster AND n.node=e.node WHERE e.position <= \(Self.eventsShownPerService) ORDER BY e.id DESC")
            var events: [WitnessEvent] = []
            for row in 0..<history.rowCount {
                events.append(WitnessEvent(clusterID: try history.string(6, row: row), id: try history.integer(0, row: row),
                    time: Date(timeIntervalSince1970: try history.number(1, row: row)),
                    action: try history.string(2, row: row), nodeID: try history.string(3, row: row),
                    term: try history.integer(4, row: row), nodeName: WitnessNodeName.normalized(history[5].cast(to: String.self)[row])))
            }
            let participantRows = try connection.query("SELECT id, time, kind, cluster, node, node_name, detail FROM (SELECT *, row_number() OVER (PARTITION BY cluster ORDER BY id DESC) AS position FROM participant_events) activity WHERE position <= \(Self.eventsShownPerService) ORDER BY id DESC")
            var participantActivity: [ParticipantActivityRecord] = []
            for row in 0..<participantRows.rowCount {
                participantActivity.append(ParticipantActivityRecord(
                    id: try participantRows.integer(0, row: row), clusterID: try participantRows.string(3, row: row),
                    nodeID: try participantRows.string(4, row: row), nodeName: try participantRows.string(5, row: row),
                    time: Date(timeIntervalSince1970: try participantRows.number(1, row: row)),
                    kind: try participantRows.string(2, row: row), detail: try participantRows.string(6, row: row)))
            }
            return WitnessSnapshot(recoverySeconds: max(0, recoveringUntil - now), leases: leases,
                                   events: events, participantActivity: participantActivity)
        }
    }

    /// Persist a participant transition as informational history. This API
    /// enforces bounds even though the caller uses report-derived identifiers.
    public func recordParticipantActivity(clusterID: String, nodeID: String, nodeName: String,
                                          kind: String, detail: String, at date: Foundation.Date = Foundation.Date()) throws -> ParticipantActivityRecord {
        let allowedKinds: Set<String> = ["onBattery", "lowBattery", "powerRestored", "sessionEnding"]
        guard !clusterID.isEmpty, clusterID.utf8.count <= 128,
              !nodeID.isEmpty, nodeID.utf8.count <= 128,
              allowedKinds.contains(kind), date.timeIntervalSince1970.isFinite,
              let safeName = WitnessNodeName.normalized(nodeName),
              !detail.isEmpty, detail.utf8.count <= 1024,
              detail.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw WitnessError.invalidConfiguration
        }
        return try database.open { connection in
            let nextID = try connection.query("SELECT COALESCE(MAX(id), 0)+1 FROM participant_events").integer(0)
            _ = try database.query(connection, "INSERT INTO participant_events VALUES (?, ?, ?, ?, ?, ?, ?)") {
                try $0.bind(nextID, at: 1)
                try $0.bind(date.timeIntervalSince1970, at: 2); try $0.bind(kind, at: 3)
                try $0.bind(clusterID, at: 4); try $0.bind(nodeID, at: 5)
                try $0.bind(safeName, at: 6); try $0.bind(detail, at: 7)
            }
            _ = try database.query(connection, "DELETE FROM participant_events WHERE cluster=? AND id NOT IN (SELECT id FROM participant_events WHERE cluster=? ORDER BY id DESC LIMIT \(Self.participantEventsKeptPerService))") {
                try $0.bind(clusterID, at: 1); try $0.bind(clusterID, at: 2)
            }
            return ParticipantActivityRecord(id: nextID, clusterID: clusterID, nodeID: nodeID,
                nodeName: safeName, time: date, kind: kind, detail: detail)
        }
    }

    /// One service's current lease and the authority's recovery state, for
    /// `GET /v1/service`. Ownership from a previous process is never reported live.
    public func status(for clusterID: String) throws -> (lease: LeaseStatus?, recoverySeconds: Double) {
        let now = clock()
        return try database.open { connection in
            let recovery = max(0, recoveringUntil - now)
            guard let stored = try readLease(connection, clusterID: clusterID) else { return (nil, recovery) }
            let live = stored.epochIsCurrent && stored.expiry > now && !stored.owner.isEmpty
            return (LeaseStatus(clusterID: clusterID, ownerNodeID: live ? stored.owner : "", term: stored.term,
                                remainingSeconds: live ? stored.expiry - now : 0), recovery)
        }
    }

    /// A consistent, secret-free copy of terms, history and reported names.
    public func makeSnapshot() throws -> LeaseSnapshot {
        try database.open { connection in
            let leaseRows = try connection.query("SELECT cluster, owner, term, expires FROM leases ORDER BY cluster")
            var leases: [LeaseSnapshot.Lease] = []
            for row in 0..<leaseRows.rowCount {
                let term = try leaseRows.integer(2, row: row)
                try validateStoredTerm(term, expiry: try leaseRows.number(3, row: row))
                leases.append(.init(clusterID: try leaseRows.string(0, row: row),
                                    ownerNodeID: try leaseRows.string(1, row: row), term: term))
            }
            let eventRows = try connection.query("SELECT id, time, action, cluster, node, term FROM events ORDER BY id")
            var events: [LeaseSnapshot.Event] = []
            for row in 0..<eventRows.rowCount {
                events.append(.init(id: try eventRows.integer(0, row: row),
                                    time: Date(timeIntervalSince1970: try eventRows.number(1, row: row)),
                                    action: try eventRows.string(2, row: row), clusterID: try eventRows.string(3, row: row),
                                    nodeID: try eventRows.string(4, row: row), term: try eventRows.integer(5, row: row)))
            }
            let nameRows = try connection.query("SELECT cluster, node, name FROM node_names ORDER BY cluster, node")
            var names: [LeaseSnapshot.NodeName] = []
            for row in 0..<nameRows.rowCount {
                names.append(.init(clusterID: try nameRows.string(0, row: row), nodeID: try nameRows.string(1, row: row),
                                   name: try nameRows.string(2, row: row)))
            }
            let participantRows = try connection.query("SELECT id, time, kind, cluster, node, node_name, detail FROM participant_events ORDER BY id")
            var participantEvents: [LeaseSnapshot.ParticipantEvent] = []
            for row in 0..<participantRows.rowCount {
                participantEvents.append(.init(id: try participantRows.integer(0, row: row),
                    time: Date(timeIntervalSince1970: try participantRows.number(1, row: row)),
                    kind: try participantRows.string(2, row: row), clusterID: try participantRows.string(3, row: row),
                    nodeID: try participantRows.string(4, row: row), nodeName: try participantRows.string(5, row: row),
                    detail: try participantRows.string(6, row: row)))
            }
            let snapshot = LeaseSnapshot(createdAt: Date(), leases: leases, events: events, nodeNames: names,
                                         participantEvents: participantEvents)
            try snapshot.validate()
            return snapshot
        }
    }

    /// Checkpoints and returns every stored term, for a restore that is about to
    /// replace this database. Call only after the listener has stopped.
    public func checkpointedTerms() throws -> [String: Int64] {
        try database.open { connection in
            try database.execute(connection, "CHECKPOINT")
            let result = try connection.query("SELECT cluster, term FROM leases")
            var terms: [String: Int64] = [:]
            for row in 0..<result.rowCount {
                let term = try result.integer(1, row: row)
                guard LeaseDatabaseSetup.validTerm(term) else { throw Self.damagedLease() }
                terms[try result.string(0, row: row)] = term
            }
            return terms
        }
    }

    #if DEBUG
    /// Test-only fault injection uses the same connection, rather than opening a
    /// second DuckDB instance on a file owned by the running authority.
    func executeStorageSQL(_ sql: String) throws {
        try database.open { try database.execute($0, sql) }
    }
    #endif

    private struct StoredLease {
        let owner: String
        let term: Int64
        let expiry: Double
        let epochIsCurrent: Bool
    }

    private func readLease(_ connection: Connection, clusterID: String) throws -> StoredLease? {
        let result = try database.query(connection, "SELECT owner, term, expires FROM leases WHERE cluster=?") {
            try $0.bind(clusterID, at: 1)
        }
        guard result.rowCount > 0 else { return nil }
        let term = try result.integer(1), expiry = try result.number(2)
        try validateStoredTerm(term, expiry: expiry)
        return StoredLease(owner: try result.string(0), term: term, expiry: expiry,
                           epochIsCurrent: currentClusters.contains(clusterID))
    }

    private func validateStoredTerm(_ term: Int64, expiry: Double) throws {
        guard LeaseDatabaseSetup.validTerm(term), expiry.isFinite, expiry >= 0 else { throw Self.damagedLease() }
    }

    private static func damagedLease() -> WitnessError {
        .database("The stored ownership term, expiry or duration is damaged; no fresh authority will be created.")
    }

    private func writeLease(_ connection: Connection, clusterID: String, owner: String, term: Int64,
                            expiry: Double, duration: Double) throws {
        _ = try database.query(connection, "INSERT INTO leases (cluster, owner, term, expires, duration) VALUES (?, ?, ?, ?, ?) ON CONFLICT (cluster) DO UPDATE SET owner=excluded.owner, term=excluded.term, expires=excluded.expires, duration=excluded.duration") {
            try $0.bind(clusterID, at: 1); try $0.bind(owner, at: 2)
            try $0.bind(term, at: 3); try $0.bind(expiry, at: 4); try $0.bind(duration, at: 5)
        }
    }

    private func log(_ connection: Connection, action: String, request: LeaseRequest, term: Int64) throws {
        _ = try database.query(connection, "INSERT INTO events SELECT COALESCE(MAX(id), 0)+1, ?, ?, ?, ?, ? FROM events") {
            try $0.bind(Date().timeIntervalSince1970, at: 1); try $0.bind(action, at: 2)
            try $0.bind(request.clusterID, at: 3); try $0.bind(request.nodeID, at: 4); try $0.bind(term, at: 5)
        }
        _ = try database.query(connection, "DELETE FROM events WHERE cluster=? AND id NOT IN (SELECT id FROM events WHERE cluster=? ORDER BY id DESC LIMIT \(Self.eventsKeptPerService))") {
            try $0.bind(request.clusterID, at: 1); try $0.bind(request.clusterID, at: 2)
        }
    }

    private func writeNodeName(_ connection: Connection, request: LeaseRequest) throws {
        if let name = WitnessNodeName.normalized(request.nodeName) {
            _ = try database.query(connection, "INSERT INTO node_names VALUES (?, ?, ?) ON CONFLICT (cluster, node) DO UPDATE SET name=excluded.name WHERE node_names.name != excluded.name") {
                try $0.bind(request.clusterID, at: 1); try $0.bind(request.nodeID, at: 2); try $0.bind(name, at: 3)
            }
        }
        try database.execute(connection, "DELETE FROM node_names WHERE NOT EXISTS (SELECT 1 FROM leases WHERE leases.cluster=node_names.cluster AND leases.owner=node_names.node) AND NOT EXISTS (SELECT 1 FROM events WHERE events.cluster=node_names.cluster AND events.node=node_names.node)")
    }
}
