import Foundation

/// Pairs this server with a Ruru service using a one-time code shown in Ruru's
/// Connection Details. The operator must approve the request in Ruru before
/// any credentials are returned. Store the returned token in Keychain.
public enum RuruPairing {
    public enum Failure: Error, Equatable, Sendable {
        /// The code is wrong, already used, or expired.
        case invalidCode
        /// The operator rejected the request in Ruru.
        case rejected
        /// Nobody approved the request before it expired.
        case expired
        /// Too many wrong codes recently; wait a minute.
        case throttled
        case server(status: Int, code: String)
        case transport(String)
    }

    /// Exchanges `code` for connection details, waiting up to `timeout` for the
    /// operator to approve. Returns a configuration ready for `RuruLeaseClient`.
    public static func pair(endpoint: URL, code: String, nodeID: String, nodeName: String? = nil,
                            timeout: Duration = .seconds(600), session: URLSession = .shared) async throws -> RuruConfiguration {
        var body = ["code": code, "nodeID": nodeID]
        if let nodeName { body["nodeName"] = nodeName }
        let claim = try await post(endpoint, "v1/pair", body, session)
        guard let pairingID = claim["pairingID"] as? String else { throw Failure.server(status: 202, code: "invalid_response") }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let reply = try await post(endpoint, "v1/pair/status", ["pairingID": pairingID], session)
            if reply["status"] as? String == "approved",
               let clusterID = reply["clusterID"] as? String, let token = reply["token"] as? String {
                return RuruConfiguration(endpoint: endpoint, clusterID: clusterID, nodeID: nodeID, nodeName: nodeName, token: token)
            }
            let wait = (reply["retryAfter"] as? Double) ?? 2
            try await Task.sleep(for: .seconds(min(10, max(1, wait))))
        }
        throw Failure.expired
    }

    private static func post(_ endpoint: URL, _ path: String, _ body: [String: String],
                             _ session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw Failure.transport(error.localizedDescription) }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200, 202: return object
        case 404: throw Failure.invalidCode
        case 403: throw Failure.rejected
        case 410: throw Failure.expired
        case 429: throw Failure.throttled
        default: throw Failure.server(status: status, code: object["error"] as? String ?? "")
        }
    }
}
