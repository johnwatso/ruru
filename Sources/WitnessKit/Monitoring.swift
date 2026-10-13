import Foundation
import Network

/// A reachability target Ruru checks on a schedule. Monitoring is observation
/// only: results feed the UI and alerts and never touch leases or ownership.
public struct MonitorTarget: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case tcp = "TCP", http = "HTTP" }

    public static let maxTargets = 32
    public static let intervalRange = 30...3600
    public static let timeoutRange = 1...30
    public static let thresholdRange = 1...10
    public static let defaultInterval = 60
    public static let defaultTimeout = 10
    public static let defaultThreshold = 3

    public var id: String
    public var name: String
    public var kind: Kind
    /// TCP: host name or IP address. Unused for HTTP.
    public var host: String
    /// TCP: port. Unused for HTTP.
    public var port: Int
    /// HTTP: absolute http(s) URL. Unused for TCP.
    public var url: String
    public var intervalSeconds: Int
    public var timeoutSeconds: Int
    /// Consecutive failures before the target is reported down.
    public var failureThreshold: Int
    public var enabled: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String, kind: Kind, host: String = "", port: Int = 0,
                url: String = "", intervalSeconds: Int = MonitorTarget.defaultInterval,
                timeoutSeconds: Int = MonitorTarget.defaultTimeout,
                failureThreshold: Int = MonitorTarget.defaultThreshold, enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port; self.url = url
        self.intervalSeconds = intervalSeconds; self.timeoutSeconds = timeoutSeconds
        self.failureThreshold = failureThreshold; self.enabled = enabled
    }

    /// What the target points at, for display.
    public var address: String {
        switch kind {
        case .tcp: host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .http: url
        }
    }

    public var isValid: Bool {
        guard UUID(uuidString: id) != nil,
              WitnessNodeName.normalized(name) == name, name.utf8.count <= 128,
              Self.intervalRange.contains(intervalSeconds), Self.timeoutRange.contains(timeoutSeconds),
              timeoutSeconds < intervalSeconds, Self.thresholdRange.contains(failureThreshold) else { return false }
        switch kind {
        case .tcp: return Self.validHost(host) && (1...65535).contains(port)
        case .http: return Self.validURL(url) != nil
        }
    }

    /// Host names and IP literals only: no whitespace, paths, credentials or ports.
    public static func validHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= 253 else { return false }
        return host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:_".contains($0)) }
    }

    public static func validURL(_ text: String) -> URL? {
        guard text.utf8.count <= 2048, let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

public struct MonitorResult: Equatable, Sendable {
    public let time: Date
    public let ok: Bool
    public let latencyMilliseconds: Int?
    /// Short, secret-free explanation such as "HTTP 503" or "Connection refused".
    public let detail: String

    public init(time: Date = Date(), ok: Bool, latencyMilliseconds: Int? = nil, detail: String) {
        self.time = time; self.ok = ok; self.latencyMilliseconds = latencyMilliseconds; self.detail = detail
    }
}

public enum MonitorStatus: String, Sendable { case unknown, up, down }

public struct MonitorChange: Equatable, Sendable {
    public let time: Date
    public let status: MonitorStatus
    public let detail: String
}

/// Per-target state machine. A target goes down only after `failureThreshold`
/// consecutive failures and recovers on the first success, so one dropped packet
/// does not alert. The first result never produces a change on its own unless it
/// is already a confirmed failure.
public struct MonitorState: Equatable, Sendable {
    public static let historyLimit = 120
    public static let changeLimit = 20

    public private(set) var status: MonitorStatus = .unknown
    public private(set) var consecutiveFailures = 0
    public private(set) var history: [MonitorResult] = []
    public private(set) var changes: [MonitorChange] = []
    public var last: MonitorResult? { history.last }

    public init() {}

    /// Records a result and returns a status change when one occurred.
    @discardableResult
    public mutating func record(_ result: MonitorResult, failureThreshold: Int) -> MonitorChange? {
        history.append(result)
        if history.count > Self.historyLimit { history.removeFirst(history.count - Self.historyLimit) }
        consecutiveFailures = result.ok ? 0 : consecutiveFailures + 1

        let next: MonitorStatus
        if result.ok { next = .up }
        else if consecutiveFailures >= failureThreshold { next = .down }
        else { next = status }
        guard next != status else { return nil }
        let wasKnown = status != .unknown
        status = next
        let change = MonitorChange(time: result.time, status: next, detail: result.detail)
        changes.append(change)
        if changes.count > Self.changeLimit { changes.removeFirst(changes.count - Self.changeLimit) }
        // Unknown → up is the first observation, not news.
        return wasKnown || next == .down ? change : nil
    }

    /// Share of recorded checks that succeeded, 0...1, or nil with no history.
    public var uptime: Double? {
        guard !history.isEmpty else { return nil }
        return Double(history.filter(\.ok).count) / Double(history.count)
    }
}

public enum MonitorProbe {
    public static func run(_ target: MonitorTarget) async -> MonitorResult {
        switch target.kind {
        case .tcp: await tcp(host: target.host, port: target.port, timeout: target.timeoutSeconds)
        case .http: await http(url: target.url, timeout: target.timeoutSeconds)
        }
    }

    // MARK: TCP

    static func tcp(host: String, port: Int, timeout: Int) async -> MonitorResult {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return MonitorResult(ok: false, detail: "Invalid port")
        }
        let started = ContinuousClock.now
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        let outcome: (ok: Bool, detail: String) = await withCheckedContinuation { continuation in
            let gate = OneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish((true, "Connected"))
                case .failed(let error): gate.finish((false, describe(error)))
                case .waiting(let error): gate.finish((false, describe(error)))
                case .cancelled: gate.finish((false, "Cancelled"))
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeout)) {
                gate.finish((false, "Timed out after \(timeout) s"))
            }
        }
        connection.cancel()
        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return MonitorResult(ok: outcome.ok, latencyMilliseconds: outcome.ok ? milliseconds : nil, detail: outcome.detail)
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: "Connection refused"
            case .ETIMEDOUT: "Timed out"
            case .EHOSTUNREACH, .ENETUNREACH: "Host unreachable"
            default: "Connection failed"
            }
        case .dns: "Name could not be resolved"
        default: "Connection failed"
        }
    }

    // MARK: HTTP

    static func http(url text: String, timeout: Int) async -> MonitorResult {
        guard let url = MonitorTarget.validURL(text) else { return MonitorResult(ok: false, detail: "Invalid URL") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = TimeInterval(timeout)
        configuration.timeoutIntervalForResource = TimeInterval(timeout)
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue("Ruru-Monitor", forHTTPHeaderField: "User-Agent")
        let started = ContinuousClock.now
        do {
            // Only headers matter: cancel as soon as the response arrives.
            let (bytes, response) = try await session.bytes(for: request)
            bytes.task.cancel()
            guard let http = response as? HTTPURLResponse else { return MonitorResult(ok: false, detail: "Not an HTTP response") }
            let elapsed = started.duration(to: .now)
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            // A redirect proves the server is answering; it is not followed.
            let ok = (200..<400).contains(http.statusCode)
            return MonitorResult(ok: ok, latencyMilliseconds: ok ? milliseconds : nil, detail: "HTTP \(http.statusCode)")
        } catch let error as URLError {
            return MonitorResult(ok: false, detail: describe(error))
        } catch {
            return MonitorResult(ok: false, detail: "Request failed")
        }
    }

    private static func describe(_ error: URLError) -> String {
        switch error.code {
        case .timedOut: "Timed out"
        case .cannotFindHost, .dnsLookupFailed: "Name could not be resolved"
        case .cannotConnectToHost: "Connection refused"
        case .networkConnectionLost, .notConnectedToInternet: "Network unavailable"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid: "TLS certificate problem"
        default: "Request failed"
        }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// Resumes a continuation exactly once from whichever callback fires first.
    private final class OneShot: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<(ok: Bool, detail: String), Never>?
        init(_ continuation: CheckedContinuation<(ok: Bool, detail: String), Never>) { self.continuation = continuation }
        func finish(_ value: (ok: Bool, detail: String)) {
            lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
            pending?.resume(returning: value)
        }
    }
}

/// A change in a target's confirmed status, drained by the app for alerts.
public struct MonitorTransition: Equatable, Sendable {
    public let targetID: String
    public let name: String
    public let address: String
    public let change: MonitorChange
}

/// Runs one bounded task per enabled target. At most `MonitorTarget.maxTargets`
/// probes are ever in flight, each with its own timeout.
public actor MonitorEngine {
    public typealias Prober = @Sendable (MonitorTarget) async -> MonitorResult

    private let prober: Prober
    private var targets: [String: MonitorTarget] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var states: [String: MonitorState] = [:]
    private var pending: [MonitorTransition] = []

    public init(prober: @escaping Prober = { await MonitorProbe.run($0) }) { self.prober = prober }

    /// Applies the saved target list: new or changed targets restart, removed ones stop and lose history.
    public func configure(_ list: [MonitorTarget]) {
        let wanted = Dictionary(uniqueKeysWithValues: list.filter(\.isValid).prefix(MonitorTarget.maxTargets).map { ($0.id, $0) })
        for (id, task) in tasks where wanted[id] == nil || wanted[id] != targets[id] || wanted[id]?.enabled == false {
            task.cancel(); tasks[id] = nil
        }
        for id in states.keys where wanted[id] == nil { states[id] = nil }
        targets = wanted
        for (id, target) in wanted where target.enabled && tasks[id] == nil {
            if states[id] == nil { states[id] = MonitorState() }
            tasks[id] = Task { [weak self] in await self?.loop(target) }
        }
    }

    public func stop() {
        for task in tasks.values { task.cancel() }
        tasks = [:]
    }

    public func snapshot() -> [String: MonitorState] { states }

    /// Transitions since the last call, oldest first.
    public func drainTransitions() -> [MonitorTransition] {
        defer { pending = [] }
        return pending
    }

    /// Checks one target now, outside its schedule.
    public func checkNow(_ id: String) async {
        guard let target = targets[id] else { return }
        let result = await prober(target)
        record(result, for: target)
    }

    private func loop(_ target: MonitorTarget) async {
        while !Task.isCancelled {
            let result = await prober(target)
            if Task.isCancelled { return }
            record(result, for: target)
            do { try await Task.sleep(for: .seconds(target.intervalSeconds)) } catch { return }
        }
    }

    private func record(_ result: MonitorResult, for target: MonitorTarget) {
        // The target may have been edited or removed while the probe ran.
        guard targets[target.id] == target else { return }
        var state = states[target.id] ?? MonitorState()
        if let change = state.record(result, failureThreshold: target.failureThreshold) {
            pending.append(MonitorTransition(targetID: target.id, name: target.name, address: target.address, change: change))
            if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        }
        states[target.id] = state
    }
}
