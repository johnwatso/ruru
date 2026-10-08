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
    public let primaryPreference: WitnessPrimaryPreference
    public let coordinationPolicy: CoordinationPolicy
    public let leaseSeconds: Double
    public init(clusterID: String, token: String, primaryPreference: WitnessPrimaryPreference = .init(),
                coordinationPolicy: CoordinationPolicy = .init(), leaseSeconds: Double = LeaseStore.leaseDuration) {
        self.clusterID = clusterID
        self.token = token
        self.primaryPreference = primaryPreference
        self.coordinationPolicy = coordinationPolicy
        self.leaseSeconds = leaseSeconds
    }
}

struct WitnessAuthorization: Sendable {
    private let codes: [String: Data]
    private static let authContext = Data("Ruru-auth-v1".utf8)
    init() { codes = [:] }

    init(services: [WitnessServiceCredential]) throws {
        guard services.count <= 32,
              Set(services.map(\.clusterID)).count == services.count,
              Set(services.map(\.token)).count == services.count else { throw WitnessError.invalidConfiguration }
        var codes: [String: Data] = [:]
        for service in services {
            guard !service.clusterID.isEmpty, service.clusterID.utf8.count <= 128,
                  !service.clusterID.contains(where: { $0.isNewline }),
                  service.token.utf8.count >= 32, service.token.utf8.count <= 512,
                  !service.token.contains(where: \.isWhitespace),
                  service.primaryPreference.isValid, service.coordinationPolicy.isValid,
                  LeaseStore.leaseDurationRange.contains(service.leaseSeconds) else { throw WitnessError.invalidConfiguration }
            let key = SymmetricKey(data: Data(service.token.utf8))
            codes[service.clusterID] = Data(HMAC<SHA256>.authenticationCode(for: Self.authContext, using: key))
        }
        self.codes = codes
    }
    func cluster(for header: String?) -> String? {
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

struct WitnessRouter: Sendable {
    let store: LeaseStore
    private let authorization: WitnessAuthorization
    let services: [WitnessServiceCredential]
    let catalogue: CoordinationCatalogue
    let pairing: PairingDesk
    let participants: ParticipantPresence
    private let policies: [String: WitnessServicePolicy]
    private let leaseSeconds: [String: Double]

    init(store: LeaseStore, clusterID: String, token: String) throws {
        try self.init(store: store, services: [WitnessServiceCredential(clusterID: clusterID, token: token)])
    }

    init(store: LeaseStore, services: [WitnessServiceCredential], catalogue: CoordinationCatalogue? = nil,
         pairing: PairingDesk? = nil, participants: ParticipantPresence? = nil) throws {
        authorization = try WitnessAuthorization(services: services)
        self.services = services
        self.store = store
        self.catalogue = try catalogue ?? CoordinationCatalogue(services: services)
        self.pairing = pairing ?? PairingDesk()
        self.participants = try participants ?? ParticipantPresence(services: services)
        policies = Dictionary(uniqueKeysWithValues: services.map {
            ($0.clusterID, WitnessServicePolicy(clusterID: $0.clusterID, preference: $0.primaryPreference))
        })
        leaseSeconds = Dictionary(uniqueKeysWithValues: services.map { ($0.clusterID, $0.leaseSeconds) })
    }

    func route(_ request: HTTPRequest) async -> LeaseReply {
        if request.path.hasPrefix("/v1/participants/") { return await participants.route(request) }
        if request.path.hasPrefix("/v1/coordination/") { return await catalogue.route(request) }
        if request.method == "GET", request.path == "/health" || request.path.hasPrefix("/health?") {
            do {
                let snapshot = try await store.snapshot()
                let ready = snapshot.recoverySeconds <= 0
                return LeaseReply(status: ready ? 200 : 503,
                                  body: Data((ready ? #"{"ready":true}"# : #"{"ready":false}"#).utf8))
            } catch { return .error("authority_unavailable", status: 503) }
        }
        if request.method == "POST", request.path == "/v1/pair" || request.path == "/v1/pair/status" {
            return await routePairing(request)
        }
        if request.method == "GET", request.path == "/v1/service" {
            guard let cluster = authorization.cluster(for: request.headers["authorization"]),
                  let service = services.first(where: { $0.clusterID == cluster }) else {
                return .error("unauthorized", status: 401)
            }
            do {
                let status = try await store.status(for: cluster)
                let body = try JSONEncoder().encode(WitnessServiceDescription(service: service, lease: status.lease,
                                                                             recoverySeconds: status.recoverySeconds))
                return LeaseReply(status: 200, body: body)
            } catch { return .error("authority_unavailable", status: 503) }
        }
        if request.method == "POST", request.path == "/v1/service/policy" {
            guard let allowedCluster = authorization.cluster(for: request.headers["authorization"]) else {
                return .error("unauthorized", status: 401)
            }
            guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
                  let payload = try? JSONDecoder().decode(WitnessServicePolicyRequest.self, from: request.body) else {
                return .error("invalid_request", status: 400)
            }
            guard let policy = policies[payload.clusterID] else { return .error("unknown_cluster", status: 403) }
            guard payload.clusterID == allowedCluster else { return .error("forbidden_cluster", status: 403) }
            guard let body = try? JSONEncoder().encode(policy) else { return .error("authority_unavailable", status: 503) }
            return LeaseReply(status: 200, body: body)
        }
        guard request.method == "POST", request.path.hasPrefix("/v1/lease/"),
              let action = LeaseAction(rawValue: String(request.path.dropFirst("/v1/lease/".count))) else {
            return .error("not_found", status: 404)
        }
        guard let allowedCluster = authorization.cluster(for: request.headers["authorization"]) else {
            return .error("unauthorized", status: 401)
        }
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
              let payload = try? JSONDecoder().decode(LeaseRequest.self, from: request.body) else {
            return .error("invalid_request", status: 400)
        }
        guard policies[payload.clusterID] != nil else { return .error("unknown_cluster", status: 403) }
        guard payload.clusterID == allowedCluster else { return .error("forbidden_cluster", status: 403) }
        return await store.apply(action, request: payload,
                                 leaseDuration: leaseSeconds[payload.clusterID] ?? LeaseStore.leaseDuration)
    }
}

// MARK: Pairing

struct PairClaim: Decodable {
    let code: String
    let nodeID: String
    let nodeName: String?
}

struct PairStatusRequest: Decodable {
    let pairingID: String
}

extension WitnessRouter {
    /// Unauthenticated by design: the code (or pairing ID) is the credential,
    /// and nothing is released until the operator approves in Ruru.
    func routePairing(_ request: HTTPRequest) async -> LeaseReply {
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes else {
            return .error("invalid_request", status: 400)
        }
        func json(_ status: Int, _ object: [String: Any]) -> LeaseReply {
            LeaseReply(status: status, body: (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data())
        }
        if request.path == "/v1/pair" {
            guard let claim = try? JSONDecoder().decode(PairClaim.self, from: request.body),
                  WitnessPrimaryPreference.validNodeID(claim.nodeID) else {
                return .error("invalid_request", status: 400)
            }
            switch await pairing.claim(code: claim.code, nodeID: claim.nodeID, nodeName: WitnessNodeName.normalized(claim.nodeName)) {
            case .accepted(let id): return json(202, ["pairingID": id, "status": "pending", "retryAfter": 2])
            case .invalid: return .error("invalid_code", status: 404)
            case .throttled: return .error("too_many_attempts", status: 429)
            case .full: return .error("pairing_busy", status: 503)
            }
        }
        guard let poll = try? JSONDecoder().decode(PairStatusRequest.self, from: request.body),
              !poll.pairingID.isEmpty, poll.pairingID.utf8.count <= 64 else {
            return .error("invalid_request", status: 400)
        }
        switch await pairing.status(of: poll.pairingID) {
        case .pending: return json(202, ["status": "pending", "retryAfter": 2])
        case .rejected: return .error("pairing_rejected", status: 403)
        case .expired: return .error("pairing_expired", status: 410)
        case .approved(let credential):
            return json(200, ["status": "approved", "clusterID": credential.clusterID,
                              "token": credential.token, "leaseSeconds": credential.leaseSeconds])
        }
    }
}
