import Foundation

/// Bounded, ephemeral observations. Restart begins empty; clients must re-report.
/// This actor never opens the lease database or performs network/file operations.
public actor CoordinationCatalogue {
    static let batchSize = 8
    static let pageSize = 20
    static let freshSeconds = 90
    static let retainedSeconds = 600
    static let maxNodes = 16
    static let maxPerNode = 128
    static let maxPerService = 512
    static let maxTotal = 2_048
    static let maxEnrollmentsPerService = 8
    static let maxEnrollmentsTotal = 64

    private struct Enrollment: Sendable {
        let id: UUID
        let clusterID: String
        let nodeID: String
        let nodeName: String?
        let origin: String
        let received: Double
        var rejected = false
    }
    private var enrollments: [UUID: Enrollment] = [:]

    private struct Observation: Sendable {
        let resource: CoordinationResource
        let received: Double
    }
    private struct Node: Sendable {
        var name: String?
        var received: Double
        var resources: [CoordinationResourceKey: Observation] = [:]
    }
    private var nodes: [String: [String: Node]] = [:]
    private var services: [String: WitnessServiceCredential] = [:]
    private var authorization: WitnessAuthorization
    private var revisions: [String: String] = [:]
    private let clock: @Sendable () -> Double

    public init() {
        authorization = WitnessAuthorization()
        clock = Self.liveClock()
    }

    init(services: [WitnessServiceCredential], clock: (@Sendable () -> Double)? = nil) throws {
        authorization = try WitnessAuthorization(services: services)
        self.services = Dictionary(uniqueKeysWithValues: services.map { ($0.clusterID, $0) })
        self.clock = clock ?? Self.liveClock()
        revisions = Dictionary(uniqueKeysWithValues: services.map { ($0.clusterID, UUID().uuidString) })
    }

    private static func liveClock() -> @Sendable () -> Double {
        let origin = ContinuousClock.now
        return {
            let elapsed = origin.duration(to: ContinuousClock.now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        }
    }

    public func configureServices(_ credentials: [WitnessServiceCredential]) throws {
        let newAuthorization = try WitnessAuthorization(services: credentials)
        let newServices = Dictionary(uniqueKeysWithValues: credentials.map { ($0.clusterID, $0) })
        enrollments = enrollments.filter { _, proposal in
            guard let next = newServices[proposal.clusterID], next.token == services[proposal.clusterID]?.token else { return false }
            // Explicitly disabling an enabled catalogue revokes outstanding requests.
            if services[proposal.clusterID]?.coordinationPolicy.enabled == true && !next.coordinationPolicy.enabled { return false }
            return !(next.coordinationPolicy.enabled && next.coordinationPolicy.allowedOrigins.contains(proposal.origin))
        }
        // Revocation and narrower origin policies discard observations immediately.
        // Token rotation also starts a new reporting scope.
        for cluster in Array(nodes.keys) {
            guard let next = newServices[cluster], next.coordinationPolicy.enabled,
                  next.token == services[cluster]?.token else { nodes.removeValue(forKey: cluster); continue }
            var group = nodes[cluster] ?? [:]
            for (nodeID, var node) in group {
                node.resources = node.resources.filter { next.coordinationPolicy.permits($0.value.resource.url) }
                group[nodeID] = node
            }
            nodes[cluster] = group
        }
        revisions = Dictionary(uniqueKeysWithValues: credentials.map { service in
            let previous = services[service.clusterID]
            let unchanged = previous?.token == service.token && previous?.coordinationPolicy == service.coordinationPolicy
            return (service.clusterID, unchanged ? (revisions[service.clusterID] ?? UUID().uuidString) : UUID().uuidString)
        })
        services = newServices
        authorization = newAuthorization
    }

    func route(_ request: HTTPRequest) -> LeaseReply {
        guard request.method == "POST",
              ["/v1/coordination/capabilities", "/v1/coordination/report", "/v1/coordination/catalogue", "/v1/coordination/enrollment"].contains(request.path) else {
            return .error("not_found", status: 404)
        }
        guard let identity = authorization.identity(for: request.headers["authorization"]) else {
            return .error("unauthorized", status: 401)
        }
        let cluster = identity.clusterID
        guard !request.body.isEmpty, request.body.count <= HTTPParser.maxBodyBytes,
              let scope = try? JSONDecoder().decode(CoordinationScopeRequest.self, from: request.body) else {
            return .error("invalid_request", status: 400)
        }
        guard scope.clusterID == cluster else { return .error("forbidden_cluster", status: 403) }
        // Node tokens may only name their own node in reports and enrolments.
        struct NodeProbe: Decodable { let nodeID: String? }
        guard identity.permits(nodeID: (try? JSONDecoder().decode(NodeProbe.self, from: request.body))?.nodeID) else {
            return .error("forbidden_node", status: 403)
        }
        guard scope.version == 1 else { return .error("unsupported_version", status: 409) }
        guard let service = services[cluster] else { return .error("unknown_cluster", status: 403) }
        let policy = service.coordinationPolicy
        if request.path == "/v1/coordination/capabilities" {
            return reply(CoordinationCapabilities(version: 1, clusterID: cluster, enabled: policy.enabled,
                capabilities: policy.enabled ? ["resource-catalogue.v1"] : [], allowedOrigins: policy.allowedOrigins,
                maxBatchSize: Self.batchSize, pageSize: Self.pageSize, freshForSeconds: Self.freshSeconds,
                retainedForSeconds: Self.retainedSeconds, maxNodesPerService: Self.maxNodes,
                maxLocationsPerNode: Self.maxPerNode, maxLocationsPerService: Self.maxPerService, maxLocationsTotal: Self.maxTotal,
                enrollmentSupported: true))
        }
        if request.path == "/v1/coordination/enrollment" {
            guard let proposal = try? JSONDecoder().decode(CoordinationEnrollmentRequest.self, from: request.body) else {
                return .error("invalid_request", status: 400)
            }
            return enroll(proposal, policy: policy)
        }
        guard policy.enabled else { return .error("capability_disabled", status: 403) }
        prune()
        if request.path == "/v1/coordination/report" {
            guard let report = try? JSONDecoder().decode(CoordinationReport.self, from: request.body) else {
                return .error("invalid_request", status: 400)
            }
            return apply(report, policy: policy)
        }
        guard let query = try? JSONDecoder().decode(CoordinationCatalogueRequest.self, from: request.body),
              query.offset >= 0, query.offset <= Self.maxPerService,
              query.offset % Self.pageSize == 0 else { return .error("invalid_request", status: 400) }
        if query.offset > 0, query.revision == nil { return .error("invalid_request", status: 400) }
        let revision = revisions[cluster] ?? ""
        if let expected = query.revision, expected != revision { return .error("catalogue_changed", status: 409) }
        let locations = locations(cluster: cluster)
        guard query.offset <= locations.count else { return .error("invalid_request", status: 400) }
        let end = min(query.offset + Self.pageSize, locations.count)
        return reply(CoordinationCataloguePage(version: 1, clusterID: cluster, revision: revision,
            locations: Array(locations[query.offset..<end]), nextOffset: end < locations.count ? end : nil))
    }

    public func snapshot() -> [CoordinationLocation] {
        prune()
        return nodes.keys.sorted().flatMap { locations(cluster: $0) }
    }

    public func pendingEnrollments() -> [CoordinationEnrollment] {
        prune()
        return enrollments.values.filter { !$0.rejected }.map { proposal in
            CoordinationEnrollment(id: proposal.id, clusterID: proposal.clusterID, nodeID: proposal.nodeID,
                nodeName: proposal.nodeName, origin: proposal.origin, ageSeconds: max(0, clock() - proposal.received))
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func rejectEnrollment(id: UUID) {
        prune()
        enrollments[id]?.rejected = true
    }

    private func enroll(_ request: CoordinationEnrollmentRequest, policy: CoordinationPolicy) -> LeaseReply {
        guard CoordinationResourceKey.valid(request.nodeID, bytes: 128),
              request.nodeName.map({ WitnessNodeName.normalized($0) == $0 }) != false,
              request.origin.utf8.count <= 256, CoordinationPolicy.normalizedOrigin(request.origin) == request.origin else {
            return .error("invalid_enrollment", status: 400)
        }
        prune()
        let existing = enrollments.values.first {
            $0.clusterID == request.clusterID && $0.nodeID == request.nodeID && $0.origin == request.origin
        }
        let status: String
        if request.withdraw {
            if let existing { enrollments[existing.id] = nil }
            status = "withdrawn"
        } else if policy.enabled && policy.allowedOrigins.contains(request.origin) {
            status = "approved"
        } else if let existing {
            status = existing.rejected ? "rejected" : "pending"
        } else {
            guard enrollments.count < Self.maxEnrollmentsTotal,
                  enrollments.values.filter({ $0.clusterID == request.clusterID }).count < Self.maxEnrollmentsPerService else {
                return .error("enrollment_capacity", status: 429)
            }
            let proposal = Enrollment(id: UUID(), clusterID: request.clusterID, nodeID: request.nodeID,
                nodeName: request.nodeName, origin: request.origin, received: clock())
            enrollments[proposal.id] = proposal
            status = "pending"
        }
        return reply(CoordinationEnrollmentReply(version: 1, clusterID: request.clusterID, status: status))
    }

    private func apply(_ report: CoordinationReport, policy: CoordinationPolicy) -> LeaseReply {
        guard CoordinationResourceKey.valid(report.nodeID, bytes: 128),
              report.nodeName.map({ WitnessNodeName.normalized($0) == $0 }) != false,
              report.resources.count <= Self.batchSize, report.removed.count <= Self.batchSize,
              report.resources.allSatisfy({ $0.isValid(policy: policy) }), report.removed.allSatisfy(\.isValid),
              Set(report.resources.map(\.key)).count == report.resources.count,
              Set(report.removed).count == report.removed.count,
              Set(report.resources.map(\.key)).isDisjoint(with: Set(report.removed)) else {
            return .error("invalid_report", status: 400)
        }
        let now = clock()
        var group = nodes[report.clusterID] ?? [:]
        var node = group[report.nodeID] ?? Node(received: now)
        node.name = report.nodeName
        node.received = now
        for key in report.removed { node.resources.removeValue(forKey: key) }
        for resource in report.resources { node.resources[resource.key] = Observation(resource: resource, received: now) }
        group[report.nodeID] = node
        let groupCount = group.values.reduce(0) { $0 + $1.resources.count }
        let otherCount = nodes.filter { $0.key != report.clusterID }.values.reduce(0) { total, group in
            total + group.values.reduce(0) { $0 + $1.resources.count }
        }
        guard group.count <= Self.maxNodes, node.resources.count <= Self.maxPerNode,
              groupCount <= Self.maxPerService, groupCount + otherCount <= Self.maxTotal else {
            return .error("catalogue_capacity", status: 429)
        }
        nodes[report.clusterID] = group
        revisions[report.clusterID] = UUID().uuidString
        return LeaseReply(status: 200, body: Data(#"{"version":1,"accepted":true}"#.utf8))
    }

    private func prune() {
        let now = clock()
        enrollments = enrollments.filter { now - $0.value.received < Double(Self.retainedSeconds) }
        for cluster in Array(nodes.keys) {
            var changed = false
            for nodeID in Array(nodes[cluster]?.keys ?? Dictionary<String, Node>().keys) {
                guard var node = nodes[cluster]?[nodeID] else { continue }
                if now - node.received >= Double(Self.retainedSeconds) {
                    nodes[cluster]?.removeValue(forKey: nodeID)
                    changed = true
                } else {
                    let retained = node.resources.filter { now - $0.value.received < Double(Self.retainedSeconds) }
                    if retained.count != node.resources.count { changed = true }
                    node.resources = retained
                    nodes[cluster]?[nodeID] = node
                }
            }
            if nodes[cluster]?.isEmpty == true { nodes.removeValue(forKey: cluster) }
            if changed { revisions[cluster] = UUID().uuidString }
        }
    }

    private func locations(cluster: String) -> [CoordinationLocation] {
        let now = clock()
        return (nodes[cluster] ?? [:]).flatMap { nodeID, node in
            node.resources.values.map { observation in
                let age = max(0, now - observation.received)
                return CoordinationLocation(clusterID: cluster, nodeID: nodeID, nodeName: node.name,
                    resource: observation.resource, ageSeconds: age, fresh: age < Double(Self.freshSeconds))
            }
        }.sorted { $0.id.lexicographicallyPrecedes($1.id) }
    }

    private func reply<T: Encodable>(_ value: T) -> LeaseReply {
        guard let body = try? JSONEncoder().encode(value) else { return .error("catalogue_unavailable", status: 503) }
        return LeaseReply(status: 200, body: body)
    }
}
