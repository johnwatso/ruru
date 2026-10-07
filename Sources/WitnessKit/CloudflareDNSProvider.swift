// Adapted from SwiftBot’s Cloudflare DNS setup.
import Foundation

struct CloudflareDNSProvider: Sendable {
    private struct APIError: Decodable {
        let code: Int?
        let message: String
    }

    struct DNSRecordSummary: Sendable, Equatable {
        let zoneID: String
        let recordID: String
        let type: String
        let name: String
        let content: String
    }

    struct ZoneSummary: Sendable, Equatable {
        let id: String
        let name: String
        let accountID: String?

        init(id: String, name: String, accountID: String? = nil) {
            self.id = id
            self.name = name
            self.accountID = accountID
        }
    }

    enum Error: LocalizedError {
        case invalidDomain(String)
        case zoneNotFound(String)
        case identicalRecordAlreadyExists
        case apiFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidDomain:
                return "Enter a valid hostname."
            case .zoneNotFound(let domain):
                return "The domain \(domain) was not detected in Cloudflare."
            case .identicalRecordAlreadyExists:
                return "The required DNS record already exists and will be reused for certificate provisioning."
            case .apiFailed(let message):
                return message
            }
        }
    }

    private struct APIEnvelope<ResultType: Decodable>: Decodable {
        let success: Bool
        let result: ResultType?
        let errors: [APIError]

        private enum CodingKeys: String, CodingKey {
            case success
            case result
            case errors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            result = try container.decodeIfPresent(ResultType.self, forKey: .result)
            errors = try container.decodeIfPresent([APIError].self, forKey: .errors) ?? []
        }
    }

    private struct TokenVerificationResult: Decodable {
        let status: String?
    }

    private struct CloudflareZoneResponse: Decodable {
        let success: Bool
        let result: [Zone]
        let errors: [APIError]

        private enum CodingKeys: String, CodingKey {
            case success
            case result
            case errors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            result = try container.decodeIfPresent([Zone].self, forKey: .result) ?? []
            errors = try container.decodeIfPresent([APIError].self, forKey: .errors) ?? []
        }
    }

    private struct CloudflareDNSResponse: Decodable {
        let success: Bool
        let result: [CloudflareDNSRecord]
        let errors: [APIError]

        private enum CodingKeys: String, CodingKey {
            case success
            case result
            case errors
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            success = try container.decode(Bool.self, forKey: .success)
            result = try container.decodeIfPresent([CloudflareDNSRecord].self, forKey: .result) ?? []
            errors = try container.decodeIfPresent([APIError].self, forKey: .errors) ?? []
        }
    }

    private struct Zone: Decodable {
        let id: String
        let name: String
        let account: AccountReference?
    }

    private struct AccountReference: Decodable {
        let id: String
    }

    private struct CloudflareDNSRecord: Decodable {
        let id: String
        let type: String
        let name: String
        let content: String
    }

    private struct DNSRecord: Decodable {
        let id: String
        let type: String
        let name: String
        let content: String

        private enum CodingKeys: String, CodingKey {
            case id
            case type
            case name
            case content
        }
    }

    private struct CreateDNSRecordRequest: Encodable {
        let type: String
        let name: String
        let content: String
        let ttl: Int
        let proxied: Bool?
    }

    private let apiToken: String
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let baseURL = URL(string: "https://api.cloudflare.com/client/v4")!

    init(apiToken: String, session: URLSession = .shared) {
        self.apiToken = Self.normalizedAPIToken(from: apiToken)
        self.session = session
    }

    static func normalizedAPIToken(from rawToken: String) -> String {
        var token = rawToken
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))

        if let bearerToken = firstRegexCapture(
            in: token,
            pattern: #"(?i)\bbearer\s+([^\s"'`<>\\]+)"#
        ) {
            token = bearerToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))
        } else if let assignedToken = firstRegexCapture(
            in: token,
            pattern: #"(?i)\b(?:cloudflare[_-]?api[_-]?token|cf[_-]?api[_-]?token|api[_-]?token)\s*[:=]\s*([^\s"'`<>\\]+)"#
        ) {
            token = assignedToken
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))
        }

        if token.localizedCaseInsensitiveCompare("Bearer") == .orderedSame {
            return ""
        }

        if token.lowercased().hasPrefix("authorization:") {
            token = String(token.dropFirst("authorization:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if token.lowercased().hasPrefix("bearer ") {
            token = String(token.dropFirst("bearer ".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`<>"))
    }

    private static func firstRegexCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }

        return String(text[captureRange])
    }

    private static func hasInvalidAuthorizationHeaderCharacters(_ token: String) -> Bool {
        token.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
            || token.rangeOfCharacter(from: CharacterSet(charactersIn: "\":;'`<>\\{}[]")) != nil
            || token.localizedCaseInsensitiveContains("authorization:")
            || token.localizedCaseInsensitiveContains("curl ")
    }

    func createDNSRecord(
        zoneID: String,
        type: String,
        name: String,
        content: String,
        ttl: Int = 120,
        proxied: Bool? = nil
    ) async throws -> DNSRecordSummary {
        let requestBody = CreateDNSRecordRequest(
            type: type,
            name: name,
            content: content,
            ttl: ttl,
            proxied: proxied
        )
        let requestURL = baseURL
            .appendingPathComponent("zones")
            .appendingPathComponent(zoneID)
            .appendingPathComponent("dns_records")

        var request = makeRequest(url: requestURL, method: "POST")
        request.httpBody = try encoder.encode(requestBody)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let envelope: APIEnvelope<DNSRecord> = try await send(request)
        guard envelope.success, let record = envelope.result else {
            if Self.hasIdenticalRecordError(envelope.errors) {
                throw Error.identicalRecordAlreadyExists
            }
            throw Error.apiFailed(envelope.errors.map(\.message).joined(separator: ", "))
        }

        return DNSRecordSummary(
            zoneID: zoneID,
            recordID: record.id,
            type: record.type,
            name: record.name,
            content: record.content
        )
    }

    func verifyAPITokenDetailed() async throws {
        guard !apiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.apiFailed("Cloudflare API token is missing.")
        }
        guard !Self.hasInvalidAuthorizationHeaderCharacters(apiToken) else {
            throw Error.apiFailed(Self.invalidRequestHeadersMessage)
        }

        let requestURL = baseURL
            .appendingPathComponent("user")
            .appendingPathComponent("tokens")
            .appendingPathComponent("verify")

        let request = makeRequest(url: requestURL, method: "GET", timeoutInterval: 5)
        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Error.apiFailed("Could not reach Cloudflare to verify the API token. Check your internet connection and try again.")
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.apiFailed("Cloudflare returned an invalid response.")
        }

        let envelope: APIEnvelope<TokenVerificationResult>
        do {
            envelope = try decoder.decode(APIEnvelope<TokenVerificationResult>.self, from: data)
        } catch {
            throw Error.apiFailed("Cloudflare token verification failed.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = envelope.errors.isEmpty
                ? "Cloudflare token verification failed with HTTP \(http.statusCode)."
                : envelope.errors.map(\.message).joined(separator: ", ")
            if Self.isInvalidRequestHeadersMessage(message) {
                throw Error.apiFailed(Self.invalidRequestHeadersMessage)
            }
            throw Error.apiFailed(message)
        }

        guard envelope.success else {
            let message = envelope.errors.isEmpty
                ? "Cloudflare token verification failed."
                : envelope.errors.map(\.message).joined(separator: ", ")
            if Self.isInvalidRequestHeadersMessage(message) {
                throw Error.apiFailed(Self.invalidRequestHeadersMessage)
            }
            throw Error.apiFailed(message)
        }

        let status = envelope.result?.status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard status.localizedCaseInsensitiveCompare("active") == .orderedSame else {
            if status.isEmpty {
                throw Error.apiFailed("Cloudflare token verification did not return an active token status.")
            }

            throw Error.apiFailed("Cloudflare API token is \(status). Create or choose an active API token and try again.")
        }
    }

    private static let invalidRequestHeadersMessage = """
    Cloudflare rejected the authorization header. Paste only a Cloudflare API Token value, \
    not a Global API Key, tunnel token, curl command, or full Authorization header.
    """

    private static func isInvalidRequestHeadersMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("invalid request headers")
    }

    func listZones() async throws -> [ZoneSummary] {
        var components = URLComponents(url: baseURL.appendingPathComponent("zones"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "per_page", value: "50")]
        guard let url = components?.url else { return [] }

        let request = makeRequest(url: url, method: "GET")
        let (data, http) = try await sendData(request)

        let response: CloudflareZoneResponse
        do {
            response = try decoder.decode(CloudflareZoneResponse.self, from: data)
        } catch {
            throw Error.apiFailed("Cloudflare zone list failed.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = response.errors.isEmpty
                ? "Cloudflare request failed with HTTP \(http.statusCode)."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        guard response.success else {
            let message = response.errors.isEmpty
                ? "Cloudflare zone list failed."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        var zones = response.result.map { ZoneSummary(id: $0.id, name: $0.name, accountID: $0.account?.id) }
        var page = 2
        var count = response.result.count
        while count == 50 {
            guard page <= 100 else { throw Error.apiFailed("Cloudflare returned too many zones. Scope this token to the witness domain.") }
            components?.queryItems = [URLQueryItem(name: "per_page", value: "50"), URLQueryItem(name: "page", value: String(page))]
            guard let nextURL = components?.url else { throw Error.apiFailed("Invalid zone request.") }
            let envelope: APIEnvelope<[Zone]> = try await send(makeRequest(url: nextURL, method: "GET"))
            guard let entries = envelope.result else { throw Error.apiFailed("Cloudflare zone list failed.") }
            zones += entries.map { ZoneSummary(id: $0.id, name: $0.name, accountID: $0.account?.id) }
            count = entries.count
            page += 1
        }
        return zones
    }

    func findDNSRecord(
        zoneID: String,
        hostname: String,
        allowedTypes: Set<String>? = nil,
        expectedContent: String? = nil
    ) async throws -> DNSRecordSummary? {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("zones")
                .appendingPathComponent(zoneID)
                .appendingPathComponent("dns_records"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "name", value: hostname),
            URLQueryItem(name: "per_page", value: "100")
        ]

        guard let url = components?.url else {
            throw Error.invalidDomain(hostname)
        }

        let request = makeRequest(url: url, method: "GET")
        let (data, http) = try await sendData(request)

        let response: CloudflareDNSResponse
        do {
            response = try decoder.decode(CloudflareDNSResponse.self, from: data)
        } catch {
            throw Error.apiFailed("Cloudflare DNS lookup failed.")
        }

        guard (200..<300).contains(http.statusCode) else {
            let message = response.errors.isEmpty
                ? "Cloudflare request failed with HTTP \(http.statusCode)."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        guard response.success else {
            let message = response.errors.isEmpty
                ? "Cloudflare DNS lookup failed."
                : response.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }

        let record = response.result.first { record in
            guard record.name.caseInsensitiveCompare(hostname) == .orderedSame else {
                return false
            }

            if let allowedTypes {
                guard allowedTypes.contains(record.type.uppercased()) else {
                    return false
                }
            }

            if let expectedContent {
                return record.content == expectedContent
            }

            return true
        }

        guard let record else {
            return nil
        }

        return DNSRecordSummary(
            zoneID: zoneID,
            recordID: record.id,
            type: record.type,
            name: record.name,
            content: record.content
        )
    }

    enum TunnelDNSRouteResult: Sendable {
        case created
        case alreadyConfigured
    }

    enum TunnelDNSConflict: LocalizedError, Sendable {
        case existingCNAMEToOtherTarget(current: String)
        case existingRecordOfOtherType(type: String, current: String)

        var errorDescription: String? {
            switch self {
            case .existingCNAMEToOtherTarget(let current):
                return "This hostname already points to \(current) (CNAME). Choose an unused hostname."
            case .existingRecordOfOtherType(let type, let current):
                return "This hostname already has an existing \(type) record pointing to \(current). Choose an unused hostname."
            }
        }
    }

    /// Never replaces an existing record belonging to a different service.
    func configureTunnelDNSRoute(hostname: String, tunnelTarget: String, zoneID: String) async throws -> TunnelDNSRouteResult {
        if let existing = try await findDNSRecord(zoneID: zoneID, hostname: hostname) {
            guard existing.type.uppercased() == "CNAME" else {
                throw TunnelDNSConflict.existingRecordOfOtherType(type: existing.type, current: existing.content)
            }
            guard existing.content.caseInsensitiveCompare(tunnelTarget) == .orderedSame else {
                throw TunnelDNSConflict.existingCNAMEToOtherTarget(current: existing.content)
            }
            return .alreadyConfigured
        }
        _ = try await createDNSRecord(zoneID: zoneID, type: "CNAME", name: hostname,
                                     content: tunnelTarget, ttl: 1, proxied: true)
        return .created
    }

    private func makeRequest(url: URL, method: String, timeoutInterval: TimeInterval = 30) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.httpMethod = method
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Ruru/0.2", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func send<ResultType: Decodable>(_ request: URLRequest) async throws -> APIEnvelope<ResultType> {
        let (data, http) = try await sendData(request)

        let envelope = try decoder.decode(APIEnvelope<ResultType>.self, from: data)
        guard (200..<300).contains(http.statusCode), envelope.success else {
            if Self.hasIdenticalRecordError(envelope.errors) {
                throw Error.identicalRecordAlreadyExists
            }
            let message = envelope.errors.isEmpty
                ? "Cloudflare request failed with HTTP \(http.statusCode)."
                : envelope.errors.map(\.message).joined(separator: ", ")
            throw Error.apiFailed(message)
        }
        return envelope
    }

    private func sendData(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.apiFailed("Cloudflare returned an invalid response.")
        }

        return (data, http)
    }

    private static func hasIdenticalRecordError(_ errors: [APIError]) -> Bool {
        errors.contains { error in
            if error.code == 81057 {
                return true
            }

            return error.message.localizedCaseInsensitiveContains("identical record already exists")
        }
    }

}
