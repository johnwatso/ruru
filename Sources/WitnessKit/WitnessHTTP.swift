import CryptoKit
import Foundation

struct HTTPRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

/// A deliberately narrow browser surface hosted beside the authority protocol.
/// It cannot alter lease routing: `/v1/*` remains owned by `WitnessRouter`, and
/// the application supplies a handler only for the Web UI path namespace.
public struct WitnessWebRequest: Sendable {
    public let method: String
    public let path: String
    public let headers: [String: String]
    public let body: Data
    /// True only when the TCP peer is this Mac. The bundled cloudflared helper
    /// connects locally, so handlers can refuse a direct LAN peer.
    public let isLoopbackPeer: Bool

    init(_ request: HTTPRequest, isLoopbackPeer: Bool) {
        method = request.method; path = request.path; headers = request.headers; body = request.body
        self.isLoopbackPeer = isLoopbackPeer
    }
}

/// A complete browser response. The HTTP server validates header values before
/// writing them, so a Web UI handler cannot introduce response splitting.
public struct WitnessWebResponse: Sendable {
    public let status: Int
    public let contentType: String
    public let body: Data
    public let headers: [String: String]

    public init(status: Int = 200, contentType: String = "application/json; charset=utf-8",
                body: Data = Data(), headers: [String: String] = [:]) {
        self.status = status; self.contentType = contentType; self.body = body; self.headers = headers
    }
}

public typealias WitnessWebHandler = @Sendable (WitnessWebRequest) async -> WitnessWebResponse?

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

/// A bearer token issued to one paired server. It is accepted only for
/// requests that name this node, so a leaked token cannot impersonate a sibling
/// and can be revoked on its own.
public struct WitnessNodeToken: Codable, Sendable, Equatable {
    public let nodeID: String
    public let token: String
    public let name: String?
    /// The token this one replaced. Admitted only until `previousExpires`, so a client whose
    /// rotation response was lost can retry and collect the current token.
    public let previousToken: String?
    public let previousExpires: Date?
    public init(nodeID: String, token: String, name: String? = nil,
                previousToken: String? = nil, previousExpires: Date? = nil) {
        self.nodeID = nodeID; self.token = token; self.name = name
        self.previousToken = previousToken; self.previousExpires = previousExpires
    }
}

public struct WitnessServiceCredential: Sendable {
    public static let maxNodeTokens = 32
    public let clusterID: String
    public let token: String
    /// The shared token this one replaced, while a rotation grace period lasts. It can still
    /// authenticate, and `/v1/credential/rotate` returns the current token to its holder.
    public let previousToken: String?
    public let nodeTokens: [WitnessNodeToken]
    public let primaryPreference: WitnessPrimaryPreference
    public let coordinationPolicy: CoordinationPolicy
    public let leaseSeconds: Double
    public init(clusterID: String, token: String, previousToken: String? = nil, nodeTokens: [WitnessNodeToken] = [],
                primaryPreference: WitnessPrimaryPreference = .init(),
                coordinationPolicy: CoordinationPolicy = .init(), leaseSeconds: Double = LeaseStore.leaseDuration) {
        self.clusterID = clusterID
        self.token = token
        self.previousToken = previousToken
        self.nodeTokens = nodeTokens
        self.primaryPreference = primaryPreference
        self.coordinationPolicy = coordinationPolicy
        self.leaseSeconds = leaseSeconds
    }
}

/// Who a bearer token speaks for. `nodeID` is nil for the shared service token.
struct WitnessIdentity: Sendable, Equatable {
    let clusterID: String
    let nodeID: String?
    /// True when the caller presented a token that has since been replaced.
    var usedPrevious = false

    /// A node token may only act as its own node.
    func permits(nodeID claimed: String?) -> Bool {
        guard let nodeID else { return true }
        return claimed == nil || claimed == nodeID
    }
}

struct WitnessAuthorization: Sendable {
    private struct NodeCode: Sendable { let identity: WitnessIdentity; let code: Data }
    private let codes: [String: Data]
    private let nodeCodes: [NodeCode]
    private let previousCodes: [String: Data]
    private let previousNodeCodes: [NodeCode]
    private static let authContext = Data("Ruru-auth-v1".utf8)
    init() { codes = [:]; nodeCodes = []; previousCodes = [:]; previousNodeCodes = [] }

    init(services: [WitnessServiceCredential]) throws {
        let everyToken = services.flatMap {
            [$0.token] + [$0.previousToken].compactMap { $0 } +
                $0.nodeTokens.flatMap { [$0.token] + [$0.previousToken].compactMap { $0 } }
        }
        guard services.count <= 32,
              Set(services.map(\.clusterID)).count == services.count,
              Set(everyToken).count == everyToken.count else { throw WitnessError.invalidConfiguration }
        var codes: [String: Data] = [:]
        var nodeCodes: [NodeCode] = []
        var previousCodes: [String: Data] = [:]
        var previousNodeCodes: [NodeCode] = []
        func valid(_ token: String) -> Bool {
            token.utf8.count >= 32 && token.utf8.count <= 512 && !token.contains(where: \.isWhitespace)
        }
        func code(_ token: String) -> Data {
            Data(HMAC<SHA256>.authenticationCode(for: Self.authContext, using: SymmetricKey(data: Data(token.utf8))))
        }
        for service in services {
            guard !service.clusterID.isEmpty, service.clusterID.utf8.count <= 128,
                  !service.clusterID.contains(where: { $0.isNewline }),
                  service.token.utf8.count >= 32, service.token.utf8.count <= 512,
                  !service.token.contains(where: \.isWhitespace),
                  service.primaryPreference.isValid, service.coordinationPolicy.isValid,
                  LeaseStore.leaseDurationRange.contains(service.leaseSeconds) else { throw WitnessError.invalidConfiguration }
            codes[service.clusterID] = code(service.token)
            if let previous = service.previousToken {
                guard valid(previous) else { throw WitnessError.invalidConfiguration }
                previousCodes[service.clusterID] = code(previous)
            }
            guard service.nodeTokens.count <= WitnessServiceCredential.maxNodeTokens,
                  Set(service.nodeTokens.map(\.nodeID)).count == service.nodeTokens.count else { throw WitnessError.invalidConfiguration }
            for node in service.nodeTokens {
                guard WitnessPrimaryPreference.validNodeID(node.nodeID),
                      node.token.utf8.count >= 32, node.token.utf8.count <= 512,
                      !node.token.contains(where: \.isWhitespace) else { throw WitnessError.invalidConfiguration }
                nodeCodes.append(NodeCode(identity: WitnessIdentity(clusterID: service.clusterID, nodeID: node.nodeID),
                                          code: code(node.token)))
                if let previous = node.previousToken {
                    guard valid(previous) else { throw WitnessError.invalidConfiguration }
                    previousNodeCodes.append(NodeCode(identity: WitnessIdentity(clusterID: service.clusterID, nodeID: node.nodeID, usedPrevious: true),
                                                      code: code(previous)))
                }
            }
        }
        self.codes = codes
        self.nodeCodes = nodeCodes
        self.previousCodes = previousCodes
        self.previousNodeCodes = previousNodeCodes
    }
    func cluster(for header: String?) -> String? { identity(for: header)?.clusterID }

    /// Compares against every credential so timing does not reveal which one matched.
    func identity(for header: String?) -> WitnessIdentity? {
        guard let header, header.hasPrefix("Bearer "), header.utf8.count <= 519 else { return nil }
        let suppliedKey = SymmetricKey(data: Data(header.dropFirst(7).utf8))
        var matched: WitnessIdentity?
        for (cluster, code) in codes {
            if HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Self.authContext, using: suppliedKey) {
                matched = WitnessIdentity(clusterID: cluster, nodeID: nil)
            }
        }
        for node in nodeCodes {
            if HMAC<SHA256>.isValidAuthenticationCode(node.code, authenticating: Self.authContext, using: suppliedKey) {
                matched = node.identity
            }
        }
        for (cluster, code) in previousCodes {
            if HMAC<SHA256>.isValidAuthenticationCode(code, authenticating: Self.authContext, using: suppliedKey) {
                matched = WitnessIdentity(clusterID: cluster, nodeID: nil, usedPrevious: true)
            }
        }
        for node in previousNodeCodes {
            if HMAC<SHA256>.isValidAuthenticationCode(node.code, authenticating: Self.authContext, using: suppliedKey) {
                matched = node.identity
            }
        }
        return matched
    }
}

/// What the app decided about a `POST /v1/credential/rotate` request.
public enum WitnessRotationOutcome: Sendable, Equatable {
    /// `token` is the caller's current credential; the one they presented stays valid for `previousValidSeconds`.
    case issued(token: String, previousValidSeconds: Double)
    /// A shared-token caller asked while no rotation was in progress.
    case notPending
    case throttled
    case failed
}

/// Supplied by the application, which owns persistence. Called only after the bearer token authenticated.
/// `usedPrevious` is true when the caller still holds a replaced token and just needs the current one.
public typealias WitnessCredentialRotator = @Sendable (_ clusterID: String, _ nodeID: String?, _ usedPrevious: Bool) async -> WitnessRotationOutcome

struct WitnessRouter: Sendable {
    let store: LeaseStore
    private let authorization: WitnessAuthorization
    let services: [WitnessServiceCredential]
    let catalogue: CoordinationCatalogue
    let pairing: PairingDesk
    let participants: ParticipantPresence
    let operationalStatus: OperationalStatusRegistry
    private let authorityVersion: String?
    private let authorityBuild: String?
    private let policies: [String: WitnessServicePolicy]
    private let leaseSeconds: [String: Double]
    private let rotator: WitnessCredentialRotator?

    init(store: LeaseStore, clusterID: String, token: String, authorityVersion: String? = nil,
         authorityBuild: String? = nil) throws {
        try self.init(store: store, services: [WitnessServiceCredential(clusterID: clusterID, token: token)],
                      authorityVersion: authorityVersion, authorityBuild: authorityBuild)
    }

    init(store: LeaseStore, services: [WitnessServiceCredential], catalogue: CoordinationCatalogue? = nil,
         pairing: PairingDesk? = nil, participants: ParticipantPresence? = nil,
         operationalStatus: OperationalStatusRegistry? = nil, authorityVersion: String? = nil,
         authorityBuild: String? = nil, rotator: WitnessCredentialRotator? = nil) throws {
        self.rotator = rotator
        authorization = try WitnessAuthorization(services: services)
        self.services = services
        self.store = store
        self.catalogue = try catalogue ?? CoordinationCatalogue(services: services)
        self.pairing = pairing ?? PairingDesk()
        self.participants = try participants ?? ParticipantPresence(services: services)
        self.operationalStatus = try operationalStatus ?? OperationalStatusRegistry(services: services)
        self.authorityVersion = authorityVersion
        self.authorityBuild = authorityBuild
        policies = Dictionary(uniqueKeysWithValues: services.map {
            ($0.clusterID, WitnessServicePolicy(clusterID: $0.clusterID, preference: $0.primaryPreference))
        })
        leaseSeconds = Dictionary(uniqueKeysWithValues: services.map { ($0.clusterID, $0.leaseSeconds) })
    }

    func route(_ request: HTTPRequest) async -> LeaseReply {
        if request.path.hasPrefix("/v1/participants/") { return await participants.route(request) }
        if request.path.hasPrefix("/v1/operational-status/") { return await operationalStatus.route(request) }
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
        if request.method == "POST", request.path == "/v1/credential/rotate" {
            return await routeRotation(request)
        }
        if request.method == "GET", request.path == "/v1/service" {
            guard let identity = authorization.identity(for: request.headers["authorization"]),
                  let service = services.first(where: { $0.clusterID == identity.clusterID }) else {
                return .error("unauthorized", status: 401)
            }
            let cluster = identity.clusterID
            do {
                let status = try await store.status(for: cluster)
                let body = try JSONEncoder().encode(WitnessServiceDescription(service: service, lease: status.lease,
                                                                             recoverySeconds: status.recoverySeconds,
                                                                             authorityVersion: authorityVersion,
                                                                             authorityBuild: authorityBuild,
                                                                             rotationAvailable: rotator != nil,
                                                                             rotationPending: identity.usedPrevious))
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
        guard let identity = authorization.identity(for: request.headers["authorization"]) else {
            return .error("unauthorized", status: 401)
        }
        let allowedCluster = identity.clusterID
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
              let payload = try? JSONDecoder().decode(LeaseRequest.self, from: request.body) else {
            return .error("invalid_request", status: 400)
        }
        guard policies[payload.clusterID] != nil else { return .error("unknown_cluster", status: 403) }
        guard payload.clusterID == allowedCluster else { return .error("forbidden_cluster", status: 403) }
        guard identity.permits(nodeID: payload.nodeID) else { return .error("forbidden_node", status: 403) }
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

// MARK: Credential rotation

private struct RotationRequest: Decodable { let clusterID: String }

extension WitnessRouter {
    /// A paired server (own node token) rotates its own credential; a shared-token holder can only
    /// collect the token an operator already rotated. The caller never chooses the new value.
    func routeRotation(_ request: HTTPRequest) async -> LeaseReply {
        guard let rotator else { return .error("not_found", status: 404) }
        guard let identity = authorization.identity(for: request.headers["authorization"]) else {
            return .error("unauthorized", status: 401)
        }
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
              let payload = try? JSONDecoder().decode(RotationRequest.self, from: request.body) else {
            return .error("invalid_request", status: 400)
        }
        guard payload.clusterID == identity.clusterID else { return .error("forbidden_cluster", status: 403) }
        switch await rotator(identity.clusterID, identity.nodeID, identity.usedPrevious) {
        case .issued(let token, let seconds):
            let body = (try? JSONSerialization.data(withJSONObject: [
                "version": 1, "clusterID": identity.clusterID, "token": token, "previousValidSeconds": seconds
            ] as [String: Any], options: [.sortedKeys])) ?? Data()
            return LeaseReply(status: 200, body: body)
        case .notPending: return .error("no_rotation_pending", status: 409)
        case .throttled: return .error("rotation_throttled", status: 429)
        case .failed: return .error("authority_unavailable", status: 503)
        }
    }
}
