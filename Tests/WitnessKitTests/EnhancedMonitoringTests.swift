import Foundation
import Network
import RuruClient
import XCTest
@testable import WitnessKit

final class MonitorStatusDocumentTests: XCTestCase {
    private let origin = URL(string: "https://app.example.com/health")!

    private func parse(_ json: String) -> Result<MonitorStatusDocument, MonitorStatusDocument.Issue> {
        MonitorStatusDocument.parse(Data(json.utf8), origin: origin)
    }

    private func document(_ json: String, file: StaticString = #filePath, line: UInt = #line) throws -> MonitorStatusDocument {
        switch parse(json) {
        case .success(let document): return document
        case .failure(let issue): XCTFail("Rejected: \(issue)", file: file, line: line); throw issue
        }
    }

    private func issue(_ json: String) -> MonitorStatusDocument.Issue? {
        if case .failure(let issue) = parse(json) { return issue }
        return nil
    }

    func testDocumentURLKeepsOriginAndReplacesPath() {
        XCTAssertEqual(MonitorStatusDocument.documentURL(for: URL(string: "https://Example.com:8443/a/b?q=1#x")!)?.absoluteString,
                       "https://Example.com:8443/.well-known/ruru")
        XCTAssertEqual(MonitorStatusDocument.documentURL(for: URL(string: "http://192.168.1.30:8080")!)?.absoluteString,
                       "http://192.168.1.30:8080/.well-known/ruru")
        XCTAssertNil(MonitorStatusDocument.documentURL(for: URL(string: "https://user:pw@example.com/")!))
        XCTAssertNil(MonitorStatusDocument.documentURL(for: URL(string: "ftp://example.com/")!))
    }

    func testFullDocumentParses() throws {
        let doc = try document("""
        {"ruru":1,"app":{"id":"app.example","name":"Example","version":"1.45.0","build":"2026101912"},
         "state":"degraded","reasonCode":"account_needs_sign_in","uptimeSeconds":183412,
         "components":[{"id":"miners","name":"Drop miners","state":"degraded","reasonCode":"account_needs_sign_in"},
                       {"id":"swiftbot","name":"SwiftBot connection","state":"ready"}],
         "metrics":[{"id":"accounts","name":"Accounts","value":3,"unit":"count"}],
         "links":[{"rel":"dashboard","title":"Dashboard","url":"https://app.example.com/app"}],
         "futureField":{"ignored":true}}
        """)
        XCTAssertEqual(doc.app.name, "Example")
        XCTAssertEqual(doc.app.version, "1.45.0")
        XCTAssertEqual(doc.state, .degraded)
        XCTAssertEqual(doc.components.map(\.id), ["miners", "swiftbot"])
        XCTAssertEqual(doc.metrics.first?.value, 3)
        XCTAssertEqual(doc.links.first?.url.absoluteString, "https://app.example.com/app")
    }

    func testMinimalDocumentParses() throws {
        let doc = try document(#"{"ruru":1,"app":{"id":"a","name":"A"},"state":"ready"}"#)
        XCTAssertTrue(doc.components.isEmpty && doc.metrics.isEmpty && doc.links.isEmpty)
        XCTAssertNil(doc.app.version)
    }

    func testVersionAndJSONFailures() {
        XCTAssertEqual(issue(#"{"ruru":2,"app":{"id":"a","name":"A"},"state":"ready"}"#), .unsupportedVersion)
        XCTAssertEqual(issue("<html>hello</html>"), .notJSON)
        XCTAssertEqual(issue(#"{"app":{"id":"a","name":"A"},"state":"ready"}"#), .invalid)
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"A"},"state":"fine"}"#), .invalid)
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"A"},"state":"ready","uptimeSeconds":-1}"#), .invalid)
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"A"},"state":"ready","metrics":[{"id":"m","name":"M","value":1e400}]}"#), .invalid)
    }

    func testSizeAndCountBounds() {
        let padding = String(repeating: " ", count: MonitorStatusDocument.maxBytes)
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"A"},"state":"ready"}"# + padding), .tooLarge)
        let components = (0...MonitorStatusDocument.maxComponents).map { #"{"id":"c\#($0)","name":"C","state":"ready"}"# }
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"A"},"state":"ready","components":[\#(components.joined(separator: ","))]}"#), .invalid)
        let duplicate = #"{"id":"m","name":"M","value":1}"#
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"A"},"state":"ready","metrics":[\#(duplicate),\#(duplicate)]}"#), .invalid)
    }

    func testMachineCodesAreStrictASCII() {
        for bad in ["", "Upper", "has space", "slash/es", String(repeating: "a", count: 49), "ünicode"] {
            XCTAssertNil(MonitorStatusDocument.machineCode(bad), bad)
        }
        XCTAssertEqual(MonitorStatusDocument.machineCode("app.swift-miner_2"), "app.swift-miner_2")
    }

    func testHostileTextIsCleanedOrRejected() throws {
        // Right-to-left override and zero-width space are removed; a newline is a control character.
        let doc = try document(#"{"ruru":1,"app":{"id":"a","name":"Evil‮gnp.exe​\n"},"state":"ready"}"#)
        XCTAssertEqual(doc.app.name, "Evilgnp.exe")
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"‮​"},"state":"ready"}"#), .invalid)
        XCTAssertEqual(issue(#"{"ruru":1,"app":{"id":"a","name":"\#(String(repeating: "x", count: 65))"},"state":"ready"}"#), .invalid)
    }

    func testOnlySameHostHTTPSLinksSurvive() throws {
        let doc = try document("""
        {"ruru":1,"app":{"id":"a","name":"A"},"state":"ready","links":[
         {"rel":"dashboard","title":"Mine","url":"https://APP.example.com/x"},
         {"rel":"status","title":"Plain","url":"http://app.example.com/x"},
         {"rel":"docs","title":"Elsewhere","url":"https://phish.example.net/"},
         {"rel":"support","title":"Creds","url":"https://u:p@app.example.com/"}]}
        """)
        XCTAssertEqual(doc.links.map(\.title), ["Mine"])
    }
}

final class MonitorStatusStateTests: XCTestCase {
    private func doc(state: MonitorStatusDocument.State = .ready, version: String = "1.0", uptime: Int = 100,
                     metrics: [String: Double] = ["a": 1]) -> MonitorStatusDocument {
        let json: [String: Any] = [
            "ruru": 1, "app": ["id": "a", "name": "A", "version": version], "state": state.rawValue, "uptimeSeconds": uptime,
            "metrics": metrics.sorted { $0.key < $1.key }.map { ["id": $0.key, "name": $0.key.uppercased(), "value": $0.value] }
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return try! MonitorStatusDocument.parse(data, origin: URL(string: "https://example.com")!).get()
    }

    private func result(_ at: TimeInterval, ok: Bool = true, _ status: MonitorStatusOutcome?) -> MonitorResult {
        MonitorResult(time: Date(timeIntervalSince1970: at), ok: ok, detail: ok ? "HTTP 200" : "Timed out", status: status)
    }

    func testDocumentIsKeptOutOfHistoryAndGoesStaleOnFailure() {
        var state = MonitorState()
        state.record(result(1, .document(doc())), failureThreshold: 3)
        XCTAssertNil(state.history.last?.status, "History keeps results, not document copies")
        XCTAssertEqual(state.statusDocument?.app.name, "A")
        XCTAssertTrue(state.statusDocumentIsCurrent)

        state.record(result(2, ok: false, nil), failureThreshold: 3)
        XCTAssertNotNil(state.statusDocument, "The last document stays visible")
        XCTAssertFalse(state.statusDocumentIsCurrent)

        state.record(result(3, .issue(.invalid)), failureThreshold: 3)
        XCTAssertEqual(state.statusIssue, .invalid)
        XCTAssertEqual(state.status, .up, "An invalid document never makes an answering server down")
        state.record(result(4, .document(doc())), failureThreshold: 3)
        XCTAssertNil(state.statusIssue)
    }

    func testStateVersionAndRestartEvents() {
        var state = MonitorState()
        state.record(result(1, .document(doc(version: "1.0", uptime: 500))), failureThreshold: 3)
        XCTAssertTrue(state.statusEvents.isEmpty, "The first document is not news")
        state.record(result(2, .document(doc(state: .degraded, version: "1.1", uptime: 5))), failureThreshold: 3)
        XCTAssertEqual(state.statusEvents.map(\.kind), [.stateChanged(from: .ready, to: .degraded),
                                                        .versionChanged(from: "1.0", to: "1.1"), .restarted])
        for step in 0..<40 {
            state.record(result(Double(3 + step), .document(doc(state: step.isMultiple(of: 2) ? .ready : .degraded))), failureThreshold: 3)
        }
        XCTAssertEqual(state.statusEvents.count, MonitorState.statusEventLimit)
    }

    func testMetricHistoryIsBoundedAndFollowsTheDocument() {
        var state = MonitorState()
        for step in 0..<(MonitorState.historyLimit + 10) {
            state.record(result(Double(step), .document(doc(metrics: ["a": Double(step), "b": 1]))), failureThreshold: 3)
        }
        XCTAssertEqual(state.metricHistory["a"]?.count, MonitorState.historyLimit)
        XCTAssertEqual(state.metricHistory["a"]?.last?.value, Double(MonitorState.historyLimit + 9))
        state.record(result(1000, .document(doc(metrics: ["c": 2]))), failureThreshold: 3)
        XCTAssertEqual(Set(state.metricHistory.keys), ["c"], "Metrics the app stopped reporting are dropped")
    }
}

final class EnhancedMonitorTargetTests: XCTestCase {
    func testOlderTargetsDecodeWithEnhancedStatusOff() throws {
        let json = """
        {"id":"\(UUID().uuidString.lowercased())","name":"Site","kind":"HTTP","host":"","port":0,
         "url":"https://example.com","intervalSeconds":60,"timeoutSeconds":10,"failureThreshold":3,"enabled":true}
        """
        XCTAssertFalse(try JSONDecoder().decode(MonitorTarget.self, from: Data(json.utf8)).enhancedStatus)
    }

    func testEnhancedStatusRoundTripsAndIsHTTPOnly() throws {
        let target = MonitorTarget(name: "Site", kind: .http, url: "https://example.com/health", enhancedStatus: true)
        XCTAssertTrue(target.isValid)
        XCTAssertEqual(target.address, "https://example.com/.well-known/ruru")
        XCTAssertEqual(try JSONDecoder().decode(MonitorTarget.self, from: JSONEncoder().encode(target)), target)
        XCTAssertFalse(MonitorTarget(name: "NAS", kind: .tcp, host: "10.0.0.2", port: 22, enhancedStatus: true).isValid)
    }

    func testWebConsoleRestrictionStillAppliesToEnhancedTargets() async {
        var target = MonitorTarget(name: "Loop", kind: .http, url: "http://127.0.0.1:9/", enhancedStatus: true)
        target.requiresNumericHost = true
        let result = await MonitorProbe.run(target)
        XCTAssertFalse(result.ok)
        XCTAssertNil(result.status)
    }
}

final class EnhancedMonitorProbeTests: XCTestCase {
    /// Serves one canned response per connection and records request lines.
    private final class Server: @unchecked Sendable {
        let listener: NWListener
        private let lock = NSLock()
        private var lines: [String] = []
        var requestLines: [String] { lock.lock(); defer { lock.unlock() }; return lines }

        init(response: @escaping @Sendable (String) -> Data) throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .global())
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    let request = String(decoding: data ?? Data(), as: UTF8.self)
                    let line = request.components(separatedBy: "\r\n").first ?? ""
                    if let self { self.lock.lock(); self.lines.append(line); self.lock.unlock() }
                    connection.send(content: response(line), completion: .contentProcessed { _ in connection.cancel() })
                }
            }
        }
    }

    private func start(_ server: Server) async throws -> String {
        let ready = expectation(description: "listening")
        server.listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        server.listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 5)
        addTeardownBlock { server.listener.cancel() }
        return "http://127.0.0.1:\(try XCTUnwrap(server.listener.port?.rawValue))"
    }

    private static func reply(_ status: String, _ body: String, contentLength: Bool = true) -> Data {
        let length = contentLength ? "Content-Length: \(body.utf8.count)\r\n" : ""
        return Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n\(length)Connection: close\r\n\r\n\(body)".utf8)
    }

    func testValidDocumentIsReadFromTheWellKnownPath() async throws {
        let body = #"{"ruru":1,"app":{"id":"a","name":"Example"},"state":"degraded"}"#
        let server = try Server { line in line.hasPrefix("GET /.well-known/ruru ") ? Self.reply("200 OK", body) : Self.reply("500 Oops", "") }
        let base = try await start(server)
        let result = await MonitorProbe.http(url: base + "/some/page", timeout: 5, statusDocument: true)
        XCTAssertTrue(result.ok)
        guard case .document(let document) = result.status else { return XCTFail("No document: \(String(describing: result.status))") }
        XCTAssertEqual(document.state, .degraded)
        XCTAssertEqual(server.requestLines.count, 1, "One request per check")
    }

    func testAnsweringServerWithoutAUsableDocumentIsStillUp() async throws {
        let cases: [(Data, MonitorStatusDocument.Issue)] = [
            (Self.reply("200 OK", "<html></html>"), .notJSON),
            (Self.reply("204 No Content", ""), .unavailable),
            (Self.reply("302 Found\r\nLocation: http://127.0.0.1:1/", ""), .unavailable),
            (Self.reply("200 OK", String(repeating: "x", count: MonitorStatusDocument.maxBytes + 1)), .tooLarge),
            (Self.reply("200 OK", String(repeating: "x", count: MonitorStatusDocument.maxBytes + 1), contentLength: false), .tooLarge)
        ]
        for (response, expected) in cases {
            let server = try Server { _ in response }
            let base = try await start(server)
            let result = await MonitorProbe.http(url: base, timeout: 5, statusDocument: true)
            XCTAssertTrue(result.ok, "\(expected)")
            XCTAssertEqual(result.status, .issue(expected))
        }
    }

    func testErrorStatusIsAFailureWithoutDocument() async throws {
        let server = try Server { _ in Self.reply("503 Service Unavailable", "{}") }
        let base = try await start(server)
        let result = await MonitorProbe.http(url: base, timeout: 5, statusDocument: true)
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.detail, "HTTP 503")
        XCTAssertNil(result.status)
    }

    func testPlainHTTPChecksAreUnchanged() async throws {
        let server = try Server { _ in Self.reply("200 OK", "{}") }
        let base = try await start(server)
        let result = await MonitorProbe.http(url: base + "/health", timeout: 5)
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.status)
        XCTAssertEqual(server.requestLines.first?.hasPrefix("GET /health "), true)
    }
}

/// The public RuruClient builder must always produce documents Ruru accepts.
final class StatusDocumentConformanceTests: XCTestCase {
    func testClientBuiltDocumentParsesInRuru() throws {
        let built = RuruStatusDocument(
            app: .init(id: "app.example", name: "Example", version: "1.45.0", build: "2026101912"),
            state: .degraded, reasonCode: "account_needs_sign_in", uptimeSeconds: 42,
            components: [.init(id: "miners", name: "Drop miners", state: .degraded, reasonCode: "account_needs_sign_in"),
                         .init(id: "swiftbot", name: "SwiftBot connection", state: .ready)],
            metrics: [.init(id: "accounts", name: "Accounts", value: 3, unit: "count")],
            links: [.init(rel: .dashboard, title: "Dashboard", url: URL(string: "https://app.example.com/app")!)])
        let parsed = try MonitorStatusDocument.parse(built.encoded(), origin: URL(string: "https://app.example.com")!).get()
        XCTAssertEqual(parsed.app.id, "app.example")
        XCTAssertEqual(parsed.state, .degraded)
        XCTAssertEqual(parsed.components.map(\.state), [.degraded, .ready])
        XCTAssertEqual(parsed.metrics.first?.unit, "count")
        XCTAssertEqual(parsed.links.count, 1)
        XCTAssertEqual(RuruStatusDocument.path, MonitorStatusDocument.path)
        XCTAssertEqual(RuruStatusDocument.maxBytes, MonitorStatusDocument.maxBytes)
    }

    /// A real response captured from SwiftMiner 1.45.0, which implements the
    /// schema without RuruClient.
    func testSwiftMinerDocumentParses() throws {
        let json = #"{"metrics":[{"unit":"count","id":"accounts","name":"Accounts","value":2},{"unit":"count","id":"mining","name":"Mining now","value":2},{"unit":"count","id":"needs_sign_in","name":"Need sign-in","value":0},{"unit":"count","id":"drops_claimed","name":"Drops claimed","value":144}],"components":[{"id":"miners","name":"Drop miners","state":"ready"},{"id":"swiftbot","reasonCode":"swiftbot_disconnected","name":"SwiftBot connection","state":"degraded"}],"state":"degraded","app":{"id":"app.swiftminer","name":"SwiftMiner","build":"2026101913","version":"1.45.0"},"ruru":1,"uptimeSeconds":383,"reasonCode":"swiftbot_disconnected"}"#
        let parsed = try MonitorStatusDocument.parse(Data(json.utf8), origin: URL(string: "http://10.11.1.40:8080")!).get()
        XCTAssertEqual(parsed.app.name, "SwiftMiner")
        XCTAssertEqual(parsed.state, .degraded)
        XCTAssertEqual(parsed.metrics.count, 4)
    }

    func testSchemaFileMatchesParserLimits() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Documentation/ruru-status-v1.schema.json")
        let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual((properties["components"] as? [String: Any])?["maxItems"] as? Int, MonitorStatusDocument.maxComponents)
        XCTAssertEqual((properties["metrics"] as? [String: Any])?["maxItems"] as? Int, MonitorStatusDocument.maxMetrics)
        XCTAssertEqual((properties["links"] as? [String: Any])?["maxItems"] as? Int, MonitorStatusDocument.maxLinks)
        let states = ((schema["$defs"] as? [String: Any])?["state"] as? [String: Any])?["enum"] as? [String]
        XCTAssertEqual(states, MonitorStatusDocument.State.allCases.map(\.rawValue))
    }

    func testClientAndServerShareTheStateVocabulary() throws {
        let clientStates: [RuruOperationalState] = [.ready, .synchronizing, .outdated, .degraded, .unknown]
        XCTAssertEqual(clientStates.map(\.rawValue), MonitorStatusDocument.State.allCases.map(\.rawValue))
    }
}
