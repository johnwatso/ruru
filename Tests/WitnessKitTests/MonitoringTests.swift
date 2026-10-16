import Network
import XCTest
@testable import WitnessKit

final class MonitoringTests: XCTestCase {
    private func result(_ ok: Bool, _ at: TimeInterval = 0) -> MonitorResult {
        MonitorResult(time: Date(timeIntervalSince1970: at), ok: ok, latencyMilliseconds: ok ? 5 : nil, detail: ok ? "OK" : "Down")
    }

    func testTargetValidation() {
        XCTAssertTrue(MonitorTarget(name: "NAS", kind: .tcp, host: "192.168.1.20", port: 445).isValid)
        XCTAssertTrue(MonitorTarget(name: "Site", kind: .http, url: "https://example.com/health").isValid)
        XCTAssertTrue(MonitorTarget(name: "Cloudflare DNS", kind: .dns, host: "1.1.1.1", port: 53).isValid)
        XCTAssertFalse(MonitorTarget(name: "", kind: .tcp, host: "nas.local", port: 22).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .tcp, host: "nas local", port: 22).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .tcp, host: "nas/etc", port: 22).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .tcp, host: "nas", port: 0).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .http, url: "ftp://example.com").isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .http, url: "https://user:pw@example.com").isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad DNS", kind: .dns, host: "1.1.1.1", port: 53, dnsQueryName: "bad name").isValid)
        XCTAssertFalse(MonitorTarget(name: "Fast", kind: .tcp, host: "nas", port: 22, intervalSeconds: 5).isValid)
        XCTAssertFalse(MonitorTarget(name: "Slow probe", kind: .tcp, host: "nas", port: 22, intervalSeconds: 30, timeoutSeconds: 30).isValid)
        XCTAssertFalse(MonitorTarget(id: "not-a-uuid", name: "Id", kind: .tcp, host: "nas", port: 22).isValid)
    }

    func testFirstSuccessIsNotNewsAndFailuresNeedThreshold() {
        var state = MonitorState()
        XCTAssertNil(state.record(result(true), failureThreshold: 3))
        XCTAssertEqual(state.status, .up)
        XCTAssertNil(state.record(result(false), failureThreshold: 3))
        XCTAssertNil(state.record(result(false), failureThreshold: 3))
        XCTAssertEqual(state.status, .up)
        XCTAssertEqual(state.record(result(false), failureThreshold: 3)?.status, .down)
        XCTAssertNil(state.record(result(false), failureThreshold: 3), "Staying down is not a new change")
        XCTAssertEqual(state.record(result(true), failureThreshold: 3)?.status, .up)
        XCTAssertEqual(state.changes.map(\.status), [.up, .down, .up])
    }

    func testOneBlipDoesNotAlertAndFirstConfirmedFailureDoes() {
        var blip = MonitorState()
        blip.record(result(true), failureThreshold: 2)
        blip.record(result(false), failureThreshold: 2)
        XCTAssertNil(blip.record(result(true), failureThreshold: 2))
        XCTAssertEqual(blip.status, .up)

        var cold = MonitorState()
        XCTAssertNil(cold.record(result(false), failureThreshold: 2))
        XCTAssertEqual(cold.record(result(false), failureThreshold: 2)?.status, .down)
    }

    func testHistoryIsBounded() {
        var state = MonitorState()
        for index in 0..<(MonitorState.historyLimit + 50) { state.record(result(index % 2 == 0, Double(index)), failureThreshold: 1) }
        XCTAssertEqual(state.history.count, MonitorState.historyLimit)
        XCTAssertLessThanOrEqual(state.changes.count, MonitorState.changeLimit)
        XCTAssertNotNil(state.uptime)
    }

    func testTCPProbeSeesOpenAndClosedPorts() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.cancel() }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)

        let open = await MonitorProbe.tcp(host: "127.0.0.1", port: Int(port), timeout: 5)
        XCTAssertTrue(open.ok)
        XCTAssertNotNil(open.latencyMilliseconds)

        listener.cancel()
        try await Task.sleep(for: .milliseconds(300))
        let closed = await MonitorProbe.tcp(host: "127.0.0.1", port: Int(port), timeout: 5)
        XCTAssertFalse(closed.ok)
    }

    func testHTTPProbeStatusHandling() async throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, _ in
                let request = String(decoding: data ?? Data(), as: UTF8.self)
                let status = request.contains("GET /down") ? "503 Service Unavailable"
                    : request.contains("GET /moved") ? "302 Found\r\nLocation: http://127.0.0.1:1/" : "200 OK"
                let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)
        let base = "http://127.0.0.1:\(port)"

        let good = await MonitorProbe.http(url: base + "/up", timeout: 5)
        XCTAssertTrue(good.ok); XCTAssertEqual(good.detail, "HTTP 200")
        let bad = await MonitorProbe.http(url: base + "/down", timeout: 5)
        XCTAssertFalse(bad.ok); XCTAssertEqual(bad.detail, "HTTP 503")
        let redirect = await MonitorProbe.http(url: base + "/moved", timeout: 5)
        XCTAssertTrue(redirect.ok, "A redirect proves the server answers and is not followed")
        let invalid = await MonitorProbe.http(url: "not a url", timeout: 5)
        XCTAssertFalse(invalid.ok)
    }

    func testDNSProbeSeesAValidResponse() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receiveMessage { data, _, _, _ in
                guard let data, data.count >= 12 else { connection.cancel(); return }
                var response = data
                response[2] = 0x81
                response[3] = 0x80
                response[6] = 0; response[7] = 0; response[8] = 0; response[9] = 0; response[10] = 0; response[11] = 0
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port?.rawValue)

        let good = await MonitorProbe.dns(host: "127.0.0.1", port: Int(port), queryName: "example.com", timeout: 5)
        XCTAssertTrue(good.ok); XCTAssertEqual(good.detail, "DNS response")
        let invalid = await MonitorProbe.dns(host: "127.0.0.1", port: Int(port), queryName: "bad name", timeout: 5)
        XCTAssertFalse(invalid.ok); XCTAssertEqual(invalid.detail, "Invalid DNS target")
    }

    func testEngineRecordsTransitionsAndDropsRemovedTargets() async throws {
        let outcomes = OutcomeQueue([true, false, false, true])
        let engine = MonitorEngine(prober: { _ in await outcomes.next() })
        let target = MonitorTarget(name: "NAS", kind: .tcp, host: "nas.local", port: 22, failureThreshold: 2)
        await engine.configure([target])
        for _ in 0..<4 { await engine.checkNow(target.id) }
        let transitions = await engine.drainTransitions()
        XCTAssertEqual(transitions.map(\.change.status), [.down, .up])
        XCTAssertEqual(transitions.first?.name, "NAS")
        let drained = await engine.drainTransitions()
        XCTAssertTrue(drained.isEmpty)
        await engine.configure([])
        let snapshot = await engine.snapshot()
        XCTAssertTrue(snapshot.isEmpty)
        await engine.stop()
    }

    // MARK: Inconclusive checks and observations

    func testInconclusiveChecksNeverCountTowardOrClearAFailure() {
        var state = MonitorState()
        XCTAssertNil(state.record(MonitorResult(ok: true, detail: "OK"), failureThreshold: 2))
        XCTAssertNil(state.record(MonitorResult(ok: false, detail: "Down"), failureThreshold: 2))
        XCTAssertNil(state.record(MonitorResult(ok: false, detail: "No network", inconclusive: true), failureThreshold: 2))
        XCTAssertEqual(state.consecutiveFailures, 1, "An inconclusive check is neither a failure nor a success")
        XCTAssertEqual(state.status, .up)
        let change = state.record(MonitorResult(ok: false, detail: "Down"), failureThreshold: 2)
        XCTAssertEqual(change?.status, .down)
        XCTAssertNil(state.record(MonitorResult(ok: false, detail: "No network", inconclusive: true), failureThreshold: 2))
        XCTAssertEqual(state.status, .down, "Losing local connectivity does not recover a confirmed outage")
        XCTAssertEqual(state.uptime ?? 0, 1.0 / 3.0, accuracy: 0.0001, "Inconclusive checks are excluded from uptime")
    }

    func testFailuresWithoutANetworkOrAfterAWakeGapAreInconclusive() {
        let failure = MonitorResult(ok: false, detail: "Timed out")
        XCTAssertTrue(MonitorEngine.classify(failure, networkAvailable: false, late: false).inconclusive)
        XCTAssertTrue(MonitorEngine.classify(failure, networkAvailable: true, late: true).inconclusive)
        XCTAssertEqual(MonitorEngine.classify(failure, networkAvailable: true, late: false), failure)
        let success = MonitorResult(ok: true, detail: "OK")
        XCTAssertEqual(MonitorEngine.classify(success, networkAvailable: false, late: true), success,
                       "A success is trusted regardless of local conditions")
        XCTAssertFalse(MonitorEngine.isLate(lateness: .seconds(2)))
        XCTAssertTrue(MonitorEngine.isLate(lateness: .seconds(40)))
    }

    func testEnginePublishesEveryCheckAsAnObservation() async throws {
        let outcomes = OutcomeQueue([false, false, true])
        let available = AvailabilityFlag(true)
        let engine = MonitorEngine(prober: { _ in await outcomes.next() }, networkAvailable: { available.value })
        let target = MonitorTarget(name: "Site", kind: .http, url: "https://example.com", failureThreshold: 2, enabled: false)
        await engine.configure([target]) // disabled: no background loop races the explicit checks
        await engine.checkNow(target.id)
        available.value = false
        await engine.checkNow(target.id)
        available.value = true
        await engine.checkNow(target.id)
        let seen = await engine.drainObservations()
        XCTAssertEqual(seen.map(\.result.inconclusive), [false, true, false])
        XCTAssertEqual(seen.map(\.consecutiveFailures), [1, 1, 0])
        XCTAssertEqual(seen.last?.status, .up)
        XCTAssertEqual(seen.first?.failureThreshold, 2)
        let drained = await engine.drainObservations()
        XCTAssertTrue(drained.isEmpty)
        await engine.stop()
    }
}

private final class AvailabilityFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag: Bool
    init(_ value: Bool) { flag = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return flag }
        set { lock.lock(); flag = newValue; lock.unlock() }
    }
}

private actor OutcomeQueue {
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func next() -> MonitorResult {
        let ok = values.isEmpty ? true : values.removeFirst()
        return MonitorResult(ok: ok, latencyMilliseconds: ok ? 1 : nil, detail: ok ? "OK" : "Down")
    }
}

final class MonitorTargetAttentionTests: XCTestCase {
    func testOlderTargetWithoutAttentionSettingDecodesAsOff() throws {
        let json = """
        {"id":"\(UUID().uuidString.lowercased())","name":"NAS","kind":"TCP","host":"10.0.0.2","port":22,
         "url":"","intervalSeconds":60,"timeoutSeconds":10,"failureThreshold":3,"enabled":true}
        """
        let target = try JSONDecoder().decode(MonitorTarget.self, from: Data(json.utf8))
        XCTAssertFalse(target.needsAttention)
        XCTAssertEqual(target.dnsQueryName, "example.com")
    }

    func testAttentionSettingRoundTrips() throws {
        let target = MonitorTarget(name: "Site", kind: .http, url: "https://example.com", needsAttention: true)
        let decoded = try JSONDecoder().decode(MonitorTarget.self, from: JSONEncoder().encode(target))
        XCTAssertEqual(decoded, target)
        XCTAssertTrue(decoded.needsAttention)
    }
}

final class MonitorWebPermissionTests: XCTestCase {
    func testWebConsoleRejectsLocalAndMetadataTargets() {
        let blocked: [MonitorTarget] = [
            MonitorTarget(name: "a", kind: .tcp, host: "127.0.0.1", port: 22),
            MonitorTarget(name: "b", kind: .tcp, host: "localhost", port: 22),
            MonitorTarget(name: "c", kind: .http, url: "http://169.254.169.254/latest"),
            MonitorTarget(name: "d", kind: .dns, host: "::1", port: 53),
            MonitorTarget(name: "e", kind: .tcp, host: "2130706433", port: 22),
            MonitorTarget(name: "f", kind: .http, url: "http://0.0.0.0:8080")
        ]
        for target in blocked { XCTAssertFalse(target.isWebPermitted, target.name) }
    }

    func testWebConsoleAllowsLANAndInternetTargets() {
        XCTAssertTrue(MonitorTarget(name: "nas", kind: .tcp, host: "192.168.1.20", port: 445).isWebPermitted)
        XCTAssertTrue(MonitorTarget(name: "site", kind: .http, url: "https://status.example.com").isWebPermitted)
        XCTAssertTrue(MonitorTarget(name: "dns", kind: .dns, host: "192.168.1.1", port: 53).isWebPermitted)
    }
}
