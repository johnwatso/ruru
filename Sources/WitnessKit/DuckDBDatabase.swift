import DuckDB
import Foundation

/// Connections belong to the serialized lease authority. Keeping one connection
/// avoids rebuilding DuckDB's catalog on every five-second renewal.
struct DuckDBDatabase: Sendable {
    let url: URL
    let connection: Connection

    init(url: URL) throws {
        self.url = url
        let settings = Database.Configuration()
        try settings.setValue("2", forKey: "threads")
        try settings.setValue("128MB", forKey: "memory_limit")
        try settings.setValue("false", forKey: "enable_external_access")
        let database = try Database(store: .file(at: url), configuration: settings)
        connection = try database.connect()
    }

    func open<T>(_ operation: (Connection) throws -> T) throws -> T {
        // DuckDB keeps an open descriptor. A removed pathname must still make
        // this authority unavailable, rather than acknowledging orphaned writes.
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WitnessError.database("The durable database is missing. It will not be recreated.")
        }
        return try operation(connection)
    }

    func execute(_ connection: Connection, _ sql: String) throws {
        // query retains DuckDB's diagnostic, unlike execute in the pinned API.
        _ = try connection.query(sql)
    }

    func query(_ connection: Connection, _ sql: String,
               bind: (PreparedStatement) throws -> Void = { _ in }) throws -> ResultSet {
        let statement = try PreparedStatement(connection: connection, query: sql)
        try bind(statement)
        return try statement.execute()
    }

    static func createSchema(_ connection: Connection) throws {
        _ = try connection.query("""
            CREATE TABLE leases (cluster VARCHAR PRIMARY KEY, owner VARCHAR NOT NULL, term BIGINT NOT NULL, expires DOUBLE NOT NULL);
            CREATE TABLE events (id BIGINT PRIMARY KEY, time DOUBLE NOT NULL, action VARCHAR NOT NULL, cluster VARCHAR NOT NULL, node VARCHAR NOT NULL, term BIGINT NOT NULL);
            CREATE TABLE node_names (cluster VARCHAR NOT NULL, node VARCHAR NOT NULL, name VARCHAR NOT NULL, PRIMARY KEY (cluster, node));
            """)
    }
}

extension ResultSet {
    func string(_ column: Int, row: DBInt = 0) throws -> String {
        guard let value = self[DBInt(column)].cast(to: String.self)[row] else {
            throw WitnessError.database("Invalid text in durable ownership storage.")
        }
        return value
    }

    func integer(_ column: Int, row: DBInt = 0) throws -> Int64 {
        guard let value = self[DBInt(column)].cast(to: Int64.self)[row] else {
            throw WitnessError.database("Invalid integer in durable ownership storage.")
        }
        return value
    }

    func number(_ column: Int, row: DBInt = 0) throws -> Double {
        guard let value = self[DBInt(column)].cast(to: Double.self)[row], value.isFinite else {
            throw WitnessError.database("Invalid number in durable ownership storage.")
        }
        return value
    }
}
