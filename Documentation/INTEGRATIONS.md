# Integrating an app

Ruru coordinates exclusive ownership for any app that runs on more than one
server: one owner per service at a time, with terms that only go up. SwiftBot
was the first app to use it and has a built-in template (its icon and pairing
instructions), but every service is configured the same way and nothing in the
protocol is SwiftBot-specific.

Lease guarding controls exclusive work; participant reports independently show
recent contact, including servers in standby.

## Operational status (v1)

`operationalStatus` is a separate, feature-detected diagnostic capability for a
node to report application readiness. It has no effect on a lease, presence,
Preferred Primary, or Ruru's authority health. Reports are authenticated with
the service token, bounded to 32 nodes and 16 components per node, fresh for
45 seconds, and expire after 10 minutes or a Ruru restart. Ruru stores no
free-form detail in this channel.

POST `/v1/operational-status/report` with the normal bearer token:

```json
{"version":1,"clusterID":"example","nodeID":"stable-node-id","state":"degraded","components":[{"namespace":"example","id":"sync","state":"degraded","reasonCode":"peer_unreachable"}]}
```

`namespace`, `id`, and optional `reasonCode` are ASCII machine codes (letters,
digits, `.`, `_`, `-`), not user-provided prose. Clients must call
`describe()` and use `supports("operationalStatus")` before reporting so older
authorities remain compatible. The typed `RuruLeaseClient.reportOperationalStatus`
method is the supported Swift integration boundary.

## Register a service

In **Guarding → Add Service**, choose a template (SwiftBot or Other app), a
name, a unique cluster ID and a lease length (10 seconds to 5 minutes). The
SwiftBot template starts at five minutes; Other app starts at 30 seconds.
Existing services keep their saved duration. A fresh Ruru starts with no services. Open the service's
**Connection Details** and give every participating server the endpoint,
cluster ID and bearer token. The token authorizes only that service. Up to 32
services share one authority, database and optional HTTPS tunnel, each with an
independent owner and term.

SwiftBot uses **SwiftMesh → Recovery and Pairing**. "Other app" is a generic
lease integration; it does not imply an adapter for any named application. A
service token trusts every node within that service, so pair only intended
participants; it does not authenticate a node or replace an application's own
membership and transport security.

## Pair with a code

Instead of copying the token, an operator can open a service's **Connection
Details → Pair a Server → Create Code**. Ruru shows a single-use code such as
`7KQ4-M2XP` that expires after 10 minutes. On the server:

```swift
let configuration = try await RuruPairing.pair(
    endpoint: URL(string: "https://ruru.example.com")!,
    code: "7KQ4-M2XP", nodeID: stableNodeID, nodeName: "Studio Mac")
// Save configuration.token in Keychain, then use RuruLeaseClient.
```

Over HTTP: `POST /v1/pair` with `{"code","nodeID","nodeName"}` (no bearer
token) uses the code up and returns 202 `{"pairingID","status":"pending"}`.
Poll `POST /v1/pair/status` with `{"pairingID"}`: 202 while pending; 200
`{"status":"approved","clusterID","token","leaseSeconds"}` exactly once after
the operator clicks **Approve** in Ruru; 403 if rejected; 410 if expired. A
wrong, used or expired code returns 404; ten wrong codes in a minute pause
pairing (429) for a minute. Nothing is released without approval, codes and
requests live only in memory (a restart cancels them), and removing a service
cancels its codes and requests. Ruru notifies the operator of each request.

## Rotate a credential (pull)

`GET /v1/service` reports `credentialRotation: true` when Ruru supports
`POST /v1/credential/rotate` (body `{"clusterID"}`), and
`credentialRotationPending: true` when the token you presented has been
replaced. Two cases:

- **Paired server (its own node token).** Calling rotate issues a new token for
  that node only; at most one per minute. The old token keeps working for 15
  minutes, so a lost response can be retried and returns the same new token.
- **Shared service token.** An operator rotates the service key in Ruru's
  Connection Details and picks how long the old key stays valid (15 minutes,
  1 hour or 24 hours). During that time the old token still works and calling
  rotate returns the new one. Without a pending rotation it returns 409
  `no_rotation_pending`; a caller can never mint a token on its own.

Save the new token to Keychain **before** using it. Ruru never pushes a token;
the client pulls it. Ending the grace early, or letting it lapse, makes the old
token return 401, and a server that missed the window must be paired again or
given the new token by hand. Ownership, terms and history are unaffected.
Restarting Ruru keeps unexpired grace periods.

```swift
let client = RuruLeaseClient(configuration: configuration)
if let fresh = try await client.collectPendingCredential() {
    try keychain.save(fresh.token)           // persist first
    configuration.token = fresh.token        // then switch clients
}
```

## Use RuruClient (Swift)

[`RuruClient`](../Clients/RuruClient) is the supported small Swift package
 (macOS 13+, iOS 16+) that implements the client rules below. Its public
manifest lives at the Ruru repository root, so add the Ruru repository as a
local or git package dependency and select the `RuruClient` library product.
Do not point SwiftPM at `Clients/RuruClient`: remote SwiftPM dependencies can
resolve only a repository-root `Package.swift`.

```swift
import RuruClient

let client = RuruLeaseClient(configuration: .init(
    endpoint: URL(string: "https://ruru.example.com")!,
    clusterID: "media-server", nodeID: stableNodeID, nodeName: "Studio Mac",
    token: tokenFromKeychain))

let ownership = Task {
    await client.maintain { state in
        switch state {
        case .owner(let lease): await worker.start(fencedBy: lease.term, until: lease.deadline)
        case .standby, .unavailable: await worker.stop()
        }
    }
}
// Cancelling awaits the standby callback (stop/drain), then releases the lease.
```

`maintain` renews at a third of the lease, measures deadlines from when each
request was sent with a stopping margin (10%, capped at two seconds), interrupts
stalled renewals at the local deadline, and rejects grants that arrive expired.
On cancellation it awaits a `.standby` callback before releasing. Callbacks must
return promptly; the worker must check the deadline independently before every
side effect, and stop/drain before its standby callback returns. A delayed
callback or suspended process cannot be made safe by a timer alone.
`acquire`, `renew`, `release` and
`describe` are available for apps that run their own loop. For other languages,
see the [OpenAPI description](openapi.yaml) and the
[Python example](../Clients/examples/ruru_lease.py).

When an application persists the highest fencing term its protected resource
has accepted, use `acquire(minimumTerm:)` after the application's recovery. If
Ruru grants a lower term, RuruClient releases that temporary lease before
throwing `ownershipLost`; it never silently discards an acquired lease. If the
release request has a transport error, that error is returned because ownership
cannot be ruled out until the lease expires.

## Protocol

Send JSON over HTTPS with `Authorization: Bearer <service token>`:

```json
{"clusterID":"backup-worker","nodeID":"server-a","nodeName":"Worker Mac","term":0}
```

- `POST /v1/lease/acquire` grants ownership if there is no live owner, or
  confirms it for the current owner. Success returns `ownerNodeID`, `term` and
  `expiresInSeconds` (the granted remaining duration). An acquire retry does
  not extend the lease. When a configured duration is reduced, renewals retain
  earlier outstanding permission until it ages out. Send the highest term you
  have seen; Ruru never grants a lower one. 409 `ownership_held` means another
  server owns it: do not perform the guarded work.
- `POST /v1/lease/renew` uses the owner's stable node ID and granted term.
  Expired leases are never revived; 409 means ownership expired or changed.
- `POST /v1/lease/release` hands ownership back immediately. Success returns
  `{"released":true}`. Release never decreases the term.
- `GET /v1/service` describes the caller's service: `clusterID`, `leaseSeconds`,
  `recoverySeconds`, versioned `capabilities` (`lease`, `primaryPreference`,
  `coordination`, `participantPresence`, `operationalStatus`) and the current
  `lease` (owner, term, remaining seconds). `authorityVersion` and
  `authorityBuild` identify the running Ruru app release for diagnostics; they
  are not protocol compatibility numbers. Feature-detect from `capabilities`
  rather than assuming an app or protocol version. It is also a safe status
  endpoint for monitoring tools, scoped to one service's token.
- 503 `authority_recovering` means Ruru restarted (or was restored) and is
  waiting out every lease it could have granted. Retry after a short delay.
- 401 means a missing or wrong token; 403 means the token belongs to another
  service, or the cluster isn't configured.

`nodeName` is optional display metadata. Node IDs must be stable across
restarts and never derived from start order. Routine renewals are not logged.
Any number of servers can compete; there is one owner per service.

## Fencing: the rule that keeps leases safe

A lease alone can't stop a paused or partitioned server from finishing a write
after its lease ended. The **term is a fencing token**:

1. Attach the current term to every side effect the owner performs (database
   writes, file publishes, messages to other systems).
2. The protected system stores the highest term it has accepted and rejects
   anything older, atomically with the change itself.
3. Also stop work at the **local deadline** (`RuruLease.deadline`): request send
   time plus `expiresInSeconds`, less a stopping/clock-rate margin, measured on
   a monotonic clock. A network timeout must never postpone this check.

Neither check is enough alone. See [fencing references](LEASE_REFERENCES.md)
and [storage limits](STORAGE.md), including the absence of exactly-once effects.

## When Ruru can't be reached

Ruru is a single authority on one Mac; it is not replicated. If it is down or
unreachable:

- The current owner keeps working only until its local deadline, then stops.
- No server gains ownership until Ruru is back. Exclusive work pauses rather
  than risking two owners. This is deliberate.
- Never infer ownership from another server being unreachable.
- After Ruru restarts it waits out the longest lease it granted (503
  `authority_recovering`), then grants again with higher terms.

Choose the lease length accordingly: shorter leases fail over faster after a
crash but need more frequent renewals and stop sooner if Ruru is briefly
unreachable. Ruru's own alerts (Settings → Alerts) can notify you, including via
Discord, when it or a service has a problem.

## Client conformance checklist

A client is correct when it:

- [ ] renews at no more than half the lease length (RuruClient uses a third);
- [ ] computes its deadline from when the request was sent, not received;
- [ ] reserves time for stopping work and modest clock-rate differences;
- [ ] rejects expired, malformed, decreasing-term or mismatched renewal grants;
- [ ] stops guarded work at the deadline if no renewal succeeded;
- [ ] treats 409 on renew as immediate loss of ownership;
- [ ] treats a grant naming another `ownerNodeID` as not owning;
- [ ] retries 503 `authority_recovering` and transport errors with jittered backoff;
- [ ] sends its highest seen term on acquire and fences side effects with it;
- [ ] stops/drains work before release, from a context that isn't already cancelled;
- [ ] keeps the token secret and never logs it.

`Tests/WitnessKitTests/ClientConformanceTests.swift` runs RuruClient against the
real server for these cases (single owner, rising terms, hand-over on release,
restart quarantine, wrong credentials).
`RuruClientSafetyTests.swift` injects stalled transport, delayed/invalid grants
and cancellation to verify deadlines and stop-before-release ordering. The Python
example uses a separate expiry thread so blocking HTTP cannot delay its stop
callback; its placeholder worker still requires per-effect deadline checks and
durable resource fencing. These clients cannot guarantee exactly-once effects.

## Preferred Primary

Each service can store a Preferred Primary, separate from its live owner. A
compatible client reads `POST /v1/service/policy` with its scoped bearer token
and `{"clusterID":"..."}`. Ruru returns a versioned preferred node ID and
revision. Reading or changing this intent never grants permission, blocks
failover or revokes a live lease. See [Preferred Primary](PRIMARY_PREFERENCE.md).

## What the console knows

Known Servers combines ownership history with authenticated participant reports.
An updated SwiftBot reports every 15 seconds, including while in standby. Past
ownership alone shows **Presence unknown**. Ruru keeps the last 256 transitions **per service**
(and shows the newest 64 per service), so a busy service can't hide another's
history. Alerts report a service as down when its owner stops renewing and
nobody takes over within 15 seconds. Contact reports do not prove application
health, synchronization, or readiness to take over.

### Participant presence v1

Feature-detect `participantPresence` version 1 in `GET /v1/service`. Send
`POST /v1/participants/report` every 15 seconds with the service bearer token:

```json
{"version":1,"clusterID":"swiftbot","nodeID":"stable-backup-id","nodeName":"Backup Mac","role":"standby","webUIURL":"https://failover.example.com","powerSource":"ups","externalPower":false,"batteryPercent":87,"batteryTimeRemaining":3600}
```

Roles are `active`, `standby`, `worker` or `unknown` and are self-reported; Ruru
always derives Current owner from the lease. A report neither acquires nor renews
a lease. Success: `{"version":1,"accepted":true,"freshSeconds":45,"reportAfterSeconds":15}`.
Missing/invalid credentials return 401, cross-service reports 403, invalid fields
400, unsupported versions 409, and capacity/admission overflow 429. Node IDs
must be nonempty, at most 128 UTF-8 bytes, without whitespace padding or control
characters; optional names have a 256-byte limit and no control characters.

`webUIURL` is optional: a credential-free HTTPS website origin, at most 256
UTF-8 bytes, with no path except `/`, query or fragment. Ruru normalizes host
case and the default port. Invalid addresses reject the report (400). Omit it
when the website is disabled or no public HTTPS address is configured; omission
clears the previous address. Older clients can continue omitting this field,
and older Ruru versions ignore it.

The optional `powerSource` (`ac`, `ups`, `battery` or `unknown`),
`externalPower`, `batteryPercent` (0–100) and `batteryTimeRemaining` (seconds,
at most seven days) fields report a local power snapshot. Omit unavailable
values; each new report replaces the prior snapshot, so omission clears an old
reading. Out-of-range numeric readings reject the report. These fields are
self-reported display telemetry, retained with the report's freshness age, and
do not affect ownership, lease deadlines or authority readiness. RuruClient
exposes them as optional `reportPresence` parameters.

`sessionEnding` is an optional, ephemeral indicator. SwiftBot sets it when
macOS requests logout or power-off; Ruru shows “Logout or shutdown requested”
while the participant report is fresh. SwiftBot then stops new work, drains
active work and releases its lease through the normal lease route. The notice
itself does not release or transfer ownership. If the drain cannot complete,
SwiftBot leaves the lease to expire. A later report without this field clears
the indicator.

Failover and recovery Discord embeds include a **Web UI** website link only from
the current lease owner's fresh report, matched by service and stable node ID.
The address is self-reported, never probed, and does not prove reachability or
readiness. A stale report loses its advertised URL; reports remain ephemeral.

Reports become stale at 45 seconds and expire at 600 seconds using monotonic
time. Up to 32 nodes per service (32 services total) are held in a separate
in-memory actor; restart starts empty, removal/token replacement clears reports.
The existing four-request metadata budget also covers participant traffic,
leaving the remaining listener capacity available for leases. Service tokens
authenticate a trusted group, not the individual claimed node ID. Public
`/health` and policy reads do not register participants.

RuruClient exposes `reportPresence(role:webUIURL:powerSource:externalPower:batteryPercent:batteryTimeRemaining:sessionEnding:)`; call it in a separate reporting loop
and check `describe().supports("participantPresence")` before using it. Old
clients retain lease compatibility; they cannot show standby presence until
updated. Updated SwiftBot feature-detects, rechecking once per minute, and ignores
presence failures independently of its ownership deadlines.

## Resource catalogue

Clients may opt into [resource catalogue v1](COORDINATION_API.md) independently
of lease acquisition. It reports generic resources and host locations with
configured HTTPS origins and expiring observations. Ruru does not store or
stream resources. See [Coordination](COORDINATION.md) for the architecture and
the [SwiftBot convention](COORDINATION_API.md#swiftbot-combined-recording-libraries)
as one example.

## Exposing Ruru publicly

Internet Access publishes Ruru through a Cloudflare tunnel. The listener accepts
32 connections at a time, each closed after 5 seconds, so a flood of requests
could crowd out genuine renewals. Add a Cloudflare **rate limiting rule** for the
Ruru hostname (for example, 120 requests per minute per IP, block for 1 minute)
and keep **Bot Fight Mode** off for it so servers' requests aren't challenged.
Size the limit to your servers: each owner renews about every lease ÷ 3 seconds.
