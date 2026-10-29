import Foundation

/// Pairs this server with a Ruru service using a one-time code shown in Ruru's
/// Connection Details. The operator must approve the request in Ruru before
/// any credentials are returned. Store the returned token in Keychain.
public enum RuruPairing {
    public enum Failure: Error, Equatable, Sendable {
        /// The code is wrong, already used, or expired.
        case invalidCode
        /// The operator rejected the request in Ruru.
        case rejected
        /// Nobody approved the request before it expired.
        case expired
        /// Too many wrong codes recently; wait a minute.
        case throttled
        case server(status: Int, code: String)
        case transport(String)
    }

    /// Exchanges `code` for connection details, waiting up to `timeout` for the
    /// operator to approve. Returns a configuration ready for `RuruLeaseClient`.
    public static func pair(endpoint: URL, code: String, nodeID: String, nodeName: String? = nil,
                            timeout: Duration = .seconds(600), session: URLSession = .shared) async throws -> RuruConfiguration {
        var body = ["code": code, "nodeID": nodeID]
        if let nodeName { body["nodeName"] = nodeName }
        let claim = try await post(endpoint, "v1/pair", body, session)
        guard let pairingID = claim["pairingID"] as? String else { throw Failure.server(status: 202, code: "invalid_response") }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let reply = try await post(endpoint, "v1/pair/status", ["pairingID": pairingID], session)
            if reply["status"] as? String == "approved",
               let clusterID = reply["clusterID"] as? String, let token = reply["token"] as? String {
                return RuruConfiguration(endpoint: endpoint, clusterID: clusterID, nodeID: nodeID, nodeName: nodeName, token: token)
            }
            let wait = (reply["retryAfter"] as? Double) ?? 2
            try await Task.sleep(for: .seconds(min(10, max(1, wait))))
        }
        throw Failure.expired
    }

    /// Ruru's code alphabet has no 0/1/I/L/O/U. "7kq4 m2xp" → "7KQ4-M2XP";
    /// nil if the text isn't a short code.
    public static func normalizedCode(_ text: String) -> String? {
        let cleaned = text.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        guard cleaned.count == 8, cleaned.allSatisfy(codeAlphabet.contains) else { return nil }
        return String(cleaned.prefix(4)) + "-" + String(cleaned.suffix(4))
    }

    private static let codeAlphabet = Set("23456789ABCDEFGHJKMNPQRSTVWXYZ")

    private static func post(_ endpoint: URL, _ path: String, _ body: [String: String],
                             _ session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.transport(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200, 202: return object
        case 404: throw Failure.invalidCode
        case 403: throw Failure.rejected
        case 410: throw Failure.expired
        case 429: throw Failure.throttled
        default: throw Failure.server(status: status, code: object["error"] as? String ?? "")
        }
    }
}

/// Ruru's address and a pairing code in one line, such as
/// `ruru.example.com 7KQ4-M2XP`, so an operator copies a single thing. The
/// code carries no credential, so neither does the invite.
public struct RuruPairingInvite: Equatable, Sendable {
    public let endpoint: URL
    public let code: String

    public init?(endpoint: URL, code: String) {
        guard Self.isAcceptable(endpoint), let code = RuruPairing.normalizedCode(code) else { return nil }
        self.endpoint = endpoint
        self.code = code
    }

    /// Parses `host code`, `https://host code` or `https://host/ code`. The
    /// code may contain a space or dash. A bare host means HTTPS.
    public init?(_ text: String) {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first, words.count > 1 else { return nil }
        var address = first.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address) else { return nil }
        self.init(endpoint: url, code: words.dropFirst().joined())
    }

    /// The single line Ruru shows. HTTPS drops its scheme; anything else keeps it.
    public var text: String {
        let address = endpoint.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let shown = endpoint.scheme == "https" ? String(address.dropFirst("https://".count)) : address
        return shown + " " + code
    }

    private static func isAcceptable(_ url: URL) -> Bool {
        guard let host = url.host, !host.isEmpty, url.user == nil, url.query == nil, url.fragment == nil else { return false }
        return url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "::1"].contains(host))
    }
}
