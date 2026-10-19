import Foundation

/// A status document an app serves at `GET /.well-known/ruru` so a Ruru
/// enhanced HTTP(S) monitor can show its version, components and metrics.
///
/// This is monitoring only: serving it needs no pairing, token or lease, and
/// Ruru never treats it as identity. The route must be safe to publish: no
/// secrets, account or user names, hostnames, paths, logs or error text. Use
/// machine `reasonCode`s for detail. See Documentation/ENHANCED_MONITORING.md.
///
/// ```swift
/// let document = RuruStatusDocument(
///     app: .init(id: "app.example", name: "Example", version: "1.2.0"),
///     state: .ready,
///     components: [.init(id: "database", name: "Database", state: .ready)],
///     metrics: [.init(id: "queue", name: "Queued jobs", value: 4, unit: "count")])
/// let body = try document.encoded() // serve as application/json, HTTP 200
/// ```
public struct RuruStatusDocument: Encodable, Sendable, Equatable {
    public static let path = "/.well-known/ruru"
    public static let version = 1
    public static let maxBytes = 16 * 1024
    public static let maxComponents = 16
    public static let maxMetrics = 16
    public static let maxLinks = 4

    public struct App: Encodable, Sendable, Equatable {
        /// Reverse-DNS style machine code, ASCII `[a-z0-9._-]`, 1–48 characters.
        public var id: String
        /// Display name, 1–64 characters.
        public var name: String
        /// Display text, 1–32 characters.
        public var version: String?
        public var build: String?

        public init(id: String, name: String, version: String? = nil, build: String? = nil) {
            self.id = id; self.name = name; self.version = version; self.build = build
        }
    }

    public struct Component: Encodable, Sendable, Equatable {
        public var id: String
        public var name: String
        public var state: RuruOperationalState
        public var reasonCode: String?

        public init(id: String, name: String, state: RuruOperationalState, reasonCode: String? = nil) {
            self.id = id; self.name = name; self.state = state; self.reasonCode = reasonCode
        }
    }

    public struct Metric: Encodable, Sendable, Equatable {
        public var id: String
        public var name: String
        /// Must be finite.
        public var value: Double
        /// Display unit, 1–16 characters, such as `count`, `ms` or `%`.
        public var unit: String?

        public init(id: String, name: String, value: Double, unit: String? = nil) {
            self.id = id; self.name = name; self.value = value; self.unit = unit
        }
    }

    public struct Link: Encodable, Sendable, Equatable {
        public enum Rel: String, Encodable, Sendable { case dashboard, status, docs, support }
        public var rel: Rel
        public var title: String
        /// Ruru shows only `https` links on the monitored host.
        public var url: URL

        public init(rel: Rel, title: String, url: URL) { self.rel = rel; self.title = title; self.url = url }
    }

    public enum ValidationError: Error, Equatable, Sendable {
        case invalidCode(String)
        case invalidText(String)
        case tooMany(String)
        case duplicateID(String)
        case nonFiniteMetric(String)
        case invalidUptime
        case tooLarge(Int)
    }

    public var app: App
    public var state: RuruOperationalState
    public var reasonCode: String?
    /// The app's own process uptime. Ruru shows a decrease as a restart.
    public var uptimeSeconds: Int?
    public var components: [Component]
    public var metrics: [Metric]
    public var links: [Link]

    public init(app: App, state: RuruOperationalState, reasonCode: String? = nil, uptimeSeconds: Int? = nil,
                components: [Component] = [], metrics: [Metric] = [], links: [Link] = []) {
        self.app = app; self.state = state; self.reasonCode = reasonCode; self.uptimeSeconds = uptimeSeconds
        self.components = components; self.metrics = metrics; self.links = links
    }

    private enum CodingKeys: String, CodingKey { case ruru, app, state, reasonCode, uptimeSeconds, components, metrics, links }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .ruru)
        try container.encode(app, forKey: .app)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(reasonCode, forKey: .reasonCode)
        try container.encodeIfPresent(uptimeSeconds, forKey: .uptimeSeconds)
        if !components.isEmpty { try container.encode(components, forKey: .components) }
        if !metrics.isEmpty { try container.encode(metrics, forKey: .metrics) }
        if !links.isEmpty { try container.encode(links, forKey: .links) }
    }

    /// Checks the bounds Ruru enforces, so a mistake shows up in the app's own
    /// tests instead of as "Status document is invalid" in Ruru.
    public func validate() throws {
        try Self.code(app.id, "app.id")
        try Self.text(app.name, 64, "app.name")
        if let version = app.version { try Self.text(version, 32, "app.version") }
        if let build = app.build { try Self.text(build, 32, "app.build") }
        if let reasonCode { try Self.code(reasonCode, "reasonCode") }
        if let uptimeSeconds, !(0...(10 * 366 * 24 * 60 * 60)).contains(uptimeSeconds) { throw ValidationError.invalidUptime }
        guard components.count <= Self.maxComponents else { throw ValidationError.tooMany("components") }
        guard metrics.count <= Self.maxMetrics else { throw ValidationError.tooMany("metrics") }
        guard links.count <= Self.maxLinks else { throw ValidationError.tooMany("links") }
        for component in components {
            try Self.code(component.id, "components.id")
            try Self.text(component.name, 64, "components.name")
            if let reasonCode = component.reasonCode { try Self.code(reasonCode, "components.reasonCode") }
        }
        for metric in metrics {
            try Self.code(metric.id, "metrics.id")
            try Self.text(metric.name, 64, "metrics.name")
            if let unit = metric.unit { try Self.text(unit, 16, "metrics.unit") }
            guard metric.value.isFinite else { throw ValidationError.nonFiniteMetric(metric.id) }
        }
        for link in links { try Self.text(link.title, 64, "links.title") }
        if let duplicate = Self.firstDuplicate(components.map(\.id)) { throw ValidationError.duplicateID(duplicate) }
        if let duplicate = Self.firstDuplicate(metrics.map(\.id)) { throw ValidationError.duplicateID(duplicate) }
    }

    /// Validated JSON for the response body.
    public func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= Self.maxBytes else { throw ValidationError.tooLarge(data.count) }
        return data
    }

    private static func code(_ value: String, _ field: String) throws {
        guard (1...48).contains(value.utf8.count),
              value.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D })
        else { throw ValidationError.invalidCode(field) }
    }

    private static func text(_ value: String, _ limit: Int, _ field: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...limit).contains(trimmed.count), trimmed == value,
              !value.unicodeScalars.contains(where: { [.control, .format].contains($0.properties.generalCategory) })
        else { throw ValidationError.invalidText(field) }
    }

    private static func firstDuplicate(_ ids: [String]) -> String? {
        var seen = Set<String>()
        return ids.first { !seen.insert($0).inserted }
    }
}

/// Who may read an app's `/.well-known/ruru` document. Apps should offer this
/// as a setting, off by default: the document is unauthenticated.
public enum RuruStatusExposure: String, Codable, Sendable, CaseIterable {
    /// The route answers 404, as if it did not exist.
    case off
    /// Only direct requests from loopback or private-network addresses. Anything
    /// that arrived through a proxy or tunnel (for example Cloudflare) is refused.
    case localNetwork
    /// Anyone who can reach the server, including through a public domain.
    case everywhere

    /// Headers that proxies and tunnels add. A request carrying any of them is
    /// treated as remote, whatever address it appears to come from.
    static let forwardingHeaders: Set<String> = [
        "forwarded", "x-forwarded-for", "x-forwarded-host", "x-real-ip",
        "cf-connecting-ip", "cf-ray", "true-client-ip", "fly-client-ip"
    ]

    /// - Parameters:
    ///   - headers: the request's header fields (names in any case).
    ///   - remoteAddress: the connection's peer IP address, when the server knows
    ///     it. Without it, `.localNetwork` relies on forwarding headers alone, so a
    ///     proxy that adds none of them would be treated as local.
    public func allows(headers: [String: String], remoteAddress: String? = nil) -> Bool {
        switch self {
        case .off: return false
        case .everywhere: return true
        case .localNetwork:
            let names = Set(headers.keys.map { $0.lowercased() })
            guard names.isDisjoint(with: Self.forwardingHeaders) else { return false }
            guard let remoteAddress else { return true }
            return Self.isLocalAddress(remoteAddress)
        }
    }

    /// Loopback, RFC 1918, carrier-grade NAT (100.64/10, used by Tailscale),
    /// IPv6 unique-local and link-local addresses.
    public static func isLocalAddress(_ text: String) -> Bool {
        var address = text.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        if let zone = address.firstIndex(of: "%") { address = String(address[..<zone]) }
        if address.hasPrefix("::ffff:"), address.contains(".") { address = String(address.dropFirst(7)) }
        let octets = address.split(separator: ".", omittingEmptySubsequences: false).compactMap { UInt8($0) }
        if octets.count == 4, address.split(separator: ".", omittingEmptySubsequences: false).count == 4 {
            let a = octets[0], b = octets[1]
            return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 100 && (64...127).contains(b)) || (a == 169 && b == 254)
        }
        guard address.contains(":") else { return false }
        if address == "::1" { return true }
        let first = address.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let group = UInt16(first, radix: 16) else { return false }
        return (group & 0xFE00) == 0xFC00 || (group & 0xFFC0) == 0xFE80
    }
}

/// A ready-to-send answer for `GET /.well-known/ruru`, for any HTTP server.
public struct RuruStatusResponse: Sendable, Equatable {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
}

extension RuruStatusDocument {
    /// Builds the response for one request: 404 when `exposure` refuses it,
    /// otherwise the validated JSON with no-store caching. A document that fails
    /// validation is answered with 500 and no body, so a bug never leaks partial data.
    public func response(exposure: RuruStatusExposure, requestHeaders: [String: String],
                         remoteAddress: String? = nil) -> RuruStatusResponse {
        guard exposure.allows(headers: requestHeaders, remoteAddress: remoteAddress) else {
            return RuruStatusResponse(status: 404, headers: ["Content-Length": "0"], body: Data())
        }
        guard let body = try? encoded() else {
            return RuruStatusResponse(status: 500, headers: ["Content-Length": "0"], body: Data())
        }
        return RuruStatusResponse(status: 200, headers: [
            "Content-Type": "application/json",
            "Content-Length": "\(body.count)",
            "Cache-Control": "no-store",
            "X-Content-Type-Options": "nosniff"
        ], body: body)
    }
}
