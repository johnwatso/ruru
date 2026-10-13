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
        XCTAssertFalse(MonitorTarget(name: "", kind: .tcp, host: "nas.local", port: 22).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .tcp, host: "nas local", port: 22).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .tcp, host: "nas/etc", port: 22).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .tcp, host: "nas", port: 0).isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .http, url: "ftp://example.com").isValid)
        XCTAssertFalse(MonitorTarget(name: "Bad", kind: .http, url: "https://user:pw@example.com").isValid)
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
}

private actor OutcomeQueue {
    private var values: [Bool]
    init(_ values: [Bool]) { self.values = values }
    func next() -> MonitorResult {
        let ok = values.isEmpty ? true : values.removeFirst()
        return MonitorResult(ok: ok, latencyMilliseconds: ok ? 1 : nil, detail: ok ? "OK" : "Down")
    }
}
