import DuckDB
import Foundation

public enum AlertStorageStatus: Sendable, Equatable {
    case ready
    /// A damaged file was set aside and a new store created; history before this is in `movedTo`.
    case recovered(movedTo: String)
    /// Incidents and history cannot be saved; alerts keep working in memory.
    case unavailable(String)

    public var isUsable: Bool { if case .unavailable = self { false } else { true } }
}

/// Alert incidents, history, pending evidence and monitoring rollups. It lives in
/// its own database file and shares nothing with the lease authority: a damaged
/// or missing file here can never affect leases, terms, fencing or quarantine.
public actor AlertStore {
    public static let schemaVersion = "1"
    public static let historyKept = 2_000
    public static let incidentsKept = 1_000
    public static let incidentRetention: TimeInterval = 180 * 86_400
    public static let rollupRetention: TimeInterval = 90 * 86_400
    static let bucketSeconds: Double = 3_600

    private let connection: Connection
    private let url: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private init(connection: Connection, url: URL) { self.connection = connection; self.url = url }

    /// Opens the store, setting a damaged file aside rather than ever deleting it.
    public static func open(at url: URL, now: Foundation.Date = Foundation.Date()) -> (store: AlertStore?, status: AlertStorageStatus) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
        } catch { return (nil, .unavailable("Ruru can't create its alert storage folder.")) }
        let existed = FileManager.default.fileExists(atPath: url.path)
        if existed {
            if let connection = try? connect(url), (try? validate(connection)) != nil {
                return (AlertStore(connection: connection, url: url), .ready)
            }
            guard let moved = setAside(url, now: now) else {
                return (nil, .unavailable("Alert history is damaged and could not be set aside."))
            }
            return create(url, status: .recovered(movedTo: moved))
        }
        return create(url, status: .ready)
    }

    private static func create(_ url: URL, status: AlertStorageStatus) -> (AlertStore?, AlertStorageStatus) {
        do {
            let connection = try connect(url)
            try createSchema(connection)
            return (AlertStore(connection: connection, url: url), status)
        } catch {
            return (nil, .unavailable("Alert history couldn't be opened: \(error.localizedDescription)"))
        }
    }

    private static func connect(_ url: URL) throws -> Connection {
        let settings = Database.Configuration()
        // Small and bounded: this runs beside the authority on an older Mac.
        try settings.setValue("1", forKey: "threads")
        try settings.setValue("32MB", forKey: "memory_limit")
        try settings.setValue("false", forKey: "enable_external_access")
        return try Database(store: .file(at: url), configuration: settings).connect()
    }

    private static func createSchema(_ connection: Connection) throws {
        _ = try connection.query("""
            CREATE TABLE meta (key VARCHAR PRIMARY KEY, value VARCHAR NOT NULL);
            CREATE TABLE incidents (id VARCHAR PRIMARY KEY, rule_id VARCHAR NOT NULL, subject_key VARCHAR NOT NULL, state VARCHAR NOT NULL, opened_at DOUBLE NOT NULL, resolved_at DOUBLE NOT NULL, body VARCHAR NOT NULL);
            CREATE TABLE history (id BIGINT PRIMARY KEY, time DOUBLE NOT NULL, rule_id VARCHAR NOT NULL, show_activity BIGINT NOT NULL, body VARCHAR NOT NULL, deliveries VARCHAR NOT NULL);
            CREATE TABLE evidence (rule_id VARCHAR NOT NULL, subject_key VARCHAR NOT NULL, since DOUBLE NOT NULL, last_fresh DOUBLE NOT NULL, count BIGINT NOT NULL, PRIMARY KEY (rule_id, subject_key));
            CREATE TABLE monitor_rollups (target_id VARCHAR NOT NULL, bucket BIGINT NOT NULL, checks BIGINT NOT NULL, ok BIGINT NOT NULL, inconclusive BIGINT NOT NULL, latency_sum BIGINT NOT NULL, latency_count BIGINT NOT NULL, PRIMARY KEY (target_id, bucket));
            INSERT INTO meta VALUES ('schema', '\(schemaVersion)');
            """)
    }

    private static func validate(_ connection: Connection) throws {
        let version = try connection.query("SELECT value FROM meta WHERE key = 'schema'")
        guard version.rowCount == 1, try version.string(0) == schemaVersion else { throw StoreError.invalid }
        for table in ["incidents", "history", "evidence", "monitor_rollups"] {
            _ = try connection.query("SELECT count(*) FROM \(table)")
        }
    }

    private static func setAside(_ url: URL, now: Foundation.Date) -> String? {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-damaged-\(stamp).duckdb")
        let fileManager = FileManager.default
        do {
            try fileManager.moveItem(at: url, to: target)
            let wal = URL(fileURLWithPath: url.path + ".wal")
            if fileManager.fileExists(atPath: wal.path) {
                try? fileManager.moveItem(at: wal, to: URL(fileURLWithPath: target.path + ".wal"))
            }
            return target.lastPathComponent
        } catch { return nil }
    }

    enum StoreError: Error { case invalid }

    // MARK: Statements

    private func run(_ sql: String, _ bind: (PreparedStatement) throws -> Void = { _ in }) throws -> ResultSet {
        let statement = try PreparedStatement(connection: connection, query: sql)
        try bind(statement)
        return try statement.execute()
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        try decoder.decode(type, from: Data(text.utf8))
    }

    // MARK: Incidents

    public func save(_ incident: AlertIncident) throws {
        let body = try json(incident)
        _ = try run("INSERT OR REPLACE INTO incidents VALUES (?, ?, ?, ?, ?, ?, ?)") {
            try $0.bind(incident.id, at: 1)
            try $0.bind(incident.ruleID.uuidString, at: 2)
            try $0.bind(incident.subject.key, at: 3)
            try $0.bind(incident.state.rawValue, at: 4)
            try $0.bind(incident.openedAt.timeIntervalSince1970, at: 5)
            try $0.bind(incident.resolvedAt?.timeIntervalSince1970 ?? 0, at: 6)
            try $0.bind(body, at: 7)
        }
    }

    public func openIncidents() throws -> [AlertIncident] {
        let result = try run("SELECT body FROM incidents WHERE state = 'open' ORDER BY opened_at DESC")
        return try (0..<result.rowCount).map { try decode(AlertIncident.self, result.string(0, row: $0)) }
    }

    /// Recently resolved incidents, used so a quick return reopens rather than duplicates.
    public func resolvedIncidents(since: Foundation.Date) throws -> [AlertIncident] {
        let result = try run("SELECT body FROM incidents WHERE state = 'resolved' AND resolved_at >= ? ORDER BY resolved_at DESC") {
            try $0.bind(since.timeIntervalSince1970, at: 1)
        }
        return try (0..<result.rowCount).map { try decode(AlertIncident.self, result.string(0, row: $0)) }
    }

    public func incidents(subjectKey: String? = nil, ruleID: UUID? = nil, limit: Int = 50) throws -> [AlertIncident] {
        var clauses: [String] = [], values: [String] = []
        if let subjectKey { clauses.append("subject_key = ?"); values.append(subjectKey) }
        if let ruleID { clauses.append("rule_id = ?"); values.append(ruleID.uuidString) }
        let filter = clauses.isEmpty ? "" : "WHERE " + clauses.joined(separator: " AND ")
        let result = try run("SELECT body FROM incidents \(filter) ORDER BY opened_at DESC LIMIT \(max(1, min(limit, 500)))") { statement in
            for (index, value) in values.enumerated() { try statement.bind(value, at: index + 1) }
        }
        return try (0..<result.rowCount).map { try decode(AlertIncident.self, result.string(0, row: $0)) }
    }

    // MARK: Evidence

    public func save(_ evidence: EvidenceRecord) throws {
        _ = try run("INSERT OR REPLACE INTO evidence VALUES (?, ?, ?, ?, ?)") {
            try $0.bind(evidence.ruleID.uuidString, at: 1); try $0.bind(evidence.subjectKey, at: 2)
            try $0.bind(evidence.since.timeIntervalSince1970, at: 3)
            try $0.bind(evidence.lastFreshAt.timeIntervalSince1970, at: 4); try $0.bind(Int64(evidence.count), at: 5)
        }
    }

    public func clearEvidence(ruleID: UUID, subjectKey: String) throws {
        _ = try run("DELETE FROM evidence WHERE rule_id = ? AND subject_key = ?") {
            try $0.bind(ruleID.uuidString, at: 1); try $0.bind(subjectKey, at: 2)
        }
    }

    public func evidence() throws -> [EvidenceRecord] {
        let result = try run("SELECT rule_id, subject_key, since, last_fresh, count FROM evidence")
        return try (0..<result.rowCount).compactMap { row in
            guard let rule = UUID(uuidString: try result.string(0, row: row)) else { return nil }
            return EvidenceRecord(ruleID: rule, subjectKey: try result.string(1, row: row),
                                  since: Foundation.Date(timeIntervalSince1970: try result.number(2, row: row)),
                                  lastFreshAt: Foundation.Date(timeIntervalSince1970: try result.number(3, row: row)),
                                  count: Int(try result.integer(4, row: row)))
        }
    }

    // MARK: History

    /// Stores an entry and returns it with its assigned ID.
    public func append(_ entry: AlertHistoryEntry) throws -> AlertHistoryEntry {
        var stored = entry
        stored.id = try run("SELECT COALESCE(MAX(id), 0) + 1 FROM history").integer(0)
        let body = try json(stored), deliveries = try json(stored.deliveries)
        _ = try run("INSERT INTO history VALUES (?, ?, ?, ?, ?, ?)") {
            try $0.bind(stored.id, at: 1); try $0.bind(stored.time.timeIntervalSince1970, at: 2)
            try $0.bind(stored.ruleID.uuidString, at: 3); try $0.bind(Int64(stored.showInActivity ? 1 : 0), at: 4)
            try $0.bind(body, at: 5); try $0.bind(deliveries, at: 6)
        }
        return stored
    }

    public func setDeliveries(entryID: Int64, _ deliveries: [DeliveryOutcome]) throws {
        let text = try json(deliveries)
        _ = try run("UPDATE history SET deliveries = ? WHERE id = ?") {
            try $0.bind(text, at: 1); try $0.bind(entryID, at: 2)
        }
    }

    public func history(limit: Int = 100, ruleID: UUID? = nil) throws -> [AlertHistoryEntry] {
        let filter = ruleID == nil ? "" : "WHERE rule_id = ?"
        let result = try run("SELECT body, deliveries FROM history \(filter) ORDER BY id DESC LIMIT \(max(1, min(limit, 1_000)))") {
            if let ruleID { try $0.bind(ruleID.uuidString, at: 1) }
        }
        return try (0..<result.rowCount).map { row in
            var entry = try decode(AlertHistoryEntry.self, result.string(0, row: row))
            entry.deliveries = (try? decode([DeliveryOutcome].self, result.string(1, row: row))) ?? entry.deliveries
            return entry
        }
    }

    // MARK: Monitoring rollups

    /// Adds samples to their hourly buckets. Only conclusive checks count toward uptime.
    public func record(_ samples: [RollupSample]) throws {
        struct Key: Hashable { let target: String; let bucket: Int64 }
        struct Sum { var checks = 0, ok = 0, inconclusive = 0, latency = 0, latencyCount = 0 }
        var sums: [Key: Sum] = [:]
        for sample in samples {
            let key = Key(target: sample.targetID, bucket: Int64(sample.time.timeIntervalSince1970 / Self.bucketSeconds))
            var sum = sums[key] ?? Sum()
            if sample.inconclusive { sum.inconclusive += 1 }
            else {
                sum.checks += 1
                if sample.ok { sum.ok += 1 }
                if sample.ok, let latency = sample.latencyMilliseconds { sum.latency += latency; sum.latencyCount += 1 }
            }
            sums[key] = sum
        }
        guard !sums.isEmpty else { return }
        _ = try run("BEGIN TRANSACTION")
        do {
            for (key, sum) in sums {
                _ = try run("""
                    INSERT INTO monitor_rollups VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT (target_id, bucket) DO UPDATE SET
                      checks = monitor_rollups.checks + excluded.checks, ok = monitor_rollups.ok + excluded.ok,
                      inconclusive = monitor_rollups.inconclusive + excluded.inconclusive,
                      latency_sum = monitor_rollups.latency_sum + excluded.latency_sum,
                      latency_count = monitor_rollups.latency_count + excluded.latency_count
                    """) {
                    try $0.bind(key.target, at: 1); try $0.bind(key.bucket, at: 2); try $0.bind(Int64(sum.checks), at: 3)
                    try $0.bind(Int64(sum.ok), at: 4); try $0.bind(Int64(sum.inconclusive), at: 5)
                    try $0.bind(Int64(sum.latency), at: 6); try $0.bind(Int64(sum.latencyCount), at: 7)
                }
            }
            _ = try run("COMMIT")
        } catch {
            _ = try? run("ROLLBACK")
            throw error
        }
    }

    public func uptime(targetID: String, window: TimeInterval, now: Foundation.Date = Foundation.Date()) throws -> UptimeSummary {
        let first = Int64((now.timeIntervalSince1970 - window) / Self.bucketSeconds)
        let result = try run("""
            SELECT CAST(COALESCE(SUM(checks), 0) AS BIGINT), CAST(COALESCE(SUM(ok), 0) AS BIGINT),
                   CAST(COALESCE(SUM(inconclusive), 0) AS BIGINT), CAST(COALESCE(SUM(latency_sum), 0) AS BIGINT),
                   CAST(COALESCE(SUM(latency_count), 0) AS BIGINT)
            FROM monitor_rollups WHERE target_id = ? AND bucket >= ?
            """) { try $0.bind(targetID, at: 1); try $0.bind(first, at: 2) }
        let latencyCount = try result.integer(4)
        return UptimeSummary(checks: Int(try result.integer(0)), ok: Int(try result.integer(1)),
                             inconclusive: Int(try result.integer(2)),
                             averageLatencyMilliseconds: latencyCount > 0 ? Int(try result.integer(3) / latencyCount) : nil)
    }

    public func removeRollups(keeping targetIDs: Set<String>) throws {
        let existing = try run("SELECT DISTINCT target_id FROM monitor_rollups")
        for row in 0..<existing.rowCount {
            let id = try existing.string(0, row: row)
            if !targetIDs.contains(id) { _ = try run("DELETE FROM monitor_rollups WHERE target_id = ?") { try $0.bind(id, at: 1) } }
        }
    }

    // MARK: Retention

    public func prune(now: Foundation.Date = Foundation.Date()) throws {
        _ = try run("DELETE FROM history WHERE id <= (SELECT COALESCE(MAX(id), 0) FROM history) - \(Self.historyKept)")
        let cutoff = now.timeIntervalSince1970 - Self.incidentRetention
        // Only finished incidents are ever removed; an open incident is never aged out.
        _ = try run("DELETE FROM incidents WHERE state = 'resolved' AND resolved_at < ?") { try $0.bind(cutoff, at: 1) }
        _ = try run("""
            DELETE FROM incidents WHERE state = 'resolved' AND id NOT IN
            (SELECT id FROM incidents WHERE state = 'resolved' ORDER BY resolved_at DESC LIMIT \(Self.incidentsKept))
            """)
        let bucket = Int64((now.timeIntervalSince1970 - Self.rollupRetention) / Self.bucketSeconds)
        _ = try run("DELETE FROM monitor_rollups WHERE bucket < ?") { try $0.bind(bucket, at: 1) }
    }
}

private extension ResultSet {
    func string(_ column: Int, row: DBInt = 0) throws -> String {
        guard let value = self[DBInt(column)].cast(to: String.self)[row] else { throw AlertStore.StoreError.invalid }
        return value
    }
    func integer(_ column: Int, row: DBInt = 0) throws -> Int64 {
        guard let value = self[DBInt(column)].cast(to: Int64.self)[row] else { throw AlertStore.StoreError.invalid }
        return value
    }
    func number(_ column: Int, row: DBInt = 0) throws -> Double {
        guard let value = self[DBInt(column)].cast(to: Double.self)[row], value.isFinite else { throw AlertStore.StoreError.invalid }
        return value
    }
}
