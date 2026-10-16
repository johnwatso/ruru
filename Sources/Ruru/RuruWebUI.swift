import Foundation
import Security
import WebAuthn
import WitnessKit

/// The browser operator surface. It is intentionally app-owned: WitnessKit
/// continues to own the bounded listener and every `/v1` authority route.
/// Cloudflare Access is the perimeter identity provider; a resident, user-
/// verified passkey is the second factor before any Ruru operation is exposed.
actor RuruWebUI {
    typealias OriginProvider = @Sendable () async -> String?
    typealias MonitorSnapshot = @Sendable () async -> [WebMonitor]
    typealias ServiceSnapshot = @Sendable () async -> WebService
    typealias GuardedSnapshot = @Sendable () async -> [WebGuardedService]
    typealias MonitorSave = @Sendable (MonitorTarget) async throws -> Void
    typealias MonitorRemove = @Sendable (String) async throws -> Void
    typealias MonitorCheck = @Sendable (String) async -> Void

    /// Whether Ruru's authority is running, for the console header.
    struct WebService: Encodable, Sendable {
        let running: Bool
        let startedAt: Date?
    }

    /// A read-only view of one guarded service. It deliberately omits cluster
    /// IDs, node IDs, credentials and participant-reported URLs: the browser can
    /// see who owns a service, never act on ownership.
    struct WebGuardedService: Encodable, Sendable {
        let id: String
        let name: String
        let kind: String
        let leaseSeconds: Int
        /// "owned", "waiting" or "recovering".
        let state: String
        let recoverySeconds: Double
        let owner: Owner?
        let participants: [Participant]
        let activity: [Activity]

        struct Owner: Encodable, Sendable { let name: String; let term: Int64; let remainingSeconds: Double }
        struct Participant: Encodable, Sendable { let name: String; let role: String; let fresh: Bool; let ageSeconds: Double }
        struct Activity: Encodable, Sendable { let time: Date; let action: String; let name: String; let term: Int64 }
    }

    /// A monitor target plus its live state, flattened for the browser.
    struct WebMonitor: Encodable, Sendable {
        let target: MonitorTarget
        let status: String
        let latencyMilliseconds: Int?
        let detail: String?
        let history: [Sample]
        let changes: [Change]

        struct Sample: Encodable, Sendable { let ok: Bool; let ms: Int?; let inconclusive: Bool }
        struct Change: Encodable, Sendable { let time: Date; let status: String; let detail: String }
        private enum Keys: String, CodingKey { case status, latencyMilliseconds, detail, history, changes }

        func encode(to encoder: Encoder) throws {
            try target.encode(to: encoder)
            var values = encoder.container(keyedBy: Keys.self)
            try values.encode(status, forKey: .status)
            try values.encodeIfPresent(latencyMilliseconds, forKey: .latencyMilliseconds)
            try values.encodeIfPresent(detail, forKey: .detail)
            try values.encode(history, forKey: .history)
            try values.encode(changes, forKey: .changes)
        }
    }

    private enum OperatorRole: String, Codable, Sendable {
        case owner
        case administrator
    }

    private struct Passkey: Codable, Sendable {
        var id: String
        var publicKey: [UInt8]
        var signCount: UInt32
        var email: String
        var role: OperatorRole

        /// Records created before multi-operator support had no role. They are
        /// upgraded by `loadPasskeys()` below, which gives the original
        /// operator the sole owner role.
        init(id: String, publicKey: [UInt8], signCount: UInt32, email: String, role: OperatorRole = .administrator) {
            self.id = id; self.publicKey = publicKey; self.signCount = signCount; self.email = email; self.role = role
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            publicKey = try values.decode([UInt8].self, forKey: .publicKey)
            signCount = try values.decode(UInt32.self, forKey: .signCount)
            email = try values.decode(String.self, forKey: .email)
            role = try values.decodeIfPresent(OperatorRole.self, forKey: .role) ?? .administrator
        }
    }

    private struct Ceremony: Sendable {
        enum Kind: Sendable, Equatable { case registration, authentication }
        var kind: Kind
        var email: String
        var challenge: [UInt8]
        var expires: Date
    }

    private struct Session: Sendable {
        var email: String
        var csrf: String
        var expires: Date
    }

    private enum EnrollmentKind: Sendable { case firstOwner, operatorInvite }

    private struct Enrollment: Sendable {
        var code: String
        var email: String?
        var kind: EnrollmentKind
        var expires: Date
    }

    private let origin: OriginProvider
    private let monitorSnapshot: MonitorSnapshot
    private let serviceSnapshot: ServiceSnapshot
    private let guardedSnapshot: GuardedSnapshot
    private let monitorSave: MonitorSave
    private let monitorRemove: MonitorRemove
    private let monitorCheck: MonitorCheck
    private var passkeys: [Passkey] = []
    /// A Keychain read failure must not look like "no operators": doing so
    /// would let a damaged item become an unauthenticated re-enrolment path.
    private var passkeyStoreUnavailable = false
    private var ceremonies: [String: Ceremony] = [:]
    private var sessions: [String: Session] = [:]
    private var enrollment: Enrollment?

    init(origin: @escaping OriginProvider, monitorSnapshot: @escaping MonitorSnapshot, serviceSnapshot: @escaping ServiceSnapshot,
         guardedSnapshot: @escaping GuardedSnapshot,
         monitorSave: @escaping MonitorSave, monitorRemove: @escaping MonitorRemove,
         monitorCheck: @escaping MonitorCheck) {
        self.origin = origin
        self.monitorSnapshot = monitorSnapshot
        self.serviceSnapshot = serviceSnapshot
        self.guardedSnapshot = guardedSnapshot
        self.monitorSave = monitorSave
        self.monitorRemove = monitorRemove
        self.monitorCheck = monitorCheck
        do { passkeys = try Self.loadPasskeys() }
        catch { passkeyStoreUnavailable = true }
    }

    /// Called only from the local, signed-in macOS console. It is intentionally
    /// volatile: restarting Ruru invalidates unfinished enrolment ceremonies.
    func beginEnrollment() throws -> String {
        prune()
        guard passkeys.isEmpty else { throw WebUIError.firstOperatorAlreadyEnrolled }
        let code = try Self.randomToken()
        enrollment = Enrollment(code: code, email: nil, kind: .firstOwner, expires: Date().addingTimeInterval(10 * 60))
        return code
    }

    func route(_ request: WitnessWebRequest) async -> WitnessWebResponse? {
        // Access headers are only trustworthy when the request came through the
        // local tunnel helper; a LAN peer could forge them.
        guard request.isLoopbackPeer else { return Self.jsonError("tunnel_required", status: 403) }
        guard let origin = await origin() else { return Self.jsonError("web_ui_unavailable", status: 503) }
        guard !passkeyStoreUnavailable else { return Self.jsonError("passkey_store_unavailable", status: 503) }
        guard let email = Self.accessEmail(request.headers["cf-access-authenticated-user-email"]) else {
            return Self.jsonError("cloudflare_access_required", status: 401)
        }
        prune()
        switch (request.method, request.path) {
        case ("GET", "/"):
            return Self.html(RuruWebAssets.page)
        case ("GET", "/web/ruru.png"):
            guard let data = Self.owlPNG else { return nil }
            return .init(contentType: "image/png", body: data,
                         headers: ["Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'"])
        case ("GET", "/web/app.css"):
            return Self.stylesheet(RuruWebAssets.stylesheet)
        case ("GET", "/web/app.js"):
            return Self.javascript(RuruWebAssets.script)
        case ("GET", "/api/web/status"):
            return Self.json(["passkeyEnrolled": !passkeys.isEmpty])
        case ("GET", "/api/web/passkeys/authentication/options"):
            return beginAuthentication(email: email, origin: origin)
        case ("POST", "/api/web/passkeys/authentication/finish"):
            return finishAuthentication(request, email: email, origin: origin)
        case ("POST", "/api/web/passkeys/registration/options"):
            return beginRegistration(request, email: email, origin: origin)
        case ("POST", "/api/web/passkeys/registration/finish"):
            return await finishRegistration(request, email: email, origin: origin)
        default:
            break
        }

        guard let session = session(for: request, email: email) else { return Self.jsonError("passkey_required", status: 401) }
        switch (request.method, request.path) {
        case ("GET", "/api/web/operators"):
            guard role(for: email) == .owner else { return Self.jsonError("owner_required", status: 403) }
            return Self.json(passkeys.map { OperatorSummary(email: $0.email, role: $0.role.rawValue) })
        case ("POST", "/api/web/operators/invitations"):
            guard request.headers["x-ruru-csrf"] == session.csrf else { return Self.jsonError("csrf_required", status: 403) }
            guard role(for: email) == .owner else { return Self.jsonError("owner_required", status: 403) }
            return createOperatorInvite(request)
        case ("POST", "/api/web/logout"):
            guard request.headers["x-ruru-csrf"] == session.csrf else { return Self.jsonError("csrf_required", status: 403) }
            if let id = Self.cookie(named: "ruru_session", from: request.headers["cookie"]) { sessions.removeValue(forKey: id) }
            return Self.json(["loggedOut": true], headers: ["Set-Cookie": Self.cookie("ruru_session", value: "", age: 0)])
        case ("POST", "/api/web/operators/remove"):
            guard request.headers["x-ruru-csrf"] == session.csrf else { return Self.jsonError("csrf_required", status: 403) }
            guard role(for: email) == .owner else { return Self.jsonError("owner_required", status: 403) }
            return removeOperator(request, actingEmail: email)
        case ("GET", "/api/web/guarded"):
            return Self.json(await guardedSnapshot())
        case ("GET", "/api/web/service"):
            return Self.json(await serviceSnapshot())
        case ("GET", "/api/web/monitors"):
            return Self.json(await monitorSnapshot())
        case ("POST", "/api/web/monitors"):
            guard request.headers["x-ruru-csrf"] == session.csrf else { return Self.jsonError("csrf_required", status: 403) }
            do {
                let target = try JSONDecoder().decode(MonitorTarget.self, from: request.body)
                guard target.isWebPermitted else { return Self.jsonError("monitor_target_not_permitted", status: 400) }
                try await monitorSave(target)
                return Self.json(["saved": true])
            } catch { return Self.jsonError("invalid_monitor", status: 400) }
        case ("POST", "/api/web/monitors/delete"):
            guard request.headers["x-ruru-csrf"] == session.csrf else { return Self.jsonError("csrf_required", status: 403) }
            guard let id = try? JSONDecoder().decode(MonitorID.self, from: request.body).id else { return Self.jsonError("invalid_monitor", status: 400) }
            do { try await monitorRemove(id); return Self.json(["deleted": true]) }
            catch { return Self.jsonError("invalid_monitor", status: 400) }
        case ("POST", "/api/web/monitors/check"):
            guard request.headers["x-ruru-csrf"] == session.csrf else { return Self.jsonError("csrf_required", status: 403) }
            guard let id = try? JSONDecoder().decode(MonitorID.self, from: request.body).id else { return Self.jsonError("invalid_monitor", status: 400) }
            await monitorCheck(id)
            return Self.json(["checking": true])
        default:
            return nil
        }
    }

    private struct MonitorID: Decodable { let id: String }
    private struct EnrollmentRequest: Decodable { let code: String }
    private struct AuthenticationResult: Encodable { let authenticated: Bool; let csrf: String }
    private struct OperatorInvitationRequest: Decodable { let email: String }
    private struct OperatorInvitation: Encodable { let code: String; let expiresAt: Date; let email: String }
    private struct OperatorSummary: Encodable { let email: String; let role: String }

    private func createOperatorInvite(_ request: WitnessWebRequest) -> WitnessWebResponse {
        guard let request = try? JSONDecoder().decode(OperatorInvitationRequest.self, from: request.body),
              let invitedEmail = Self.accessEmail(request.email),
              !passkeys.contains(where: { $0.email == invitedEmail }),
              enrollment == nil else { return Self.jsonError("invalid_operator_invitation", status: 400) }
        guard passkeys.count < 8 else { return Self.jsonError("too_many_operators", status: 409) }
        do {
            let code = try Self.randomToken()
            let expiry = Date().addingTimeInterval(10 * 60)
            enrollment = Enrollment(code: code, email: invitedEmail, kind: .operatorInvite, expires: expiry)
            return Self.json(OperatorInvitation(code: code, expiresAt: expiry, email: invitedEmail))
        } catch { return Self.jsonError("enrollment_unavailable", status: 503) }
    }

    private func removeOperator(_ request: WitnessWebRequest, actingEmail: String) -> WitnessWebResponse {
        guard let value = try? JSONDecoder().decode(OperatorInvitationRequest.self, from: request.body),
              let target = Self.accessEmail(value.email), target != actingEmail,
              let index = passkeys.firstIndex(where: { $0.email == target }), passkeys[index].role != .owner else {
            return Self.jsonError("invalid_operator", status: 400)
        }
        let removed = passkeys.remove(at: index)
        do { try Self.savePasskeys(passkeys) }
        catch { passkeys.insert(removed, at: index); return Self.jsonError("passkey_store_unavailable", status: 503) }
        sessions = sessions.filter { $0.value.email != target }
        return Self.json(["removed": true])
    }

    private func beginRegistration(_ request: WitnessWebRequest, email: String, origin: String) -> WitnessWebResponse {
        guard let value = try? JSONDecoder().decode(EnrollmentRequest.self, from: request.body),
              let enrollment, enrollment.expires > Date(), enrollment.code == value.code,
              enrollment.email == nil || enrollment.email == email else {
            return Self.jsonError("enrollment_code_required", status: 403)
        }
        guard !passkeys.contains(where: { $0.email == email }), passkeys.count < 8 else {
            return Self.jsonError("operator_already_enrolled", status: 409)
        }
        let manager = Self.manager(for: origin)
        let userID: [UInt8]
        do { userID = try Self.randomBytes() } catch { return Self.jsonError("enrollment_unavailable", status: 503) }
        let options = manager.beginRegistration(user: .init(id: userID, name: email, displayName: email), timeout: .seconds(120),
                                                authenticatorSelection: .init(residentKey: .required, userVerification: .required))
        return startCeremony(.registration, email: email, challenge: options.challenge, body: options)
    }

    private func finishRegistration(_ request: WitnessWebRequest, email: String, origin: String) async -> WitnessWebResponse {
        guard let ceremony = ceremony(for: request, kind: .registration, email: email),
              (enrollment?.expires ?? .distantPast) > Date() else { return Self.jsonError("ceremony_expired", status: 401) }
        defer { ceremonies.removeValue(forKey: ceremony.0) }
        do {
            let submitted = try JSONDecoder().decode(RegistrationCredential.self, from: request.body)
            let existing = passkeys
            let credential = try await Self.manager(for: origin).finishRegistration(challenge: ceremony.1.challenge,
                credentialCreationData: submitted, requireUserVerification: true,
                confirmCredentialIDNotRegisteredYet: { id in !existing.contains(where: { $0.id == id }) })
            let role: OperatorRole = enrollment?.kind == .firstOwner ? .owner : .administrator
            passkeys.append(.init(id: credential.id, publicKey: credential.publicKey, signCount: credential.signCount, email: email, role: role))
            do { try Self.savePasskeys(passkeys) }
            catch { passkeys.removeLast(); return Self.jsonError("passkey_store_unavailable", status: 503) }
            enrollment = nil
            return createSession(email: email)
        } catch { return Self.jsonError("passkey_registration_failed", status: 400) }
    }

    private func beginAuthentication(email: String, origin: String) -> WitnessWebResponse {
        let records = passkeys.filter { $0.email == email }
        guard !records.isEmpty else { return Self.jsonError("passkey_not_enrolled", status: 404) }
        let descriptors = records.compactMap { record in
            Self.base64URLBytes(record.id).map { PublicKeyCredentialDescriptor(id: $0) }
        }
        guard descriptors.count == records.count else { return Self.jsonError("passkey_unavailable", status: 503) }
        let options = Self.manager(for: origin).beginAuthentication(timeout: .seconds(120), allowCredentials: descriptors, userVerification: .required)
        return startCeremony(.authentication, email: email, challenge: options.challenge, body: options)
    }

    private func finishAuthentication(_ request: WitnessWebRequest, email: String, origin: String) -> WitnessWebResponse {
        guard let ceremony = ceremony(for: request, kind: .authentication, email: email) else { return Self.jsonError("ceremony_expired", status: 401) }
        defer { ceremonies.removeValue(forKey: ceremony.0) }
        do {
            let submitted = try JSONDecoder().decode(AuthenticationCredential.self, from: request.body)
            guard let index = passkeys.firstIndex(where: { $0.id == submitted.id.asString() && $0.email == email }) else {
                return Self.jsonError("passkey_not_enrolled", status: 401)
            }
            let verified = try Self.manager(for: origin).finishAuthentication(credential: submitted, expectedChallenge: ceremony.1.challenge,
                credentialPublicKey: passkeys[index].publicKey, credentialCurrentSignCount: passkeys[index].signCount, requireUserVerification: true)
            let previous = passkeys[index].signCount
            passkeys[index].signCount = max(previous, verified.newSignCount)
            do { try Self.savePasskeys(passkeys) }
            catch { passkeys[index].signCount = previous; return Self.jsonError("passkey_store_unavailable", status: 503) }
            return createSession(email: email)
        } catch { return Self.jsonError("passkey_authentication_failed", status: 401) }
    }

    private func startCeremony<T: Encodable>(_ kind: Ceremony.Kind, email: String, challenge: [UInt8], body: T) -> WitnessWebResponse {
        do {
            let id = try Self.randomToken()
            ceremonies[id] = Ceremony(kind: kind, email: email, challenge: challenge, expires: Date().addingTimeInterval(120))
            return Self.json(body, headers: ["Set-Cookie": Self.cookie("ruru_ceremony", value: id, age: 120)])
        } catch { return Self.jsonError("ceremony_unavailable", status: 503) }
    }

    private func createSession(email: String) -> WitnessWebResponse {
        do {
            let id = try Self.randomToken(), csrf = try Self.randomToken()
            sessions[id] = Session(email: email, csrf: csrf, expires: Date().addingTimeInterval(8 * 60 * 60))
            return Self.json(AuthenticationResult(authenticated: true, csrf: csrf),
                             headers: ["Set-Cookie": Self.cookie("ruru_session", value: id, age: 8 * 60 * 60)])
        } catch { return Self.jsonError("session_unavailable", status: 503) }
    }

    private func ceremony(for request: WitnessWebRequest, kind: Ceremony.Kind, email: String) -> (String, Ceremony)? {
        guard let id = Self.cookie(named: "ruru_ceremony", from: request.headers["cookie"]), let ceremony = ceremonies[id],
              ceremony.kind == kind, ceremony.email == email, ceremony.expires > Date() else { return nil }
        return (id, ceremony)
    }

    private func session(for request: WitnessWebRequest, email: String) -> Session? {
        guard let id = Self.cookie(named: "ruru_session", from: request.headers["cookie"]), let session = sessions[id],
              session.email == email, session.expires > Date() else { return nil }
        return session
    }

    private func role(for email: String) -> OperatorRole? {
        passkeys.first(where: { $0.email == email })?.role
    }

    private func prune() {
        let now = Date()
        ceremonies = ceremonies.filter { $0.value.expires > now }
        sessions = sessions.filter { $0.value.expires > now }
        if (enrollment?.expires ?? .distantPast) <= now { enrollment = nil }
    }

    private static func manager(for origin: String) -> WebAuthnManager {
        let host = URL(string: origin)?.host ?? "invalid.local"
        return .init(configuration: .init(relyingPartyID: host, relyingPartyName: "Ruru", relyingPartyOrigin: origin))
    }

    private static func accessEmail(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), value.utf8.count <= 254,
              value.contains("@"), !value.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return value.lowercased()
    }

    private static func cookie(named name: String, from header: String?) -> String? {
        header?.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix(name + "=") }
            .map { String($0.dropFirst(name.count + 1)) }
    }

    private static func cookie(_ name: String, value: String, age: Int) -> String {
        "\(name)=\(value); Max-Age=\(age); Path=/; Secure; HttpOnly; SameSite=Strict"
    }

    private static func randomToken() throws -> String {
        Data(try randomBytes()).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    private static func randomBytes() throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw WebUIError.randomUnavailable }
        return bytes
    }
    private static func base64URLBytes(_ value: String) -> [UInt8]? {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64).map(Array.init)
    }

    private static func loadPasskeys() throws -> [Passkey] {
        guard let text = try WitnessKeychain.read("web-ui-passkeys") else { return [] }
        var records = try JSONDecoder().decode([Passkey].self, from: Data(text.utf8))
        guard records.count <= 8, Set(records.map(\.email)).count == records.count,
              records.allSatisfy({ !$0.id.isEmpty && !$0.publicKey.isEmpty && accessEmail($0.email) == $0.email }) else {
            throw WebUIError.passkeyStoreInvalid
        }
        // One-owner invariant also migrates the old single-operator schema.
        if !records.isEmpty && !records.contains(where: { $0.role == .owner }) { records[0].role = .owner }
        guard records.filter({ $0.role == .owner }).count <= 1 else { throw WebUIError.passkeyStoreInvalid }
        return records
    }

    private static func savePasskeys(_ records: [Passkey]) throws {
        let data = try JSONEncoder().encode(records)
        guard let text = String(data: data, encoding: .utf8) else { throw WebUIError.passkeyStoreInvalid }
        try WitnessKeychain.save(text, account: "web-ui-passkeys")
    }

    private static func json<T: Encodable>(_ body: T, headers: [String: String] = [:]) -> WitnessWebResponse {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(body) else { return jsonError("encoding_failed", status: 500) }
        return .init(contentType: "application/json; charset=utf-8", body: data, headers: headers)
    }
    private static func jsonError(_ code: String, status: Int) -> WitnessWebResponse {
        .init(status: status, contentType: "application/json; charset=utf-8", body: (try? JSONEncoder().encode(["error": code])) ?? Data())
    }
    private static func html(_ value: String) -> WitnessWebResponse {
        .init(contentType: "text/html; charset=utf-8", body: Data(value.utf8), headers: ["Content-Security-Policy": "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"])
    }

    /// The app's owl artwork (the Icon Composer layer), bundled as a resource.
    private static let owlPNG: Data? = Bundle.main.url(forResource: "ruru-owl", withExtension: "png")
        .flatMap { try? Data(contentsOf: $0) }

    private static func stylesheet(_ value: String) -> WitnessWebResponse {
        .init(contentType: "text/css; charset=utf-8", body: Data(value.utf8), headers: ["Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'"])
    }

    private static func javascript(_ value: String) -> WitnessWebResponse {
        .init(contentType: "text/javascript; charset=utf-8", body: Data(value.utf8), headers: ["Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'"])
    }

    enum WebUIError: LocalizedError { case randomUnavailable, tooManyOperators, firstOperatorAlreadyEnrolled, passkeyStoreInvalid
        var errorDescription: String? { "Web UI enrolment is unavailable." }
    }
}
