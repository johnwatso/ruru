import Foundation
import WitnessKit

/// A portable backup: application settings plus lease terms and history.
/// Bearer tokens and Cloudflare credentials are never included.
struct RuruBackup: Codable {
    static let currentFormat = "dev.ruruapp.ruru.backup"
    static let currentVersion = 1

    let format: String
    let version: Int
    let createdAt: Date
    let configuration: WitnessConfiguration
    let leases: LeaseSnapshot?

    init(configuration: WitnessConfiguration, leases: LeaseSnapshot?, createdAt: Date = Date()) {
        format = Self.currentFormat
        version = Self.currentVersion
        self.createdAt = createdAt
        self.configuration = Self.portable(configuration)
        self.leases = leases
    }

    /// Strips this Mac's Cloudflare tunnel identity; a new Mac sets up its own.
    static func portable(_ configuration: WitnessConfiguration) -> WitnessConfiguration {
        var portable = configuration
        if configuration.tunnel.isConfigured || configuration.tunnel.enabled { portable.publicEndpoint = "" }
        portable.tunnel = WitnessTunnelSettings()
        return portable
    }

    /// The backup's settings, keeping this Mac's tunnel and the listener it requires.
    static func importedConfiguration(_ backup: WitnessConfiguration, current: WitnessConfiguration) throws -> WitnessConfiguration {
        var imported = backup
        imported.tunnel = current.tunnel
        if current.tunnel.isConfigured {
            imported.publicEndpoint = current.publicEndpoint
            imported.bindAddress = current.bindAddress
            imported.port = current.port
        }
        guard imported.isValid else { throw WitnessStorage.ConfigurationError.invalid }
        return imported
    }

    func encoded() throws -> Data { try LeaseSnapshot.encoder.encode(self) }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// Reads a full backup or a bare lease snapshot.
    static func read(_ data: Data) throws -> (configuration: WitnessConfiguration?, leases: LeaseSnapshot?) {
        if let backup = try? LeaseSnapshot.decoder.decode(RuruBackup.self, from: data) {
            guard backup.format == currentFormat, backup.version == currentVersion else {
                throw LeaseRestoreError.unsupportedSnapshot
            }
            guard backup.configuration.isValid else { throw WitnessStorage.ConfigurationError.invalid }
            try backup.leases?.validate()
            return (backup.configuration, backup.leases)
        }
        return (nil, try LeaseSnapshot.decode(data))
    }
}

extension WitnessStorage {
    /// The live lease database lives in its own folder, excluded from Time
    /// Machine: restoring an older copy would re-issue terms bots have seen.
    static var authorityDirectory: URL { directory.appendingPathComponent("Authority", isDirectory: true) }
    static var databaseURL: URL { authorityDirectory.appendingPathComponent("leases.duckdb") }
    /// Kept outside Authority so Time Machine and Migration Assistant carry it.
    static var snapshotsDirectory: URL { directory.appendingPathComponent("Snapshots", isDirectory: true) }
    static let snapshotsKept = 14
    static let authorityMarker = Data("Ruru authority created; leases live in Authority/.\n".utf8)

    /// Backed-up evidence that this Mac's authority exists. If the database is
    /// missing while this marker is present, startup stops instead of creating
    /// an empty authority with term zero.
    static func checkAuthorityPresent(in directory: URL = Self.directory) throws {
        let marker = directory.appendingPathComponent("authority-created")
        let database = directory.appendingPathComponent("Authority/leases.duckdb.initialized")
        if FileManager.default.fileExists(atPath: marker.path), !FileManager.default.fileExists(atPath: database.path) {
            throw AuthorityMissingError()
        }
    }

    static func recordAuthorityCreated(in directory: URL = Self.directory) throws {
        let marker = directory.appendingPathComponent("authority-created")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try authorityMarker.write(to: marker, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        var authority = directory.appendingPathComponent("Authority", isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try authority.setResourceValues(values)
    }

    static func snapshotFiles(in folder: URL = snapshotsDirectory) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { $0.hasPrefix("lease-snapshot-") && $0.hasSuffix(".json") }.sorted()
            .map { folder.appendingPathComponent($0) }
    }

    static func latestSnapshotDate(in folder: URL = snapshotsDirectory) -> Date? {
        snapshotFiles(in: folder).last.flatMap {
            try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
    }

    /// Writes a timestamped snapshot and keeps only the newest `snapshotsKept`.
    @discardableResult
    static func writeSnapshot(_ snapshot: LeaseSnapshot, in folder: URL = snapshotsDirectory) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let url = folder.appendingPathComponent("lease-snapshot-\(formatter.string(from: snapshot.createdAt))Z.json")
        try snapshot.encoded().write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        for old in snapshotFiles(in: folder).dropLast(snapshotsKept) { try? files.removeItem(at: old) }
        return url
    }

    struct AuthorityMissingError: LocalizedError {
        var errorDescription: String? {
            "Ruru's ownership database is missing. It is deliberately not part of Time Machine. Use Settings → Backup → Restore from Backup to rebuild it with raised terms; Ruru will not start an empty authority."
        }
    }
}
