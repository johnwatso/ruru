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
    typealias MonitorSnapshot = @Sendable () async -> [MonitorTarget]
    typealias MonitorSave = @Sendable (MonitorTarget) async throws -> Void
    typealias MonitorRemove = @Sendable (String) async throws -> Void
    typealias MonitorCheck = @Sendable (String) async -> Void

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

    init(origin: @escaping OriginProvider, monitorSnapshot: @escaping MonitorSnapshot,
         monitorSave: @escaping MonitorSave, monitorRemove: @escaping MonitorRemove,
         monitorCheck: @escaping MonitorCheck) {
        self.origin = origin
        self.monitorSnapshot = monitorSnapshot
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
        guard let origin = await origin() else { return Self.jsonError("web_ui_unavailable", status: 503) }
        guard !passkeyStoreUnavailable else { return Self.jsonError("passkey_store_unavailable", status: 503) }
        guard let email = Self.accessEmail(request.headers["cf-access-authenticated-user-email"]) else {
            return Self.jsonError("cloudflare_access_required", status: 401)
        }
        prune()
        switch (request.method, request.path) {
        case ("GET", "/"):
            return Self.html(Self.page)
        case ("GET", "/web/app.js"):
            return Self.javascript(Self.script)
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
        case ("GET", "/api/web/monitors"):
            return Self.json(await monitorSnapshot())
        case ("POST", "/api/web/monitors"):
            guard request.headers["x-ruru-csrf"] == session.csrf else { return Self.jsonError("csrf_required", status: 403) }
            do {
                let target = try JSONDecoder().decode(MonitorTarget.self, from: request.body)
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
        guard let data = try? encoder.encode(body) else { return jsonError("encoding_failed", status: 500) }
        return .init(contentType: "application/json; charset=utf-8", body: data, headers: headers)
    }
    private static func jsonError(_ code: String, status: Int) -> WitnessWebResponse {
        .init(status: status, contentType: "application/json; charset=utf-8", body: Data("{\"error\":\"\(code)\"}".utf8))
    }
    private static func html(_ value: String) -> WitnessWebResponse {
        .init(contentType: "text/html; charset=utf-8", body: Data(value.utf8), headers: ["Content-Security-Policy": "default-src 'self'; script-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"])
    }

    private static func javascript(_ value: String) -> WitnessWebResponse {
        .init(contentType: "text/javascript; charset=utf-8", body: Data(value.utf8), headers: ["Content-Security-Policy": "default-src 'none'; base-uri 'none'; frame-ancestors 'none'"])
    }

    enum WebUIError: LocalizedError { case randomUnavailable, tooManyOperators, firstOperatorAlreadyEnrolled, passkeyStoreInvalid
        var errorDescription: String? { "Web UI enrolment is unavailable." }
    }

    private static let page = #"""
    <!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
    <title>Ruru</title><style>body{margin:0;background:#11151c;color:#eef2f7;font:16px -apple-system,sans-serif}main{max-width:720px;margin:10vh auto;padding:28px}button,input{font:inherit;padding:10px;border-radius:8px;border:1px solid #4b5563}button{background:#5c8dff;color:white}li{padding:10px;margin:8px 0;background:#1b2430;border-radius:8px}.muted{color:#aab4c2}</style>
    <main><h1>Ruru</h1><p class=muted id=message>Checking secure access…</p><section id=login hidden><button id=signIn>Use passkey</button><p>First operator? Enter the one-time enrolment code displayed in Ruru’s native console. Invited operators must use the code their owner shared.</p><input id=code autocomplete=one-time-code placeholder="Enrolment code"><button id=enrol>Register passkey</button></section><section id=console hidden><h2>Monitors</h2><p class=muted>Checks are bounded and observational; they never affect lease ownership.</p><form id=add><input id=name required placeholder="Name"><select id=kind><option value=HTTP>HTTP(S)</option><option value=TCP>TCP</option><option value=DNS>DNS</option></select><input id=address required placeholder="https://status.example.com"><input id=port type=number value=443 min=1 max=65535><button>Add monitor</button></form><ul id=monitors></ul><section id=operators hidden><h2>Operators</h2><p class=muted>Invitees must also be admitted by the Cloudflare Access policy for this hostname. A notification email verification alone does not grant Ruru access.</p><form id=invite><input id=operatorEmail required type=email placeholder="admin@example.com"><button>Invite operator</button></form><p class=muted id=inviteResult></p><ul id=operatorList></ul></section></section></main>
    <script src="/web/app.js"></script>
    """#

    private static let script = #"""
    let csrf='';const b64=b=>Uint8Array.from(atob(b.replace(/-/g,'+').replace(/_/g,'/').padEnd(Math.ceil(b.length/4)*4,'=')),c=>c.charCodeAt(0));const enc=b=>btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');
    const adapt=o=>{o.challenge=b64(o.challenge);if(o.user)o.user.id=b64(o.user.id);for(const c of o.allowCredentials||[])c.id=b64(c.id);for(const c of o.excludeCredentials||[])c.id=b64(c.id);return o};
    const credential=c=>({id:c.id,rawId:enc(c.rawId),type:c.type,response:Object.fromEntries(['clientDataJSON','attestationObject','authenticatorData','signature','userHandle'].filter(k=>c.response[k]).map(k=>[k,enc(c.response[k])])),authenticatorAttachment:c.authenticatorAttachment});
    async function api(path,opts={}){let r=await fetch(path,{credentials:'same-origin',...opts});let j=await r.json();if(!r.ok)throw Error(j.error||'request_failed');return j}
    async function authenticate(register){let path=register?'registration':'authentication',opts=register?{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({code:document.querySelector('#code').value)}:{};let o=adapt(await api('/api/web/passkeys/'+path+'/options',opts));let c=register?await navigator.credentials.create({publicKey:o}):await navigator.credentials.get({publicKey:o});let done=await api('/api/web/passkeys/'+path+'/finish',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(credential(c))});csrf=done.csrf;await show()}
    async function show(){let monitors=await api('/api/web/monitors');document.querySelector('#login').hidden=true;document.querySelector('#console').hidden=false;document.querySelector('#message').textContent='Signed in with Cloudflare Access and a passkey.';document.querySelector('#monitors').replaceChildren(...monitors.map(m=>Object.assign(document.createElement('li'),{textContent:m.name+' · '+m.kind+' · '+(m.kind==='HTTP'?m.url:(m.host+':'+m.port))+(m.enabled?'':' · paused')})));try{let operators=await api('/api/web/operators');document.querySelector('#operators').hidden=false;document.querySelector('#operatorList').replaceChildren(...operators.map(o=>Object.assign(document.createElement('li'),{textContent:o.email+' · '+o.role})))}catch(e){document.querySelector('#operators').hidden=true}}
    document.querySelector('#signIn').onclick=()=>authenticate(false).catch(e=>document.querySelector('#message').textContent=e.message);document.querySelector('#enrol').onclick=()=>authenticate(true).catch(e=>document.querySelector('#message').textContent=e.message);
    document.querySelector('#add').onsubmit=e=>{e.preventDefault();let kind=document.querySelector('#kind').value,address=document.querySelector('#address').value,port=Number(document.querySelector('#port').value),target={id:crypto.randomUUID(),name:document.querySelector('#name').value,kind,host:kind==='HTTP'?'':address,port:kind==='HTTP'?0:port,url:kind==='HTTP'?address:'',dnsQueryName:kind==='DNS'?'example.com':'example.com',intervalSeconds:60,timeoutSeconds:10,failureThreshold:3,enabled:true,needsAttention:false};api('/api/web/monitors',{method:'POST',headers:{'Content-Type':'application/json','X-Ruru-CSRF':csrf},body:JSON.stringify(target)}).then(show).catch(x=>document.querySelector('#message').textContent=x.message)};
    document.querySelector('#invite').onsubmit=e=>{e.preventDefault();api('/api/web/operators/invitations',{method:'POST',headers:{'Content-Type':'application/json','X-Ruru-CSRF':csrf},body:JSON.stringify({email:document.querySelector('#operatorEmail').value})}).then(i=>{document.querySelector('#inviteResult').textContent='Share this one-time code privately with '+i.email+': '+i.code+' (expires '+new Date(i.expiresAt).toLocaleTimeString()+'). They must sign in via Cloudflare Access as that same email.';document.querySelector('#operatorEmail').value=''}).catch(x=>document.querySelector('#inviteResult').textContent=x.message)};
    api('/api/web/status').then(s=>{document.querySelector('#message').textContent=s.passkeyEnrolled?'Use your passkey to open the console.':'A native one-time enrolment code is required to register the first passkey.';document.querySelector('#login').hidden=false}).catch(e=>document.querySelector('#message').textContent=e.message);
    """
}
