import Foundation

/// An app's self-reported status, read by an enhanced HTTP(S) monitor from
/// `/.well-known/ruru` on the monitored origin. See
/// Documentation/ENHANCED_MONITORING.md. Display and alerting only: it is never
/// identity and never influences leases, ownership or failover.
public struct MonitorStatusDocument: Equatable, Sendable {
    public static let path = "/.well-known/ruru"
    public static let supportedVersion = 1
    public static let maxBytes = 16 * 1024
    public static let maxComponents = 16
    public static let maxMetrics = 16
    public static let maxLinks = 4
    static let maxUptimeSeconds = 10 * 366 * 24 * 60 * 60

    public enum State: String, Codable, CaseIterable, Sendable {
        case ready, synchronizing, outdated, degraded, unknown
    }

    public struct App: Equatable, Sendable {
        public let id: String
        public let name: String
        public let version: String?
        public let build: String?
    }

    public struct Component: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let state: State
        public let reasonCode: String?
    }

    public struct Metric: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let value: Double
        public let unit: String?
    }

    public struct Link: Equatable, Sendable {
        public enum Rel: String, Codable, Sendable { case dashboard, status, docs, support }
        public let rel: Rel
        public let title: String
        public let url: URL
    }

    public let app: App
    public let state: State
    public let reasonCode: String?
    public let uptimeSeconds: Int?
    public let components: [Component]
    public let metrics: [Metric]
    /// Only `https` links on the monitored host survive parsing.
    public let links: [Link]

    /// Why a response could not be used. Raw values are stable machine codes.
    public enum Issue: String, Error, Equatable, Sendable {
        case tooLarge = "too_large"
        case notJSON = "not_json"
        case unsupportedVersion = "unsupported_version"
        case invalid
        case incomplete
        case unavailable

        public var title: String {
            switch self {
            case .tooLarge: "Status document is larger than 16 KB"
            case .notJSON: "Status document is not valid JSON"
            case .unsupportedVersion: "Unsupported status document version"
            case .invalid: "Status document is invalid"
            case .incomplete: "Status document did not finish downloading"
            case .unavailable: "No status document at /.well-known/ruru"
            }
        }
    }

    /// `/.well-known/ruru` on the same scheme, host and port as `url`.
    public static func documentURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = host
        parts.port = url.port
        parts.path = path
        return parts.url
    }

    /// Strictly validates an untrusted response body. `origin` is the monitored
    /// URL; links to any other host are dropped.
    public static func parse(_ data: Data, origin: URL) -> Result<MonitorStatusDocument, Issue> {
        guard data.count <= maxBytes else { return .failure(.tooLarge) }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(VersionProbe.self, from: data) else {
            return .failure((try? JSONSerialization.jsonObject(with: data)) == nil ? .notJSON : .invalid)
        }
        guard version.ruru == supportedVersion else { return .failure(.unsupportedVersion) }
        guard let raw = try? decoder.decode(Raw.self, from: data) else { return .failure(.invalid) }
        guard let document = validate(raw, origin: origin) else { return .failure(.invalid) }
        return .success(document)
    }

    private static func validate(_ raw: Raw, origin: URL) -> MonitorStatusDocument? {
        try? validated(raw, origin: origin)
    }

    private static func validated(_ raw: Raw, origin: URL) throws -> MonitorStatusDocument {
        guard let state = State(rawValue: raw.state) else { throw FieldError() }
        let app = App(id: try required(machineCode(raw.app.id)), name: try required(text(raw.app.name, limit: 64)),
                      version: try optionalText(raw.app.version, limit: 32), build: try optionalText(raw.app.build, limit: 32))
        let reason = try optionalCode(raw.reasonCode)
        if let uptime = raw.uptimeSeconds, !(0...maxUptimeSeconds).contains(uptime) { throw FieldError() }

        let rawComponents = raw.components ?? []
        let rawMetrics = raw.metrics ?? []
        let rawLinks = raw.links ?? []
        guard rawComponents.count <= maxComponents, rawMetrics.count <= maxMetrics, rawLinks.count <= maxLinks else { throw FieldError() }

        let components = try rawComponents.map { item in
            guard let state = State(rawValue: item.state) else { throw FieldError() }
            return Component(id: try required(machineCode(item.id)), name: try required(text(item.name, limit: 64)),
                             state: state, reasonCode: try optionalCode(item.reasonCode))
        }
        let metrics = try rawMetrics.map { item in
            guard item.value.isFinite else { throw FieldError() }
            return Metric(id: try required(machineCode(item.id)), name: try required(text(item.name, limit: 64)),
                          value: item.value, unit: try optionalText(item.unit, limit: 16))
        }
        guard Set(components.map(\.id)).count == components.count, Set(metrics.map(\.id)).count == metrics.count else { throw FieldError() }

        // A link to another host or over plain HTTP is dropped, not fatal: the
        // rest of the document is still useful.
        let host = origin.host?.lowercased()
        let links: [Link] = rawLinks.compactMap { item in
            guard let rel = Link.Rel(rawValue: item.rel), let title = text(item.title, limit: 64),
                  item.url.utf8.count <= 2048, let url = URL(string: item.url), url.scheme?.lowercased() == "https",
                  url.user == nil, url.password == nil, let linkHost = url.host?.lowercased(), linkHost == host else { return nil }
            return Link(rel: rel, title: title, url: url)
        }
        return MonitorStatusDocument(app: app, state: state, reasonCode: reason, uptimeSeconds: raw.uptimeSeconds,
                                     components: components, metrics: metrics, links: links)
    }

    // MARK: Field rules

    /// ASCII `[a-z0-9._-]`, 1–48 characters.
    static func machineCode(_ value: String) -> String? {
        guard (1...48).contains(value.utf8.count),
              value.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D })
        else { return nil }
        return value
    }

    /// Display text with control and format characters (including bidirectional
    /// overrides and zero-width characters) removed, then trimmed.
    static func text(_ value: String, limit: Int) -> String? {
        guard value.utf8.count <= limit * 8 else { return nil }
        let scalars = value.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .surrogate, .unassigned: false
            default: true
            }
        }
        let cleaned = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        guard (1...limit).contains(cleaned.count) else { return nil }
        return cleaned
    }

    private struct FieldError: Error {}

    private static func required(_ value: String?) throws -> String {
        guard let value else { throw FieldError() }
        return value
    }

    private static func optionalText(_ value: String?, limit: Int) throws -> String? {
        guard let value else { return nil }
        guard let cleaned = text(value, limit: limit) else { throw FieldError() }
        return cleaned
    }

    private static func optionalCode(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let code = machineCode(value) else { throw FieldError() }
        return code
    }

    // MARK: Wire shape

    private struct VersionProbe: Decodable { let ruru: Int }

    private struct Raw: Decodable {
        struct App: Decodable { let id: String; let name: String; let version: String?; let build: String? }
        struct Component: Decodable { let id: String; let name: String; let state: String; let reasonCode: String? }
        struct Metric: Decodable { let id: String; let name: String; let value: Double; let unit: String? }
        struct Link: Decodable { let rel: String; let title: String; let url: String }
        let app: App
        let state: String
        let reasonCode: String?
        let uptimeSeconds: Int?
        let components: [Component]?
        let metrics: [Metric]?
        let links: [Link]?
    }
}

/// What an enhanced check learned about the status document, carried on the
/// check's result and folded into `MonitorState`.
public enum MonitorStatusOutcome: Equatable, Sendable {
    case document(MonitorStatusDocument)
    case issue(MonitorStatusDocument.Issue)
}

/// A notable change in an enhanced monitor's reported status, for Activity.
public struct MonitorStatusEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case stateChanged(from: MonitorStatusDocument.State, to: MonitorStatusDocument.State)
        case versionChanged(from: String, to: String)
        case restarted
    }
    public let time: Date
    public let kind: Kind
}

public struct MonitorMetricSample: Equatable, Sendable {
    public let time: Date
    public let value: Double
}
