import Foundation
import Network

/// A small HTTP/1 listener for a dedicated HTTPS tunnel or reverse proxy.
/// Connections, request size, and read duration are bounded for older Macs.
public actor WitnessHTTPServer {
    private var configuringServices = false
    private var router: WitnessRouter
    private let webHandler: WitnessWebHandler?
    public nonisolated let catalogue: CoordinationCatalogue
    public nonisolated let pairing: PairingDesk
    public nonisolated let participants: ParticipantPresence
    public nonisolated let operationalStatus: OperationalStatusRegistry
    private let authorityVersion: String?
    private let authorityBuild: String?
    private let queue = DispatchQueue(label: "dev.ruruapp.ruru.http", qos: .utility)
    private var listener: NWListener?
    private var listenerID = UUID()
    private var startContinuation: CheckedContinuation<UInt16, any Error>?
    private var startupTimeout: Task<Void, Never>?
    private var failureMessage: String?
    private var connections: [UUID: Connection] = [:]

    private struct Connection {
        let network: NWConnection
        var buffer = Data()
        let timeout: Task<Void, Never>
        var coordination = false
        var web = false
    }

    public init(store: LeaseStore, clusterID: String, token: String, authorityVersion: String? = nil,
                authorityBuild: String? = nil, webHandler: WitnessWebHandler? = nil) throws {
        router = try WitnessRouter(store: store, clusterID: clusterID, token: token,
                                   authorityVersion: authorityVersion, authorityBuild: authorityBuild)
        catalogue = router.catalogue
        pairing = router.pairing
        participants = router.participants
        operationalStatus = router.operationalStatus
        self.authorityVersion = authorityVersion
        self.authorityBuild = authorityBuild
        self.webHandler = webHandler
    }

    public init(store: LeaseStore, services: [WitnessServiceCredential], catalogue: CoordinationCatalogue? = nil,
                pairing: PairingDesk? = nil, participants: ParticipantPresence? = nil,
                operationalStatus: OperationalStatusRegistry? = nil, authorityVersion: String? = nil,
                authorityBuild: String? = nil, webHandler: WitnessWebHandler? = nil) throws {
        router = try WitnessRouter(store: store, services: services, catalogue: catalogue, pairing: pairing, participants: participants,
                                  operationalStatus: operationalStatus, authorityVersion: authorityVersion,
                                  authorityBuild: authorityBuild)
        self.catalogue = router.catalogue
        self.pairing = router.pairing
        self.participants = router.participants
        self.operationalStatus = router.operationalStatus
        self.authorityVersion = authorityVersion
        self.authorityBuild = authorityBuild
        self.webHandler = webHandler
    }

    /// Changes admission only; the database, lease deadlines and listener stay alive.
    public func configureServices(_ services: [WitnessServiceCredential]) async throws {
        guard !configuringServices else { throw WitnessError.invalidConfiguration }
        let updated = try WitnessRouter(store: router.store, services: services, catalogue: catalogue, pairing: pairing, participants: participants,
                                        operationalStatus: operationalStatus, authorityVersion: authorityVersion,
                                        authorityBuild: authorityBuild)
        configuringServices = true
        defer { configuringServices = false }
        try await catalogue.configureServices(services)
        try await participants.configureServices(services)
        try await operationalStatus.configureServices(services)
        router = updated
    }

    public func start(bindAddress: String = "127.0.0.1", port: UInt16 = 38990) async throws -> UInt16 {
        guard listener == nil, ["127.0.0.1", "0.0.0.0", "::1"].contains(bindAddress),
              let endpointPort = NWEndpoint.Port(rawValue: port) else { throw WitnessError.invalidConfiguration }
        let beforePreparation = listenerID
        try await configureServices(router.services)
        guard listener == nil, listenerID == beforePreparation else { throw WitnessError.stopped }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        let networkListener = try NWListener(using: parameters)
        let generation = UUID()
        listenerID = generation
        failureMessage = nil
        listener = networkListener
        // Unwrap the weak reference before creating each Task: Swift 6.1 rejects
        // sending a captured `weak var` into a Task closure.
        networkListener.newConnectionHandler = { [weak self] connection in
            guard let server = self else { connection.cancel(); return }
            Task { await server.accept(connection, generation: generation) }
        }
        networkListener.stateUpdateHandler = { [weak self] state in
            guard let server = self else { return }
            Task { await server.listenerChanged(state, generation: generation) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startContinuation = continuation
            networkListener.start(queue: queue)
            startupTimeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                await self?.startTimedOut(generation: generation)
            }
        }
    }

    public func stop() {
        startupTimeout?.cancel()
        startupTimeout = nil
        startContinuation?.resume(throwing: WitnessError.stopped)
        startContinuation = nil
        listener?.cancel()
        listener = nil
        listenerID = UUID()
        for id in Array(connections.keys) { close(id) }
    }

    public func failure() -> String? { failureMessage }

    private func listenerChanged(_ state: NWListener.State, generation: UUID) {
        guard generation == listenerID else { return }
        switch state {
        case .ready:
            startupTimeout?.cancel()
            startupTimeout = nil
            if let port = listener?.port?.rawValue {
                startContinuation?.resume(returning: port)
                startContinuation = nil
            }
        case .failed(let error):
            startupTimeout?.cancel()
            startupTimeout = nil
            failureMessage = error.localizedDescription
            startContinuation?.resume(throwing: error)
            startContinuation = nil
            listener?.cancel()
            listener = nil
        case .cancelled:
            startupTimeout?.cancel()
            startupTimeout = nil
            startContinuation?.resume(throwing: WitnessError.stopped)
            startContinuation = nil
            listener = nil
        default: break
        }
    }

    private func startTimedOut(generation: UUID) {
        guard generation == listenerID, startContinuation != nil else { return }
        failureMessage = WitnessError.listenerUnavailable.localizedDescription
        startContinuation?.resume(throwing: WitnessError.listenerUnavailable)
        startContinuation = nil
        listener?.cancel()
        listener = nil
    }

    private func accept(_ network: NWConnection, generation: UUID) {
        guard listener != nil, generation == listenerID, connections.count < 32 else { network.cancel(); return }
        let id = UUID()
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.close(id)
        }
        connections[id] = Connection(network: network, timeout: timeout)
        network.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                guard let server = self else { return }
                Task { await server.close(id) }
            default: break
            }
        }
        network.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        connections[id]?.network.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            guard let server = self else { return }
            let failed = error != nil
            Task { await server.received(data, id: id, complete: complete, failed: failed) }
        }
    }

    private func received(_ data: Data?, id: UUID, complete: Bool, failed: Bool) async {
        guard !failed, connections[id] != nil else { close(id); return }
        if let data { connections[id]?.buffer.append(data) }
        guard let buffer = connections[id]?.buffer else { return }
        guard buffer.count <= HTTPParser.maxHeaderBytes + HTTPParser.maxBodyBytes + 4 else {
            send(.error("request_too_large", status: 413), id: id)
            return
        }
        if connections[id]?.coordination == false,
           let end = buffer.range(of: Data("\r\n".utf8)),
           let line = String(data: buffer[..<end.lowerBound], encoding: .utf8),
           let path = line.split(separator: " ").dropFirst().first,
           path.hasPrefix("/v1/coordination/") || path.hasPrefix("/v1/participants/") || path.hasPrefix("/v1/operational-status/") {
            guard connections.values.filter(\.coordination).count < 4 else {
                send(.error("coordination_busy", status: 429), id: id)
                return
            }
            connections[id]?.coordination = true
        }
        if connections[id]?.web == false,
           let end = buffer.range(of: Data("\r\n".utf8)),
           let line = String(data: buffer[..<end.lowerBound], encoding: .utf8),
           let path = line.split(separator: " ").dropFirst().first,
           Self.isWebPath(path) {
            guard connections.values.filter(\.web).count < 4 else {
                send(.error("web_ui_busy", status: 429), id: id)
                return
            }
            connections[id]?.web = true
        }
        switch HTTPParser.parse(buffer) {
        case .incomplete:
            if complete { close(id) } else { receive(id) }
        case .reject(let status): send(.error("invalid_request", status: status), id: id)
        case .request(let request):
            if Self.isWebPath(Substring(request.path)), let webHandler,
               let response = await webHandler(WitnessWebRequest(request, isLoopbackPeer: connections[id].map { Self.isLoopback($0.network.endpoint) } ?? false)) {
                send(response, id: id)
                return
            }
            let reply = await router.route(request)
            send(reply, id: id)
        }
    }

    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address): return address.isLoopback
        case .ipv6(let address):
            if address.isLoopback { return true }
            if let mapped = address.asIPv4 { return mapped.isLoopback }
            return false
        default: return false
        }
    }

    private static func isWebPath(_ path: Substring) -> Bool {
        path == "/" || path.hasPrefix("/web/") || path.hasPrefix("/api/web/")
    }

    private func send(_ reply: LeaseReply, id: UUID) {
        send(WitnessWebResponse(status: reply.status, body: reply.body), id: id)
    }

    private func send(_ reply: WitnessWebResponse, id: UUID) {
        let reasons = [200: "OK", 202: "Accepted", 410: "Gone", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                       429: "Too Many Requests", 500: "Internal Server Error", 411: "Length Required", 413: "Content Too Large", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        let type = Self.safeHeaderValue(reply.contentType) ?? "application/octet-stream"
        var bytes = Data("HTTP/1.1 \(reply.status) \(reasons[reply.status] ?? "Error")\r\nContent-Type: \(type)\r\nContent-Length: \(reply.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n".utf8)
        for (name, value) in reply.headers.sorted(by: { $0.key < $1.key }) where Self.safeHeaderName(name) && Self.safeHeaderValue(value) != nil {
            bytes.append(Data("\(name): \(value)\r\n".utf8))
        }
        bytes.append(Data("\r\n".utf8))
        bytes.append(reply.body)
        connections[id]?.network.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            guard let server = self else { return }
            Task { await server.close(id) }
        })
    }

    private static func safeHeaderName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    private static func safeHeaderValue(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 4_096,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return value
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timeout.cancel()
        connection.network.cancel()
    }
}
