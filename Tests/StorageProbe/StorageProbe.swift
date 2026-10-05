import Foundation
import WitnessKit

/// Built only for Xcode tests. All paths are supplied by the isolated test;
/// this helper never uses app settings, production storage, or Keychain.
@main
struct StorageProbe {
    static func main() async throws {
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
}
