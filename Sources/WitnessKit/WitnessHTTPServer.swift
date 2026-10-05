import Foundation
import Network

/// A small HTTP/1 listener for a dedicated HTTPS tunnel or reverse proxy.
/// Connections, request size, and read duration are bounded for older Macs.
public actor WitnessHTTPServer {
    private var router: WitnessRouter
    private let queue = DispatchQueue(label: "com.swiftmesh.witness.http", qos: .utility)
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
    }

    public init(store: LeaseStore, clusterID: String, token: String) throws {
        router = try WitnessRouter(store: store, clusterID: clusterID, token: token)
    }

    public init(store: LeaseStore, services: [WitnessServiceCredential]) throws {
        router = try WitnessRouter(store: store, services: services)
    }

    /// Changes admission only; the database, lease deadlines and listener stay alive.
    public func configureServices(_ services: [WitnessServiceCredential]) throws {
        router = try WitnessRouter(store: router.store, services: services)
    }

    public func start(bindAddress: String = "127.0.0.1", port: UInt16 = 38990) async throws -> UInt16 {
        guard listener == nil, ["127.0.0.1", "0.0.0.0", "::1"].contains(bindAddress),
              let endpointPort = NWEndpoint.Port(rawValue: port) else { throw WitnessError.invalidConfiguration }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindAddress), port: endpointPort)
        parameters.allowLocalEndpointReuse = false
        let networkListener = try NWListener(using: parameters)
        let generation = UUID()
        listenerID = generation
        failureMessage = nil
        listener = networkListener
        networkListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection, generation: generation) }
        }
        networkListener.stateUpdateHandler = { [weak self] state in
            Task { await self?.listenerChanged(state, generation: generation) }
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
            if case .failed = state { Task { await self?.close(id) } }
            if case .cancelled = state { Task { await self?.close(id) } }
        }
        network.start(queue: queue)
        receive(id)
    }

    private func receive(_ id: UUID) {
        connections[id]?.network.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { [weak self] data, _, complete, error in
            Task { await self?.received(data, id: id, complete: complete, failed: error != nil) }
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
        switch HTTPParser.parse(buffer) {
        case .incomplete:
            if complete { close(id) } else { receive(id) }
        case .reject(let status): send(.error("invalid_request", status: status), id: id)
        case .request(let request):
            let reply = await router.route(request)
            send(reply, id: id)
        }
    }

    private func send(_ reply: LeaseReply, id: UUID) {
        let reasons = [200: "OK", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict",
                       411: "Length Required", 413: "Content Too Large", 431: "Request Header Fields Too Large", 503: "Service Unavailable"]
        var bytes = Data("HTTP/1.1 \(reply.status) \(reasons[reply.status] ?? "Error")\r\nContent-Type: application/json\r\nContent-Length: \(reply.body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        bytes.append(reply.body)
        connections[id]?.network.send(content: bytes, completion: .contentProcessed { [weak self] _ in
            Task { await self?.close(id) }
        })
    }

    private func close(_ id: UUID) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.timeout.cancel()
        connection.network.cancel()
    }
}
