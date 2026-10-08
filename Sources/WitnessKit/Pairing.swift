import Foundation
import Security

/// One-time pairing codes. An operator creates a short code for a service; a
/// server exchanges it for a pending request; nothing is released until the
/// operator approves that request in Ruru. Codes are single-use and expire.
/// State is in memory only: a restart cancels every code and request.
public actor PairingDesk {
    public static let codeLifetime: Double = 600
    public static let requestLifetime: Double = 600
    static let maxCodes = 8
    static let maxRequests = 16
    static let maxFailuresPerMinute = 10
    /// No 0/1/I/L/O/U, so codes survive being read aloud or retyped.
    static let alphabet = Array("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    public struct Code: Sendable, Equatable {
        public let code: String
        public let clusterID: String
        public let expiresIn: Double
    }

    public struct Request: Sendable, Equatable, Identifiable {
        public let id: String
        public let clusterID: String
        public let nodeID: String
        public let nodeName: String?
        public let age: Double
    }

    public struct Credential: Codable, Sendable, Equatable {
        public let clusterID: String
        public let token: String
        public let leaseSeconds: Double
        public init(clusterID: String, token: String, leaseSeconds: Double) {
            self.clusterID = clusterID; self.token = token; self.leaseSeconds = leaseSeconds
        }
    }

    public enum Status: Sendable, Equatable {
        case pending, approved(Credential), rejected, expired
    }

    private struct ActiveCode { let clusterID: String; let expires: Double }
    private struct Pending {
        let clusterID: String, nodeID: String, nodeName: String?, created: Double
        var decision: Decision = .waiting
        enum Decision { case waiting, approved(Credential), rejected }
    }

    private let clock: @Sendable () -> Double
    private var codes: [String: ActiveCode] = [:]
    private var requests: [String: Pending] = [:]
    private var failures: [Double] = []

    public init(clock: (@Sendable () -> Double)? = nil) {
        let origin = ContinuousClock.now
        self.clock = clock ?? {
            let elapsed = origin.duration(to: ContinuousClock.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }

    // MARK: Operator (the app)

    /// Creates a code for `clusterID`. Throws when too many are already live.
    public func createCode(for clusterID: String) throws -> Code {
        prune()
        guard codes.count < Self.maxCodes else { throw WitnessError.invalidConfiguration }
        var code: String
        repeat { code = try Self.randomCode() } while codes[code] != nil
        codes[code] = ActiveCode(clusterID: clusterID, expires: clock() + Self.codeLifetime)
        return Code(code: Self.display(code), clusterID: clusterID, expiresIn: Self.codeLifetime)
    }

    public func activeCodes() -> [Code] {
        prune()
        let now = clock()
        return codes.map { Code(code: Self.display($0.key), clusterID: $0.value.clusterID, expiresIn: $0.value.expires - now) }
            .sorted { $0.expiresIn > $1.expiresIn }
    }

    public func cancelCode(_ display: String) {
        codes[Self.normalized(display) ?? ""] = nil
    }

    /// Requests awaiting a decision, oldest first.
    public func pendingRequests() -> [Request] {
        prune()
        let now = clock()
        return requests.compactMap { id, request in
            guard case .waiting = request.decision else { return nil }
            return Request(id: id, clusterID: request.clusterID, nodeID: request.nodeID,
                           nodeName: request.nodeName, age: now - request.created)
        }.sorted { $0.age > $1.age }
    }

    public func approve(_ id: String, with credential: Credential) throws {
        prune()
        guard let request = requests[id], case .waiting = request.decision, request.clusterID == credential.clusterID else {
            throw WitnessError.invalidConfiguration
        }
        requests[id]?.decision = .approved(credential)
    }

    public func reject(_ id: String) {
        guard let request = requests[id], case .waiting = request.decision else { return }
        requests[id]?.decision = .rejected
    }

    /// Drops every code and request for a service that was removed or reset.
    public func revoke(clusterID: String) {
        codes = codes.filter { $0.value.clusterID != clusterID }
        requests = requests.filter { $0.value.clusterID != clusterID }
    }

    // MARK: Servers (HTTP)

    enum ClaimResult: Equatable { case accepted(String), invalid, throttled, full }

    /// Exchanges a code for a pending request ID. The code is used up either way.
    func claim(code: String, nodeID: String, nodeName: String?) -> ClaimResult {
        prune()
        let now = clock()
        guard failures.count < Self.maxFailuresPerMinute else { return .throttled }
        guard let normalized = Self.normalized(code), let active = codes.removeValue(forKey: normalized) else {
            failures.append(now)
            return .invalid
        }
        guard requests.count < Self.maxRequests, let id = try? Self.randomID() else { return .full }
        requests[id] = Pending(clusterID: active.clusterID, nodeID: nodeID, nodeName: nodeName, created: now)
        return .accepted(id)
    }

    /// An approved credential is delivered once, then forgotten.
    func status(of id: String) -> Status {
        prune()
        guard let request = requests[id] else { return .expired }
        switch request.decision {
        case .waiting: return .pending
        case .rejected:
            requests[id] = nil
            return .rejected
        case .approved(let credential):
            requests[id] = nil
            return .approved(credential)
        }
    }

    // MARK: Helpers

    private func prune() {
        let now = clock()
        codes = codes.filter { $0.value.expires > now }
        requests = requests.filter { now - $0.value.created < Self.requestLifetime }
        failures = failures.filter { now - $0 < 60 }
    }

    static func randomCode() throws -> String {
        // 256 is not a multiple of 30; reject the biased tail.
        var characters: [Character] = []
        while characters.count < 8 {
            var byte: UInt8 = 0
            guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { throw WitnessError.invalidConfiguration }
            if byte < 240 { characters.append(alphabet[Int(byte) % alphabet.count]) }
        }
        return String(characters)
    }

    static func randomID() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw WitnessError.invalidConfiguration
        }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// Accepts any case, spaces and dashes: "7kq4 m2xp" → "7KQ4M2XP".
    static func normalized(_ text: String) -> String? {
        let cleaned = text.uppercased().filter { $0 != "-" && $0 != " " }
        guard cleaned.count == 8, cleaned.allSatisfy(alphabet.contains) else { return nil }
        return cleaned
    }

    static func display(_ code: String) -> String { String(code.prefix(4)) + "-" + String(code.suffix(4)) }
}
