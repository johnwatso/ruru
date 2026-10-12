import Darwin
import Foundation

/// A portable, secret-free copy of the authority's durable lease state. Restores
/// use only its terms and history; they never revive ownership or deadlines.
public struct LeaseSnapshot: Codable, Equatable, Sendable {
    public static let currentFormat = "dev.ruruapp.ruru.lease-snapshot"
    public static let currentVersion = 2

    public struct Lease: Codable, Equatable, Sendable {
        public let clusterID: String
        public let ownerNodeID: String
        public let term: Int64
    }

    public struct Event: Codable, Equatable, Sendable {
        public let id: Int64
        public let time: Date
        public let action: String
        public let clusterID: String
        public let nodeID: String
        public let term: Int64
    }

    public struct NodeName: Codable, Equatable, Sendable {
        public let clusterID: String
        public let nodeID: String
        public let name: String
    }

    public struct ParticipantEvent: Codable, Equatable, Sendable {
        public let id: Int64
        public let time: Date
        public let kind: String
        public let clusterID: String
        public let nodeID: String
        public let nodeName: String
        public let detail: String
    }

    public let format: String
    public let version: Int
    public let createdAt: Date
    public let leases: [Lease]
    public let events: [Event]
    public let nodeNames: [NodeName]
    public let participantEvents: [ParticipantEvent]

    init(createdAt: Date, leases: [Lease], events: [Event], nodeNames: [NodeName],
         participantEvents: [ParticipantEvent] = []) {
        format = Self.currentFormat
        version = Self.currentVersion
        self.createdAt = createdAt
        self.leases = leases
        self.events = events
        self.nodeNames = nodeNames
        self.participantEvents = participantEvents
    }

    private enum CodingKeys: String, CodingKey {
        case format, version, createdAt, leases, events, nodeNames, participantEvents
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        version = try values.decode(Int.self, forKey: .version)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        leases = try values.decode([Lease].self, forKey: .leases)
        events = try values.decode([Event].self, forKey: .events)
        nodeNames = try values.decode([NodeName].self, forKey: .nodeNames)
        participantEvents = try values.decodeIfPresent([ParticipantEvent].self, forKey: .participantEvents) ?? []
    }

    public var highestTerm: Int64 { leases.map(\.term).max() ?? 0 }

    public func validate() throws {
        func identifier(_ value: String, allowEmpty: Bool = false) -> Bool {
            (allowEmpty || !value.isEmpty) && value.utf8.count <= 128
        }
        guard format == Self.currentFormat, (1...Self.currentVersion).contains(version) else { throw LeaseRestoreError.unsupportedSnapshot }
        guard leases.count <= 1024, events.count <= 32 * LeaseStore.eventsKeptPerService, nodeNames.count <= 4096,
              Set(leases.map(\.clusterID)).count == leases.count,
              Set(events.map(\.id)).count == events.count,
              Set(nodeNames.map { [$0.clusterID, $0.nodeID] }).count == nodeNames.count,
              participantEvents.count <= 32 * LeaseStore.participantEventsKeptPerService,
              Set(participantEvents.map(\.id)).count == participantEvents.count,
              leases.allSatisfy({ identifier($0.clusterID) && identifier($0.ownerNodeID, allowEmpty: true)
                  && LeaseDatabaseSetup.validTerm($0.term) }),
              events.allSatisfy({ $0.id > 0 && identifier($0.clusterID) && identifier($0.nodeID)
                  && $0.action.utf8.count <= 32 && $0.time.timeIntervalSince1970.isFinite
                  && LeaseDatabaseSetup.validTerm($0.term) }),
              nodeNames.allSatisfy({ identifier($0.clusterID) && identifier($0.nodeID)
                  && WitnessNodeName.normalized($0.name) == $0.name }),
              participantEvents.allSatisfy({ $0.id > 0 && identifier($0.clusterID) && identifier($0.nodeID)
                  && WitnessNodeName.normalized($0.nodeName) == $0.nodeName
                  && ["onBattery", "lowBattery", "powerRestored", "sessionEnding"].contains($0.kind)
                  && $0.time.timeIntervalSince1970.isFinite && !$0.detail.isEmpty
                  && $0.detail.utf8.count <= 1024 && $0.detail.rangeOfCharacter(from: .controlCharacters) == nil }) else {
            throw LeaseRestoreError.invalidSnapshot
        }
    }

    public static func decode(_ data: Data) throws -> LeaseSnapshot {
        let snapshot = try decoder.decode(LeaseSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }

    public func encoded() throws -> Data { try Self.encoder.encode(self) }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum LeaseRestoreError: LocalizedError, Equatable {
    case unsupportedSnapshot, invalidSnapshot, termExhausted, authorityInUse
    public var errorDescription: String? {
        switch self {
        case .unsupportedSnapshot: "This file is not a Ruru backup or lease snapshot this version can read."
        case .invalidSnapshot: "The backup's ownership data is damaged or out of range. Nothing was changed."
        case .termExhausted: "The backup's ownership terms are too large to raise safely. Nothing was changed."
        case .authorityInUse: "The ownership database is still in use. Quit Ruru, reopen it, and restore before starting the service."
        }
    }
}

/// Explicit, offline disaster restore. Ordinary startup never invokes this path.
public enum LeaseRestore {
    /// Added to the highest term known from the backup or the replaced database,
    /// so no participant can be granted a term it has already been issued.
    public static let termMargin: Int64 = 1_000_000

    public struct Result: Sendable {
        public let archive: URL?
        public let terms: [String: Int64]
    }

    /// Replaces the authority database with one rebuilt from `snapshot`.
    /// `knownTerms` should come from the live store just before it was closed;
    /// without it, an existing database is read on a best-effort basis.
    /// The previous database is archived, never deleted. Every rebuilt lease is
    /// ownerless and quarantines the authority for a full lease after opening.
    @discardableResult
    public static func restore(databaseURL: URL, snapshot: LeaseSnapshot,
                               knownTerms: [String: Int64]? = nil) throws -> Result {
        guard databaseURL.pathExtension == "duckdb" else { throw WitnessError.invalidConfiguration }
        try snapshot.validate()
        let files = FileManager.default
        let directory = databaseURL.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let legacyURL = databaseURL.deletingPathExtension().appendingPathExtension("sqlite")
        // Fails with alreadyRunning while any LeaseStore still owns this database.
        let legacyLock: DatabaseInstanceLock, nativeLock: DatabaseInstanceLock
        do {
            legacyLock = try DatabaseInstanceLock(url: legacyURL.appendingPathExtension("lock"))
            nativeLock = try DatabaseInstanceLock(url: databaseURL.appendingPathExtension("lock"))
        } catch WitnessError.alreadyRunning { throw LeaseRestoreError.authorityInUse }
        return try withExtendedLifetime((legacyLock, nativeLock)) {
            var terms: [String: Int64] = [:]
            for lease in snapshot.leases { terms[lease.clusterID] = lease.term }
            let existing = knownTerms ?? (files.fileExists(atPath: databaseURL.path) ? (try? readTerms(databaseURL)) : nil) ?? [:]
            for (cluster, term) in existing where LeaseDatabaseSetup.validTerm(term) {
                terms[cluster] = max(terms[cluster] ?? 0, term)
            }
            guard terms.count <= 1024, terms.keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
                throw LeaseRestoreError.invalidSnapshot
            }
            for (cluster, term) in terms {
                // Requests add one more, so leave room below the valid-term limit.
                guard term < (1 << 62) - termMargin - 2 else { throw LeaseRestoreError.termExhausted }
                terms[cluster] = term + termMargin
            }

            // Build the replacement beside the live path, so a failure here
            // leaves the current database untouched.
            let staged = directory.appendingPathComponent("leases.restoring.duckdb")
            for path in [staged, staged.appendingPathExtension("wal")] where files.fileExists(atPath: path.path) {
                try files.removeItem(at: path)
            }
            try build(staged, snapshot: snapshot, terms: terms)
            guard !files.fileExists(atPath: staged.appendingPathExtension("wal").path) else {
                throw WitnessError.database("The restored database could not be checkpointed.")
            }

            var archive: URL?
            let current = [databaseURL, databaseURL.appendingPathExtension("wal")].filter { files.fileExists(atPath: $0.path) }
            let marker = databaseURL.appendingPathExtension("initialized")
            if !current.isEmpty || files.fileExists(atPath: marker.path) {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let folder = directory.appendingPathComponent("Restore Archives", isDirectory: true)
                    .appendingPathComponent(stamp + "-" + UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
                try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                if files.fileExists(atPath: marker.path) {
                    try files.copyItem(at: marker, to: folder.appendingPathComponent(marker.lastPathComponent))
                }
                // While the marker remains and the database is absent, startup
                // fails closed; it never creates an empty authority here.
                for path in current {
                    try files.moveItem(at: path, to: folder.appendingPathComponent(path.lastPathComponent))
                }
                try LeaseDatabaseSetup.synchronizeDirectory(folder)
                try LeaseDatabaseSetup.synchronizeDirectory(folder.deletingLastPathComponent())
                archive = folder
            }
            try LeaseDatabaseSetup.writeMarker(LeaseDatabaseSetup.retiredMarker, to: legacyURL.appendingPathExtension("initialized"))
            try LeaseDatabaseSetup.writeMarker(LeaseDatabaseSetup.marker, to: marker)
            guard renamex_np(staged.path, databaseURL.path, UInt32(RENAME_EXCL)) == 0 else {
                throw WitnessError.database("The restored database could not be moved into place.")
            }
            try LeaseDatabaseSetup.synchronizeDirectory(directory)
            return Result(archive: archive, terms: terms)
        }
    }

    private static func build(_ url: URL, snapshot: LeaseSnapshot, terms: [String: Int64]) throws {
        let database = try DuckDBDatabase(url: url)
        try database.open { connection in
            try database.execute(connection, "BEGIN TRANSACTION")
            do {
                try DuckDBDatabase.createSchema(connection)
                for (cluster, term) in terms.sorted(by: { $0.key < $1.key }) {
                    // Ownerless with a non-zero expiry and the longest permitted
                    // length: the previous authority's lengths are unknown, so the
                    // next LeaseStore waits out any lease it could have granted.
                    _ = try database.query(connection, "INSERT INTO leases (cluster, owner, term, expires, duration) VALUES (?, '', ?, 1, ?)") {
                        try $0.bind(cluster, at: 1); try $0.bind(term, at: 2)
                        try $0.bind(LeaseStore.leaseDurationRange.upperBound, at: 3)
                    }
                }
                for event in snapshot.events {
                    _ = try database.query(connection, "INSERT INTO events VALUES (?, ?, ?, ?, ?, ?)") {
                        try $0.bind(event.id, at: 1); try $0.bind(event.time.timeIntervalSince1970, at: 2)
                        try $0.bind(event.action, at: 3); try $0.bind(event.clusterID, at: 4)
                        try $0.bind(event.nodeID, at: 5); try $0.bind(event.term, at: 6)
                    }
                }
                for event in snapshot.participantEvents {
                    _ = try database.query(connection, "INSERT INTO participant_events VALUES (?, ?, ?, ?, ?, ?, ?)") {
                        try $0.bind(event.id, at: 1); try $0.bind(event.time.timeIntervalSince1970, at: 2)
                        try $0.bind(event.kind, at: 3); try $0.bind(event.clusterID, at: 4)
                        try $0.bind(event.nodeID, at: 5); try $0.bind(event.nodeName, at: 6)
                        try $0.bind(event.detail, at: 7)
                    }
                }
                for name in snapshot.nodeNames {
                    _ = try database.query(connection, "INSERT INTO node_names VALUES (?, ?, ?)") {
                        try $0.bind(name.clusterID, at: 1); try $0.bind(name.nodeID, at: 2); try $0.bind(name.name, at: 3)
                    }
                }
                try database.execute(connection, "COMMIT")
            } catch {
                try? database.execute(connection, "ROLLBACK")
                throw error
            }
            try database.execute(connection, "CHECKPOINT")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func readTerms(_ url: URL) throws -> [String: Int64] {
        let database = try DuckDBDatabase(url: url)
        return try database.open { connection in
            let result = try connection.query("SELECT cluster, term FROM leases")
            var terms: [String: Int64] = [:]
            for row in 0..<result.rowCount {
                terms[try result.string(0, row: row)] = try result.integer(1, row: row)
            }
            return terms
        }
    }
}
