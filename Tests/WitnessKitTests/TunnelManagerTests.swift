import Foundation
import XCTest
@testable import WitnessKit

final class TunnelManagerTests: XCTestCase {
    private func helper(_ script: String) throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WitnessHelperTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("helper")
        try ("#!/usr/bin/python3\nimport os,sys,time,json\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return (url, directory)
    }

    private var configuration: TunnelRuntimeConfiguration {
        TunnelRuntimeConfiguration(hostname: "witness.example.com", publicURL: "https://witness.example.com",
                                   originURL: "", tunnelToken: "test-connector-secret")
    }

    @MainActor
    func testFragmentedRegistrationAndEnvironmentOnlyToken() async throws {
        let (url, directory) = try helper("""
with open(os.path.join(os.path.dirname(__file__), 'invocation.json'), 'w') as f:
    json.dump({'argv':sys.argv[1:], 'has_token':bool(os.environ.get('TUNNEL_TOKEN'))}, f)
sys.stdout.write('Registered tunnel '); sys.stdout.flush()
time.sleep(0.05)
sys.stdout.write('connection\\n'); sys.stdout.flush()
time.sleep(10)
""")
        let manager = TunnelManager(binaryURL: url, monitorNetwork: false)
        let connected = expectation(description: "Registered fragmented log")
        await manager.configure(configuration, logger: { _ in }) { status in
            if status.state == .enabled { connected.fulfill() }
        }
        await fulfillment(of: [connected], timeout: 5)
        await manager.stopForAppTermination()
        let invocation = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("invocation.json"))) as! [String: Any]
        XCTAssertEqual(invocation["argv"] as? [String], ["tunnel", "--no-autoupdate", "run"])
        XCTAssertEqual(invocation["has_token"] as? Bool, true)
        XCTAssertFalse(String(describing: invocation).contains("test-connector-secret"))
    }

    @MainActor
    func testStopCancelsScheduledRestart() async throws {
        let (url, directory) = try helper("""
with open(os.path.join(os.path.dirname(__file__), 'attempts'), 'a') as f: f.write('start\\n')
sys.exit(1)
""")
        let manager = TunnelManager(binaryURL: url, retryDelay: 0.5, monitorNetwork: false)
        let retry = expectation(description: "Retry scheduled")
        await manager.configure(configuration, logger: { _ in }) { status in
            if status.detail.contains("Reconnecting") { retry.fulfill() }
        }
        await fulfillment(of: [retry], timeout: 5)
        await manager.stopForAppTermination()
        try await Task.sleep(for: .seconds(0.7))
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8), "start\n")
    }

    @MainActor
    func testRepeatedFailureStopsAfterFiveAttempts() async throws {
        let (url, directory) = try helper("""
with open(os.path.join(os.path.dirname(__file__), 'attempts'), 'a') as f: f.write('start\\n')
sys.exit(1)
""")
        let manager = TunnelManager(binaryURL: url, retryDelay: 0.01, monitorNetwork: false)
        let stopped = expectation(description: "Retry budget exhausted")
        await manager.configure(configuration, logger: { _ in }) { status in
            if status.state == .error && status.detail.contains("five attempts") { stopped.fulfill() }
        }
        await fulfillment(of: [stopped], timeout: 5)
        await manager.stopForAppTermination()
        let attempts = try String(contentsOf: directory.appendingPathComponent("attempts"), encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(attempts.count, 5)
    }
}
