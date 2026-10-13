import Darwin
import Foundation

/// The saved rules and the record of which default templates were already offered.
/// A template Ruru provisioned once is never provisioned again, so a rule the user
/// deleted or disabled is not brought back, and a customised rule is never overwritten.
public struct AlertRulesFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version = AlertRulesFile.currentVersion
    public var rules: [AlertRule] = []
    public var provisioned: [String] = []

    public init() {}
}

public enum AlertRuleStorage {
    public enum LoadResult: Sendable {
        case missing
        case loaded(AlertRulesFile)
        /// The file could not be read; it has been left untouched.
        case damaged(String)
    }

    public static func load(from url: URL) -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let file = try JSONDecoder().decode(AlertRulesFile.self, from: Data(contentsOf: url))
            guard file.version <= AlertRulesFile.currentVersion else {
                return .damaged("These rules were saved by a newer version of Ruru.")
            }
            return .loaded(file)
        } catch { return .damaged("The rules file could not be read.") }
    }

    /// Writes atomically and flushes to disk, like Ruru's other settings.
    public static func save(_ file: AlertRulesFile, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    /// Moves an unreadable file aside, never deleting it. Returns the new file name.
    public static func setAside(_ url: URL, now: Date = Date()) -> String? {
        let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "")
        let target = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-damaged-\(stamp).json")
        do { try FileManager.default.moveItem(at: url, to: target); return target.lastPathComponent }
        catch { return nil }
    }
}
