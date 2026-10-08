# Integrating an app

Ruru coordinates exclusive ownership for any app that runs on more than one
server: one owner per service at a time, with terms that only go up. SwiftBot
was the first app to use it and has a built-in template (its icon and pairing
instructions), but every service is configured the same way and nothing in the
protocol is SwiftBot-specific.

Lease guarding controls exclusive work; participant reports independently show
recent contact, including servers in standby.

## Register a service

In **Guarding → Add Service**, choose a template (SwiftBot or Other app), a
name, a unique cluster ID and a lease length (10 seconds to 5 minutes; 30
seconds by default). A fresh Ruru starts with no services. Open the service's
**Connection Details** and give every participating server the endpoint,
cluster ID and bearer token. The token authorizes only that service. Up to 32
services share one authority, database and optional HTTPS tunnel, each with an
independent owner and term.

SwiftBot uses **SwiftMesh → Recovery and Pairing**. "Other app" is a generic
lease integration; it does not imply an adapter for any named application.

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

## Use RuruClient (Swift)

[`Clients/RuruClient`](../Clients/RuruClient) is a small Swift package
(macOS 13+, iOS 16+) that implements the client rules below. Add it as a local
or git package dependency.

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
// Cancelling `ownership` releases the lease so another server takes over at once.
```

`maintain` renews at a third of the lease, measures deadlines from when each
request was sent, reports `.unavailable` no later than the local deadline if
renewals fail, and releases on cancellation. `acquire`, `renew`, `release` and
`describe` are available for apps that run their own loop. For other languages,
see the [OpenAPI description](openapi.yaml) and the
[Python example](../Clients/examples/ruru_lease.py).

## Protocol

Send JSON over HTTPS with `Authorization: Bearer <service token>`:

```json
{"clusterID":"backup-worker","nodeID":"server-a","nodeName":"Worker Mac","term":0}
```

- `POST /v1/lease/acquire` grants ownership if there is no live owner, or
  confirms it for the current owner. Success returns `ownerNodeID`, `term` and
  `expiresInSeconds` (the service's lease length). Send the highest term you
  have seen; Ruru never grants a lower one. 409 `ownership_held` means another
  server owns it: do not perform the guarded work.
- `POST /v1/lease/renew` uses the owner's stable node ID and granted term.
  Expired leases are never revived; 409 means ownership expired or changed.
- `POST /v1/lease/release` hands ownership back immediately. Success returns
  `{"released":true}`. Release never decreases the term.
- `GET /v1/service` describes the caller's service: `clusterID`, `leaseSeconds`,
  `recoverySeconds`, versioned `capabilities` (`lease`, `primaryPreference`,
  `coordination`, `participantPresence`) and the current `lease` (owner, term, remaining seconds).
  Feature-detect from `capabilities` rather than assuming a version. It is also
  a safe status endpoint for monitoring tools, scoped to one service's token.
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
   time plus `expiresInSeconds`, measured on a monotonic clock.

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
- [ ] stops guarded work at the deadline if no renewal succeeded;
- [ ] treats 409 on renew as immediate loss of ownership;
- [ ] treats a grant naming another `ownerNodeID` as not owning;
- [ ] retries 503 `authority_recovering` and transport errors with jittered backoff;
- [ ] sends its highest seen term on acquire and fences side effects with it;
- [ ] releases on clean shutdown, from a context that isn't already cancelled;
- [ ] keeps the token secret and never logs it.

`Tests/WitnessKitTests/ClientConformanceTests.swift` runs RuruClient against the
real server for these cases (single owner, rising terms, hand-over on release,
restart quarantine, wrong credentials).

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
{"version":1,"clusterID":"swiftbot","nodeID":"stable-backup-id","nodeName":"Backup Mac","role":"standby","webUIURL":"https://failover.example.com"}
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

RuruClient exposes `reportPresence(role:webUIURL:)`; call it in a separate reporting loop
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
