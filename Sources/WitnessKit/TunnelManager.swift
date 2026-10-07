// Adapted from SwiftBot's cloudflared process, path monitoring, retry and health supervision.
import Foundation
import Darwin
import Network

public struct WitnessInternetStatus: Sendable, Equatable {
    public enum State: String, Sendable { case disabled, enabling, enabled, error }
    public var state: State
    public var publicURL: String
    public var detail: String
    public init(state: State = .disabled, publicURL: String = "", detail: String = "") {
        self.state = state; self.publicURL = publicURL; self.detail = detail
    }
}

struct TunnelRuntimeConfiguration: Sendable, Equatable {
    let hostname: String
    let publicURL: String
    let originURL: String
    let tunnelToken: String
}

/// Status callbacks and restarts from an old connector cannot revive a stopped tunnel.
actor TunnelManager {
    private var desired: TunnelRuntimeConfiguration?
    private var process: Process?
    private var processID: UUID?
    private var generation: UInt64 = 0
    private var outputBuffer = ""
    private var restartTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    private var monitor: NWPathMonitor?
    private var lastPath: String?
    private var failures = 0
    private var healthFailures = 0
    private var handler: (@MainActor @Sendable (WitnessInternetStatus) -> Void)?
    private let binaryURL: URL?
    private let retryDelay: Double
    private let monitorNetwork: Bool
    private let session: URLSession

    init(binaryURL: URL? = nil, retryDelay: Double = 2, monitorNetwork: Bool = true) {
        self.binaryURL = binaryURL
        self.retryDelay = retryDelay
        self.monitorNetwork = monitorNetwork
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 5
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: config)
    }

    func configure(_ configuration: TunnelRuntimeConfiguration?,
                   logger: @escaping @MainActor @Sendable (String) -> Void,
                   statusHandler: @escaping @MainActor @Sendable (WitnessInternetStatus) -> Void) async {
        handler = statusHandler
        if desired == configuration, process?.isRunning == true { return }
        generation &+= 1
        let ticket = generation
        desired = configuration
        failures = 0
        await stopProcess()
        guard generation == ticket else { return }
        guard let configuration else {
            stopMonitor()
            await publish(.disabled, detail: "Internet access paused")
            return
        }
        startMonitor()
        await startProcess(configuration, ticket: ticket)
    }

    func stopForAppTermination() async {
        generation &+= 1
        desired = nil
        stopMonitor()
        await stopProcess()
    }

    private func startProcess(_ configuration: TunnelRuntimeConfiguration, ticket: UInt64) async {
        guard ticket == generation, desired == configuration, process == nil else { return }
        guard !configuration.tunnelToken.isEmpty else {
            await publish(.error, detail: "The witness tunnel token is missing. Reconnect in Internet Access.")
            return
        }
        await publish(.enabling, detail: "Connecting to Cloudflare…")
        guard ticket == generation else { return }
        do {
            let binary = try binaryURL ?? Self.resolveCloudflaredBinaryURL()
            let connector = Process()
            let id = UUID()
            connector.executableURL = binary
            connector.arguments = ["tunnel", "--no-autoupdate", "run"]
            // Match SwiftBot: never pass the token in world-readable command arguments.
            var environment = ProcessInfo.processInfo.environment
            environment["TUNNEL_TOKEN"] = configuration.tunnelToken
            connector.environment = environment
            connector.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            connector.standardOutput = pipe
            connector.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { handle.readabilityHandler = nil; return }
                Task { await self?.readOutput(String(decoding: data, as: UTF8.self), id: id) }
            }
            connector.terminationHandler = { [weak self] child in
                Task { await self?.exited(id: id, status: child.terminationStatus) }
            }
            try connector.run()
            process = connector
            processID = id
            outputBuffer = ""
        } catch {
            await publish(.error, detail: "Could not start the bundled Cloudflare helper: \(error.localizedDescription)")
        }
    }

    private func readOutput(_ text: String, id: UUID) async {
        guard processID == id, desired != nil else { return }
        outputBuffer += text
        let lines = outputBuffer.components(separatedBy: "\n")
        outputBuffer = String((lines.last ?? "").suffix(8192))
        for line in lines.dropLast() {
            if line.contains("Registered tunnel connection") {
                failures = 0
                await publish(.enabled, detail: "Connected through Cloudflare Tunnel")
                guard processID == id else { return }
                startHealthCheck()
            } else if line.contains("error registering the connection") || line.contains("Register tunnel error from server side") {
                await publish(.error, detail: "Cloudflare rejected the tunnel. Reconnect in Internet Access to refresh its token.")
            }
        }
    }

    private func exited(id: UUID, status: Int32) async {
        guard processID == id, let desired else { return }
        (process?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        process = nil
        processID = nil
        healthTask?.cancel()
        healthTask = nil
        failures += 1
        guard failures < 5 else {
            await publish(.error, detail: "Cloudflare stopped after five attempts. Pause and resume Internet Access to retry.")
            return
        }
        let ticket = generation
        await publish(.enabling, detail: "Cloudflare disconnected. Reconnecting…")
        guard generation == ticket else { return }
        restartTask?.cancel()
        let delay = min(30, retryDelay * pow(2, Double(failures - 1)))
        restartTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.startProcess(desired, ticket: ticket)
        }
    }

    private func stopProcess() async {
        restartTask?.cancel(); restartTask = nil
        healthTask?.cancel(); healthTask = nil
        healthFailures = 0
        let child = process
        process = nil
        processID = nil
        outputBuffer = ""
        child?.terminationHandler = nil
        (child?.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
        guard let child, child.isRunning else { return }
        child.terminate()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1.5))
        while child.isRunning, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if child.isRunning { kill(child.processIdentifier, SIGKILL) }
    }

    private func publish(_ state: WitnessInternetStatus.State, detail: String) async {
        await handler?(WitnessInternetStatus(state: state, publicURL: desired?.publicURL ?? "", detail: detail))
    }

    private func startMonitor() {
        guard monitorNetwork, monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = "\(path.status):" + path.availableInterfaces.map { "\($0.type):\($0.name)" }.sorted().joined(separator: ",")
            let online = path.status == .satisfied
            Task { await self?.pathChanged(signature, online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "dev.ruruapp.ruru.tunnel-network"))
    }

    private func stopMonitor() { monitor?.cancel(); monitor = nil; lastPath = nil }

    private func pathChanged(_ signature: String, online: Bool) async {
        let old = lastPath
        lastPath = signature
        guard old != nil, old != signature, online, let desired else { return }
        generation &+= 1
        let ticket = generation
        failures = 0
        await stopProcess()
        await startProcess(desired, ticket: ticket)
    }

    private func startHealthCheck() {
        guard healthTask == nil else { return }
        let ticket = generation
        healthTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                await self?.checkHealth(ticket: ticket)
            }
        }
    }

    private func checkHealth(ticket: UInt64) async {
        guard ticket == generation, let desired, process?.isRunning == true,
              let base = URL(string: desired.publicURL) else { return }
        var parts = URLComponents(url: base.appendingPathComponent("health"), resolvingAgainstBaseURL: false)
        parts?.queryItems = [URLQueryItem(name: "probe", value: UUID().uuidString)]
        guard let url = parts?.url else { return }
        var request = URLRequest(url: url)
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        let ok: Bool
        do {
            let (data, response) = try await session.data(for: request)
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Recovery 503 still proves the tunnel works; a login/HTML redirect doesn't.
            ok = [200, 503].contains(status) && body?["ready"] is Bool
        } catch { ok = false }
        guard ticket == generation else { return }
        if ok { healthFailures = 0; return }
        healthFailures += 1
        guard healthFailures >= 3 else { return }
        generation &+= 1
        let next = generation
        failures = 0
        await stopProcess()
        await startProcess(desired, ticket: next)
    }

    static func resolveCloudflaredBinaryURL(bundle: Bundle = .main) throws -> URL {
        guard let url = bundle.url(forResource: "cloudflared", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { throw HelperError.missing }
        return url
    }
    enum HelperError: LocalizedError {
        case missing
        var errorDescription: String? { "The bundled cloudflared helper is missing or not executable." }
    }
}
