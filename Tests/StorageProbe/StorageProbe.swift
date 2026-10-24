import Foundation
import WitnessKit

/// Built only for Xcode tests. All paths are supplied by the isolated test;
/// this helper never uses app settings, production storage, or Keychain.
@main
struct StorageProbe {
    static func main() async throws {
        if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--memory-soak",
           let iterations = Int(CommandLine.arguments[3]), (1...100_000).contains(iterations) {
            try await memorySoak(reportURL: URL(fileURLWithPath: CommandLine.arguments[2]), iterations: iterations)
            return
        }
        guard CommandLine.arguments.count == 3 else { throw CocoaError(.fileReadInvalidFileName) }
        let databaseURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let replyURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let store = try LeaseStore(databaseURL: databaseURL)
        let reply = await store.apply(.acquire, request: LeaseRequest(clusterID: "bot", nodeID: "primary", term: 12, nodeName: "Primary Mac"))
        guard reply.status == 200 else { throw CocoaError(.fileWriteUnknown) }
        try reply.body.write(to: replyURL, options: .atomic)
        // The test SIGKILLs us here, before normal connection shutdown/checkpoint.
        try await Task.sleep(for: .seconds(30))
        _ = try await store.snapshot()
    }

    private struct MemorySample: Codable {
        let iteration: Int
        let resources: RuruDiagnostics.Resources
    }

    private final class SoakClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds: Double = 0
        func now() -> Double { lock.withLock { seconds } }
        func advance() { lock.withLock { seconds += 1 } }
    }

    /// An accelerated storage-only workload, deliberately separate from the GUI,
    /// networking and production authority. The report survives a failed run.
    private static func memorySoak(reportURL: URL, iterations: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RuruMemorySoak-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        // Advance simulated monotonic time so each renewal writes a new expiry,
        // rather than benchmarking no-op updates to the same deadline.
        let clock = SoakClock()
        let store = try LeaseStore(databaseURL: directory.appendingPathComponent("leases.duckdb"), clock: { clock.now() })
        var term: Int64 = 0
        for _ in 0..<24 {
            let acquired = await store.apply(.acquire, request: .init(clusterID: "bot", nodeID: "primary", term: term, nodeName: "Primary Mac"))
            guard acquired.status == 200 else { throw CocoaError(.fileWriteUnknown) }
            term = try JSONDecoder().decode(LeaseGrant.self, from: acquired.body).term
            let released = await store.apply(.release, request: .init(clusterID: "bot", nodeID: "primary", term: term))
            guard released.status == 200 else { throw CocoaError(.fileWriteUnknown) }
        }
        let acquired = await store.apply(.acquire, request: .init(clusterID: "bot", nodeID: "primary", term: term))
        guard acquired.status == 200 else { throw CocoaError(.fileWriteUnknown) }
        term = try JSONDecoder().decode(LeaseGrant.self, from: acquired.body).term
        var samples: [MemorySample] = []
        for iteration in 0...iterations {
            if iteration > 0 {
                clock.advance()
                // Match the console's once-per-second snapshot and five-second renewal ratio.
                if iteration.isMultiple(of: 5) {
                    let reply = await store.apply(.renew, request: .init(clusterID: "bot", nodeID: "primary", term: term, nodeName: "Primary Mac"))
                    guard reply.status == 200 else { throw CocoaError(.fileWriteUnknown) }
                }
                let snapshot = try await store.snapshot()
                guard snapshot.leases.first?.term == term,
                      snapshot.leases.first?.remainingSeconds == 30 - Double(iteration % 5),
                      snapshot.events.count == 49 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if iteration.isMultiple(of: 1_000) || iteration == iterations {
                samples.append(MemorySample(iteration: iteration, resources: .capture()))
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(samples).write(to: reportURL, options: .atomic)
            }
        }
    }
}
