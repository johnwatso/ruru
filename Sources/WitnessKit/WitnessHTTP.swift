import CryptoKit
import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum HTTPParseResult {
    case incomplete
    case request(HTTPRequest)
    case reject(Int)
}

enum HTTPParser {
    static let maxHeaderBytes = 8_192
    static let maxBodyBytes = 4_096

    static func parse(_ data: Data) -> HTTPParseResult {
        guard let divider = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .reject(431) : .incomplete
        }
        guard divider.lowerBound <= maxHeaderBytes,
              let header = String(data: data[..<divider.lowerBound], encoding: .utf8),
              !header.contains("\0") else { return .reject(400) }
        let lines = header.components(separatedBy: "\r\n")
        guard let first = lines.first else { return .reject(400) }
        let pieces = first.split(separator: " ", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[2] == "HTTP/1.1" || pieces[2] == "HTTP/1.0",
              pieces[1].hasPrefix("/"), lines.count <= 65 else { return .reject(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                  !line.hasPrefix(" "), !line.hasPrefix("\t") else { return .reject(400) }
            let name = line[..<colon].lowercased()
            guard name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[name] == nil else { return .reject(400) }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.unicodeScalars.contains(where: { $0.value < 32 && $0.value != 9 }) else { return .reject(400) }
            headers[name] = value
        }
        guard headers["transfer-encoding"] == nil else { return .reject(400) }
        let method = String(pieces[0])
        var length = 0
        if let supplied = headers["content-length"] {
            guard !supplied.isEmpty, supplied.utf8.allSatisfy({ (48...57).contains($0) }),
                  let parsed = Int(supplied) else { return .reject(400) }
            length = parsed
        } else if method == "POST" { return .reject(411) }
        guard length <= maxBodyBytes else { return .reject(413) }
        let bodyStart = divider.upperBound
        let available = data.count - bodyStart
        guard available >= length else { return .incomplete }
        guard available == length else { return .reject(400) }
        return .request(HTTPRequest(method: method, path: String(pieces[1]), headers: headers,
                                    body: Data(data[bodyStart...])))
    }
}

public struct WitnessServiceCredential: Sendable {
    public let clusterID: String
    public let token: String
    public init(clusterID: String, token: String) { self.clusterID = clusterID; self.token = token }
}

struct WitnessRouter: Sendable {
    let store: LeaseStore
    private let codes: [String: Data]
    private static let authContext = Data("SwiftMesh-witness-auth-v1".utf8)

    init(store: LeaseStore, clusterID: String, token: String) throws {
        try self.init(store: store, services: [WitnessServiceCredential(clusterID: clusterID, token: token)])
    }

    init(store: LeaseStore, services: [WitnessServiceCredential]) throws {
        guard services.count <= 32,
              Set(services.map(\.clusterID)).count == services.count,
              Set(services.map(\.token)).count == services.count else { throw WitnessError.invalidConfiguration }
        var codes: [String: Data] = [:]
        for service in services {
            guard !service.clusterID.isEmpty, service.clusterID.utf8.count <= 128,
                  !service.clusterID.contains(where: { $0.isNewline }),
                  service.token.utf8.count >= 32, service.token.utf8.count <= 512,
                  !service.token.contains(where: \.isWhitespace) else { throw WitnessError.invalidConfiguration }
            let key = SymmetricKey(data: Data(service.token.utf8))
            codes[service.clusterID] = Data(HMAC<SHA256>.authenticationCode(for: Self.authContext, using: key))
        }
        self.store = store
        self.codes = codes
    }

    func route(_ request: HTTPRequest) async -> LeaseReply {
        if request.method == "GET", request.path == "/health" || request.path.hasPrefix("/health?") {
            do {
                let snapshot = try await store.snapshot()
                let ready = snapshot.recoverySeconds <= 0
                return LeaseReply(status: ready ? 200 : 503,
                                  body: Data((ready ? #"{"ready":true}"# : #"{"ready":false}"#).utf8))
            } catch { return .error("authority_unavailable", status: 503) }
        }
        guard request.method == "POST", request.path.hasPrefix("/v1/lease/"),
              let action = LeaseAction(rawValue: String(request.path.dropFirst("/v1/lease/".count))) else {
            return .error("not_found", status: 404)
        }
        guard let allowedCluster = authorizedCluster(request.headers["authorization"]) else {
            return .error("unauthorized", status: 401)
        }
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
              let payload = try? JSONDecoder().decode(LeaseRequest.self, from: request.body) else {
            return .error("invalid_request", status: 400)
        }
        guard codes[payload.clusterID] != nil else { return .error("unknown_cluster", status: 403) }
        guard payload.clusterID == allowedCluster else { return .error("forbidden_cluster", status: 403) }
        return await store.apply(action, request: payload)
    }

    private func authorizedCluster(_ header: String?) -> String? {
        guard let header, header.hasPrefix("Bearer "), header.utf8.count <= 519 else { return nil }
        let suppliedKey = SymmetricKey(data: Data(header.dropFirst(7).utf8))
        var matched: String?
        for (cluster, code) in codes {
            if HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Self.authContext, using: suppliedKey) {
                matched = cluster
            }
        }
        return matched
    }
}
