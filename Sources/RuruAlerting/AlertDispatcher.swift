import Foundation

/// Sends one notification to one destination. Implementations live in the app,
/// where macOS notifications and the Discord and Notify! credentials are.
public protocol AlertTransport: Sendable {
    func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome
}

/// Delivers notifications off to the side of everything else. Each destination has
/// its own bounded queue and worker, so a slow Discord webhook never delays macOS
/// notifications, and nothing here is awaited by the code that produced a signal.
public actor AlertDispatcher {
    public typealias ResultHandler = @Sendable (OutgoingNotification, DeliveryOutcome) async -> Void

    public struct Stats: Equatable, Sendable {
        public var queued = 0, dropped = 0, delivered = 0, failed = 0
    }

    private struct Job { let notification: OutgoingNotification; var attempt = 0 }

    private let transport: any AlertTransport
    private let queueLimit: Int
    private let retryDelay: Duration
    private let timeout: Duration
    private let onResult: ResultHandler
    private var queues: [AlertDestination: [Job]] = [:]
    private var workers: [AlertDestination: Task<Void, Never>] = [:]
    private var shuttingDown = false
    public private(set) var stats = Stats()

    public init(transport: any AlertTransport, queueLimit: Int = 64, retryDelay: Duration = .seconds(10),
                timeout: Duration = .seconds(25), onResult: @escaping ResultHandler) {
        self.transport = transport; self.queueLimit = queueLimit; self.retryDelay = retryDelay
        self.timeout = timeout; self.onResult = onResult
    }

    /// Queues a notification. Returns at once; the outcome arrives through `onResult`.
    public func enqueue(_ notification: OutgoingNotification, to destinations: [AlertDestination]) {
        guard !shuttingDown else { return }
        for destination in destinations {
            var queue = queues[destination] ?? []
            if queue.count >= queueLimit {
                // Keep the newest: an old backlog is least useful. The dropped one is reported.
                let dropped = queue.removeFirst()
                stats.dropped += 1
                let handler = onResult
                let outcome = DeliveryOutcome(destination: destination, ok: false, message: "Dropped: delivery queue was full")
                Task { await handler(dropped.notification, outcome) }
            }
            queue.append(Job(notification: notification))
            queues[destination] = queue
            stats.queued += 1
            if workers[destination] == nil { workers[destination] = Task { await self.work(destination) } }
        }
    }

    public func shutdown() {
        shuttingDown = true
        for worker in workers.values { worker.cancel() }
        workers = [:]; queues = [:]
    }

    private func next(_ destination: AlertDestination) -> Job? {
        guard !shuttingDown, var queue = queues[destination], !queue.isEmpty else { return nil }
        let job = queue.removeFirst()
        queues[destination] = queue
        return job
    }

    private func work(_ destination: AlertDestination) async {
        while let job = next(destination) {
            var outcome = await send(job.notification, to: destination)
            if !outcome.ok, outcome.retryable, job.attempt == 0, !shuttingDown {
                // One retry for a transient failure (rate limit, timeout, network).
                try? await Task.sleep(for: retryDelay)
                if shuttingDown { break }
                outcome = await send(job.notification, to: destination)
            }
            if outcome.ok { stats.delivered += 1 } else { stats.failed += 1 }
            stats.queued = max(0, stats.queued - 1)
            await onResult(job.notification, outcome)
        }
        workers[destination] = nil
    }

    private func send(_ notification: OutgoingNotification, to destination: AlertDestination) async -> DeliveryOutcome {
        let transport = transport, timeout = timeout
        return await withTaskGroup(of: DeliveryOutcome?.self) { group in
            group.addTask { await transport.send(notification, to: destination) }
            group.addTask { try? await Task.sleep(for: timeout); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? DeliveryOutcome(destination: destination, ok: false,
                                            message: "Timed out waiting for \(destination.title)", retryable: true)
        }
    }
}
