import Foundation
import Network

/// A reachability target Ruru checks on a schedule. Monitoring is observation
/// only: results feed the UI and alerts and never touch leases or ownership.
public struct MonitorTarget: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case tcp = "TCP", http = "HTTP", dns = "DNS" }

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
    /// DNS: the A-record name queried directly from the configured resolver.
    /// Unused for TCP and HTTP.
    public var dnsQueryName: String
    public var intervalSeconds: Int
    public var timeoutSeconds: Int
    /// Consecutive failures before the target is reported down.
    public var failureThreshold: Int
    public var enabled: Bool
    /// Whether this target being down counts as something needing attention on
    /// Overview. Off by default; the check and its alerts are unaffected.
    public var needsAttention: Bool

    public init(id: String = UUID().uuidString.lowercased(), name: String, kind: Kind, host: String = "", port: Int = 0,
                url: String = "", dnsQueryName: String = "example.com", intervalSeconds: Int = MonitorTarget.defaultInterval,
                timeoutSeconds: Int = MonitorTarget.defaultTimeout,
                failureThreshold: Int = MonitorTarget.defaultThreshold, enabled: Bool = true,
                needsAttention: Bool = false) {
        self.needsAttention = needsAttention
        self.id = id; self.name = name; self.kind = kind; self.host = host; self.port = port; self.url = url
        self.dnsQueryName = dnsQueryName
        self.intervalSeconds = intervalSeconds; self.timeoutSeconds = timeoutSeconds
        self.failureThreshold = failureThreshold; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, host, port, url, dnsQueryName, intervalSeconds, timeoutSeconds, failureThreshold, enabled, needsAttention
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        kind = try values.decode(Kind.self, forKey: .kind)
        host = try values.decode(String.self, forKey: .host)
        port = try values.decode(Int.self, forKey: .port)
        url = try values.decode(String.self, forKey: .url)
        dnsQueryName = try values.decodeIfPresent(String.self, forKey: .dnsQueryName) ?? "example.com"
        intervalSeconds = try values.decode(Int.self, forKey: .intervalSeconds)
        timeoutSeconds = try values.decode(Int.self, forKey: .timeoutSeconds)
        failureThreshold = try values.decode(Int.self, forKey: .failureThreshold)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        needsAttention = try values.decodeIfPresent(Bool.self, forKey: .needsAttention) ?? false
    }

    /// What the target points at, for display.
    public var address: String {
        switch kind {
        case .tcp: host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
        case .http: url
        case .dns: "\(host.contains(":") ? "[\(host)]" : host):\(port) · \(dnsQueryName)"
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
        case .dns: return Self.validHost(host) && (1...65535).contains(port) && Self.validDNSQueryName(dnsQueryName) != nil
        }
    }

    /// Targets the browser console may create. LAN and internet hosts are fine;
    /// this Mac itself, link-local and unspecified addresses (including cloud
    /// metadata endpoints) are not, so a web operator cannot probe local services.
    public var isWebPermitted: Bool {
        guard isValid else { return false }
        let hostText: String
        switch kind {
        case .http: hostText = Self.validURL(url)?.host ?? ""
        case .tcp, .dns: hostText = host
        }
        return !Self.isRestrictedHost(hostText)
    }

    static func isRestrictedHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if name.isEmpty || name == "localhost" || name.hasSuffix(".localhost") { return true }
        if name.contains(":") {
            return name == "::" || name == "::1" || name.hasPrefix("fe80") || name.hasPrefix("::ffff:")
                || name.hasPrefix("ff")
        }
        let octets = name.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        if octets.count == 4, octets.allSatisfy({ $0 != nil && (0...255).contains($0!) }) {
            let a = octets[0]!, b = octets[1]!
            return a == 0 || a == 127 || a >= 224 || (a == 169 && b == 254)
        }
        // Single-label decimal/hex forms such as 2130706433 or 0x7f000001.
        if Int(name) != nil || name.hasPrefix("0x") { return true }
        return false
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

    /// A conventional DNS name. Monitoring sends an A lookup only, so service
    /// labels and arbitrary record syntax are deliberately not accepted here.
    public static func validDNSQueryName(_ text: String) -> String? {
        let name = text.hasSuffix(".") ? String(text.dropLast()) : text
        guard !name.isEmpty, name.utf8.count <= 253, !name.contains("..") else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }) else { return nil }
        return name
    }
}

public struct MonitorResult: Equatable, Sendable {
    public let time: Date
    public let ok: Bool
    public let latencyMilliseconds: Int?
    /// Short, secret-free explanation such as "HTTP 503" or "Connection refused".
    public let detail: String
    /// The check could not establish whether the target is up, for example because
    /// this Mac had no network or the check ran late after sleep. It is neither a
    /// success nor a confirmed failure and never counts toward a failure threshold.
    public let inconclusive: Bool

    public init(time: Date = Date(), ok: Bool, latencyMilliseconds: Int? = nil, detail: String, inconclusive: Bool = false) {
        self.time = time; self.ok = ok && !inconclusive; self.latencyMilliseconds = latencyMilliseconds
        self.detail = detail; self.inconclusive = inconclusive
    }

    /// A confirmed failure: the check ran with working local conditions and failed.
    public var isFailure: Bool { !ok && !inconclusive }
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
        // An inconclusive check is kept for display but neither confirms nor
        // clears a failure, so a local outage cannot look like a remote one.
        if result.inconclusive { return nil }
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

    /// Share of conclusive recorded checks that succeeded, 0...1, or nil with none.
    public var uptime: Double? {
        let conclusive = history.filter { !$0.inconclusive }
        guard !conclusive.isEmpty else { return nil }
        return Double(conclusive.filter(\.ok).count) / Double(conclusive.count)
    }
}

public enum MonitorProbe {
    public static func run(_ target: MonitorTarget) async -> MonitorResult {
        switch target.kind {
        case .tcp: await tcp(host: target.host, port: target.port, timeout: target.timeoutSeconds)
        case .http: await http(url: target.url, timeout: target.timeoutSeconds)
        case .dns: await dns(host: target.host, port: target.port, queryName: target.dnsQueryName, timeout: target.timeoutSeconds)
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

    // MARK: DNS

    /// Sends one recursive UDP A lookup straight to the configured resolver.
    /// A TCP port check alone cannot tell whether a DNS service can answer.
    static func dns(host: String, port: Int, queryName: String, timeout: Int) async -> MonitorResult {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: port)),
              let normalizedName = MonitorTarget.validDNSQueryName(queryName) else {
            return MonitorResult(ok: false, detail: "Invalid DNS target")
        }
        let identifier = UInt16.random(in: .min ... .max)
        let query = dnsQuery(identifier: identifier, name: normalizedName)
        let started = ContinuousClock.now
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .udp)
        let outcome: (ok: Bool, detail: String) = await withCheckedContinuation { continuation in
            let gate = OneShot(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: query, completion: .contentProcessed { error in
                        guard error == nil else { gate.finish((false, "DNS request failed")); return }
                        connection.receiveMessage { data, _, _, error in
                            guard error == nil, let data else { gate.finish((false, "DNS request failed")); return }
                            gate.finish(dnsResponse(data, matching: identifier))
                        }
                    })
                case .failed, .waiting:
                    gate.finish((false, "DNS server could not be reached"))
                case .cancelled:
                    gate.finish((false, "DNS request cancelled"))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeout)) {
                gate.finish((false, "DNS request timed out after \(timeout) s"))
            }
        }
        connection.cancel()
        let elapsed = started.duration(to: .now)
        let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
        return MonitorResult(ok: outcome.ok, latencyMilliseconds: outcome.ok ? milliseconds : nil, detail: outcome.detail)
    }

    private static func dnsQuery(identifier: UInt16, name: String) -> Data {
        var bytes: [UInt8] = [
            UInt8(identifier >> 8), UInt8(identifier & 0xFF),
            0x01, 0x00, // standard recursive query
            0x00, 0x01, // one question
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(0)
        bytes.append(contentsOf: [0x00, 0x01, 0x00, 0x01]) // A, IN
        return Data(bytes)
    }

    private static func dnsResponse(_ data: Data, matching identifier: UInt16) -> (ok: Bool, detail: String) {
        guard data.count >= 12,
              UInt16(data[0]) << 8 | UInt16(data[1]) == identifier,
              data[2] & 0x80 != 0 else {
            return (false, "Invalid DNS response")
        }
        switch data[3] & 0x0F {
        case 0: return (true, "DNS response")
        case 1: return (false, "DNS format error")
        case 2: return (false, "DNS server failure")
        case 3: return (false, "DNS name not found")
        case 5: return (false, "DNS query refused")
        default: return (false, "DNS response error")
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
            // Missing local connectivity says nothing about the target itself.
            let local: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff]
            return MonitorResult(ok: false, detail: describe(error), inconclusive: local.contains(error.code))
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

/// One finished check with the target's resulting confirmed status. Alerts and
/// history consume these; they never influence leases or ownership.
public struct MonitorObservation: Equatable, Sendable {
    public let targetID: String
    public let name: String
    public let address: String
    public let kind: MonitorTarget.Kind
    public let result: MonitorResult
    /// Confirmed status after this check; unchanged by inconclusive checks.
    public let status: MonitorStatus
    public let consecutiveFailures: Int
    public let failureThreshold: Int
    public let intervalSeconds: Int
    public let timeoutSeconds: Int
    public let change: MonitorChange?
}

/// Whether this Mac currently has a network path. Failures observed without one
/// are inconclusive. Only a coarse yes/no is kept; nothing is probed.
public final class NetworkPathGate: @unchecked Sendable {
    public static let shared = NetworkPathGate()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.lock(); self.satisfied = path.status == .satisfied; self.lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "dev.ruruapp.ruru.network-path", qos: .utility))
    }

    public var isAvailable: Bool { lock.lock(); defer { lock.unlock() }; return satisfied }
}

/// Runs one bounded task per enabled target. At most `MonitorTarget.maxTargets`
/// probes are ever in flight, each with its own timeout.
public actor MonitorEngine {
    public typealias Prober = @Sendable (MonitorTarget) async -> MonitorResult

    /// A check that starts this much later than scheduled suggests the Mac slept
    /// or stalled; its failure is not trusted.
    static let lateCheckSlack: Duration = .seconds(15)
    static let observationLimit = 256

    private let prober: Prober
    private let networkAvailable: @Sendable () -> Bool
    private var observations: [MonitorObservation] = []
    private var targets: [String: MonitorTarget] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var states: [String: MonitorState] = [:]
    private var pending: [MonitorTransition] = []

    public init(prober: @escaping Prober = { await MonitorProbe.run($0) },
                networkAvailable: @escaping @Sendable () -> Bool = { true }) {
        self.prober = prober
        self.networkAvailable = networkAvailable
    }

    /// Decides whether a failed check can be trusted. Pure, for testing.
    static func classify(_ result: MonitorResult, networkAvailable: Bool, late: Bool) -> MonitorResult {
        guard result.isFailure else { return result }
        if !networkAvailable {
            return MonitorResult(time: result.time, ok: false, detail: "This Mac has no network connection", inconclusive: true)
        }
        if late {
            return MonitorResult(time: result.time, ok: false, detail: "Check ran late (Mac was asleep or busy)", inconclusive: true)
        }
        return result
    }

    /// `lateness` is how long after its scheduled start a check actually began.
    static func isLate(lateness: Duration) -> Bool { lateness > lateCheckSlack }

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

    /// Every finished check since the last call, oldest first. Bounded: a stalled
    /// consumer loses the oldest observations rather than growing without limit.
    public func drainObservations() -> [MonitorObservation] {
        defer { observations = [] }
        return observations
    }

    /// Transitions since the last call, oldest first.
    public func drainTransitions() -> [MonitorTransition] {
        defer { pending = [] }
        return pending
    }

    /// Checks one target now, outside its schedule.
    public func checkNow(_ id: String) async {
        guard let target = targets[id] else { return }
        let result = Self.classify(await prober(target), networkAvailable: networkAvailable(), late: false)
        record(result, for: target)
    }

    private func loop(_ target: MonitorTarget) async {
        var scheduled = ContinuousClock.now
        while !Task.isCancelled {
            let late = Self.isLate(lateness: ContinuousClock.now - scheduled)
            let raw = await prober(target)
            if Task.isCancelled { return }
            let result = Self.classify(raw, networkAvailable: networkAvailable(), late: late)
            record(result, for: target)
            // Re-check soon after an inconclusive result instead of waiting a full
            // interval, so a brief local interruption resolves quickly.
            let wait = result.inconclusive ? min(target.intervalSeconds, 10) : target.intervalSeconds
            scheduled = ContinuousClock.now + .seconds(wait)
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        }
    }

    private func record(_ result: MonitorResult, for target: MonitorTarget) {
        // The target may have been edited or removed while the probe ran.
        guard targets[target.id] == target else { return }
        var state = states[target.id] ?? MonitorState()
        let change = state.record(result, failureThreshold: target.failureThreshold)
        if let change {
            pending.append(MonitorTransition(targetID: target.id, name: target.name, address: target.address, change: change))
            if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        }
        observations.append(MonitorObservation(
            targetID: target.id, name: target.name, address: target.address, kind: target.kind, result: result,
            status: state.status, consecutiveFailures: state.consecutiveFailures,
            failureThreshold: target.failureThreshold, intervalSeconds: target.intervalSeconds,
            timeoutSeconds: target.timeoutSeconds, change: change))
        if observations.count > Self.observationLimit { observations.removeFirst(observations.count - Self.observationLimit) }
        states[target.id] = state
    }
}
