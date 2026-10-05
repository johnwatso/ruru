import Foundation

public struct LegacyAuthorityStorageError: LocalizedError {
    public init() { }
    public var errorDescription: String? {
        "Ownership database: Existing SQLite authority storage was found. This version does not migrate it. Stop and unpair every participating client, then use Set Up DuckDB to archive the old authority and create new pairing details."
    }
}

/// Explicit offline replacement only. Ordinary startup never invokes this path.
public enum LegacyAuthorityReplacement {
    @discardableResult
    public static func archiveAndReplace(databaseURL: URL, checkpoint: () throws -> Void) throws -> URL {
        guard databaseURL.pathExtension == "duckdb" else { throw WitnessError.invalidConfiguration }
        let files = FileManager.default
        let legacyURL = databaseURL.deletingPathExtension().appendingPathExtension("sqlite")
        let legacyLock = try DatabaseInstanceLock(url: legacyURL.appendingPathExtension("lock"))
        let nativeLock = try DatabaseInstanceLock(url: databaseURL.appendingPathExtension("lock"))
        // Never move lock files: another process must contend on the same inode.
        return try withExtendedLifetime((legacyLock, nativeLock)) {
            for path in [databaseURL, databaseURL.appendingPathExtension("initialized"), databaseURL.appendingPathExtension("wal")] {
                guard !files.fileExists(atPath: path.path) else {
                    throw WitnessError.database("DuckDB storage already exists. Legacy setup cannot replace or repair it.")
                }
            }
            let markerURL = legacyURL.appendingPathExtension("initialized")
            let candidates = [legacyURL, URL(fileURLWithPath: legacyURL.path + "-wal"),
                              URL(fileURLWithPath: legacyURL.path + "-shm"), markerURL]
            let existing = candidates.filter { files.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { throw WitnessError.database("There is no legacy authority to replace.") }
            for path in existing {
                let values = try path.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else {
                    throw WitnessError.database("Legacy storage must consist of regular files.")
                }
            }
            let archive = databaseURL.deletingLastPathComponent()
                .appendingPathComponent("Legacy Archives", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            try files.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if existing.contains(markerURL) {
                let archivedMarker = archive.appendingPathComponent(markerURL.lastPathComponent)
                try files.copyItem(at: markerURL, to: archivedMarker)
                let handle = try FileHandle(forWritingTo: archivedMarker)
                defer { try? handle.close() }
                try handle.synchronize()
                try LeaseDatabaseSetup.synchronizeDirectory(archive)
            }
            // Persist fresh pairing metadata and secrets before changing storage.
            // A failed checkpoint leaves the old database and marker untouched.
            try checkpoint()
            // Retire old binaries BEFORE moving data. Even an interrupted archive
            // cannot leave them free to create another SQLite authority.
            try LeaseDatabaseSetup.writeMarker(LeaseDatabaseSetup.retiredMarker, to: markerURL)
            for path in existing where path != markerURL {
                try files.moveItem(at: path, to: archive.appendingPathComponent(path.lastPathComponent))
            }
            for path in existing where path != markerURL {
                let handle = try FileHandle(forWritingTo: archive.appendingPathComponent(path.lastPathComponent))
                defer { try? handle.close() }
                try handle.synchronize()
            }
            try LeaseDatabaseSetup.synchronizeDirectory(archive)
            try LeaseDatabaseSetup.synchronizeDirectory(archive.deletingLastPathComponent())
            try LeaseDatabaseSetup.synchronizeDirectory(databaseURL.deletingLastPathComponent())
            // The marker and schema creation remain crash-safe and fail closed.
            _ = try LeaseDatabaseSetup.createFreshDatabase(url: databaseURL, legacyURL: legacyURL)
            return archive
        }
    }
}
