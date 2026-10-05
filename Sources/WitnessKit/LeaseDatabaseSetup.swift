import DuckDB
import Darwin
import Foundation

/// Fresh DuckDB authority setup. Existing SQLite authorities require an explicit
/// offline replacement; never initialize empty terms beside their durable state.
enum LeaseDatabaseSetup {
    static let marker = Data("Ruru-DuckDB-authority-v1".utf8)
    static let retiredMarker = Data("SwiftMeshWitness-authority-replaced-by-duckdb-v1".utf8)

    static func prepare(url: URL, legacyURL: URL) throws -> DuckDBDatabase {
        let files = FileManager.default
        let markerURL = url.appendingPathExtension("initialized")
        let legacyMarkerURL = legacyURL.appendingPathExtension("initialized")
        if files.fileExists(atPath: markerURL.path) {
            guard try Data(contentsOf: markerURL) == marker,
                  files.fileExists(atPath: url.path) else {
                throw WitnessError.database("Previously initialized DuckDB storage is missing or damaged. It will not be reset.")
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw WitnessError.database("The database must be a regular file.")
            }
            guard try Data(contentsOf: legacyMarkerURL) == retiredMarker else {
                throw WitnessError.database("The older-app safety marker is missing or damaged.")
            }
            return try DuckDBDatabase(url: url)
        }
        guard !files.fileExists(atPath: url.path) else {
            throw WitnessError.database("An unmarked DuckDB database exists. It will not be replaced or adopted.")
        }
        guard !files.fileExists(atPath: legacyURL.path),
              !files.fileExists(atPath: legacyURL.path + "-wal"),
              !files.fileExists(atPath: legacyURL.path + "-shm"),
              !files.fileExists(atPath: legacyMarkerURL.path) else {
            throw LegacyAuthorityStorageError()
        }
        return try createFreshDatabase(url: url, legacyURL: legacyURL)
    }

    static func createFreshDatabase(url: URL, legacyURL: URL) throws -> DuckDBDatabase {
        let files = FileManager.default
        // Mark intent before database creation. An interrupted first setup fails
        // closed, rather than trying to create another authority on next launch.
        // Old app binaries reject this marker and cannot use stale SQLite terms.
        try writeMarker(retiredMarker, to: legacyURL.appendingPathExtension("initialized"))
        try writeMarker(marker, to: url.appendingPathExtension("initialized"))
        let database = try DuckDBDatabase(url: url)
        try database.open { connection in
            try database.execute(connection, "BEGIN TRANSACTION")
            do {
                try DuckDBDatabase.createSchema(connection)
                try database.execute(connection, "COMMIT")
            } catch {
                try? database.execute(connection, "ROLLBACK")
                throw error
            }
        }
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return database
    }

    static func validTerm(_ term: Int64) -> Bool { term >= 0 && term < (1 << 62) }

    static func writeMarker(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(url.deletingLastPathComponent())
    }

    static func synchronizeDirectory(_ url: URL) throws {
        let directory = Darwin.open(url.path, O_RDONLY)
        guard directory >= 0 else { throw WitnessError.database("Cannot persist the initialization directory.") }
        defer { Darwin.close(directory) }
        guard fsync(directory) == 0 else { throw WitnessError.database("Cannot persist the initialization marker.") }
    }
}
