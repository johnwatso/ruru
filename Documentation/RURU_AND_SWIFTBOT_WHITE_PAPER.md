# Ruru and SwiftBot

## A white paper on independent lease authority, safe failover, and service coordination

**Status:** technical overview of the repository's current design and documented implementation direction.  
**Audience:** operators, application developers, reviewers, and AI assistants asked to reason about Ruru or SwiftBot.  
**Scope:** Ruru's relationship with SwiftBot, not a deployment guide or a claim that every future capability is already implemented.

## Executive summary

Ruru is a native macOS service coordinator whose first implemented capability is **lease guarding**: it decides which participating server is currently allowed to perform an exclusive activity for a configured service. SwiftBot, a Discord-bot application, is Ruru's first and most developed integration. It uses the same lease model Ruru exposes to any application, while retaining ownership of its bot logic, recordings, Discord actions, user experience, storage, and recovery workflow.

The most important architectural fact is that Ruru is **not a SwiftBot worker, bot process, plug-in, or Swift package root**. It is a separately deployed macOS app and authority. Ruru may run on a third Mac that both SwiftBot servers can reach. SwiftBot servers request, renew, and release permission through Ruru's documented HTTP protocol or the small application-neutral `RuruClient` Swift package.

This separation addresses a familiar failover hazard: after a network partition, sleep, crash, or delayed request, two servers can each believe they are entitled to act. Ruru grants one owner per service at a time and issues monotonically increasing lease terms. A correct client must stop its protected work at a locally computed deadline and fence every protected side effect with the granted term. The lease is therefore a permission boundary, not a mere health check or leader-election display.

Ruru is intentionally conservative when uncertain. If it cannot be reached, a current SwiftBot owner may continue only until its last locally confirmed lease expires; a standby cannot promote itself merely because the authority is unavailable. After a Ruru restart, the authority enters a full restart quarantine before issuing new grants. This favors exclusivity over uninterrupted availability.

Beyond lease guarding, Ruru is evolving toward a general, capability-based coordinator. Its initial coordination capabilities—participant presence, Preferred Primary policy, and an opt-in resource-location catalogue—are shared contracts. SwiftBot contributes application-specific behavior on top of them: it reports its own availability and Web UI address, can participate in deliberate primary preference, and can expose recording-library endpoints. Ruru carries metadata and operator policy; it never processes SwiftBot Discord work or proxies its media.

## 1. The problem Ruru solves

Running one logical service on multiple Macs creates an ownership problem. For SwiftBot, two installations may each be technically alive, yet only one should perform the bot's exclusive work. Simply checking whether a peer is reachable is unsafe: reachability is not proof that the peer has stopped, and a paused process can resume after its lease should have ended.

Ruru centralizes the decision about permission to act. For each explicitly configured service cluster, it maintains one durable sequence of ownership terms and permits at most one live owner. A term is a fencing token: a higher term supersedes every earlier one. The client must carry that token into its protected effects so an older owner cannot commit an action after it has lost authority.

This is deliberately different from a high-availability cluster that attempts to keep working through every authority outage. Ruru's current deployment preference is one authority on one independent Mac. When that authority is unavailable, exclusive work pauses after the current owner's lease ends rather than risking concurrent owners.

## 2. Relationship at a glance

```text
                        authority / coordination plane
  ┌─────────────────────────────────────────────────────────────────┐
  │ Ruru (separate native macOS app)                                │
  │                                                                 │
  │  durable lease terms • restart quarantine • service admission   │
  │  operator policy • bounded observations • alerts • UI           │
  └───────────────┬─────────────────────────────┬───────────────────┘
                  │ authenticated HTTPS          │ authenticated HTTPS
                  │ lease + capability protocol   │ lease + capability protocol
        ┌─────────▼─────────┐           ┌─────────▼─────────┐
        │ SwiftBot: Primary │           │ SwiftBot: Standby │
        │ bot/workload      │           │ bot/workload      │
        │ local storage     │           │ local storage     │
        │ media/web UI      │           │ media/web UI      │
        └───────────────────┘           └───────────────────┘
```

Ruru owns the authority decision. SwiftBot owns the work that is allowed or denied by that decision. The connection is an authenticated, versioned interface, not a shared runtime.

| Area | Ruru owns | SwiftBot owns |
| --- | --- | --- |
| Exclusive ownership | Grant, renewal, release, durable terms, restart quarantine | Asking for permission; stopping or starting guarded work according to the grant |
| Fencing | Supplying a monotonically increasing term | Applying the term to every relevant side effect and rejecting stale work locally/downstream |
| Service configuration | Cluster admission, per-service token, lease duration, operator-facing settings | Its SwiftMesh pairing/recovery UX and its app-specific configuration |
| Availability information | Bounded, self-reported participant observations and their freshness | Reporting its own role, optional Web UI origin, and optional session-ending state |
| Recording sharing | Opt-in generic catalogue of approved HTTPS locations | Its recording library, access rules, directory API, playback proxying, and media transfer |
| Operator experience | Native Ruru console, alerts, activity/history, Cloudflare connectivity setup | SwiftBot’s bot and recordings interfaces |

## 3. Independence is a safety boundary

Ruru has no source or project dependency on the SwiftBot repository. Its UI-free authority code lives in `WitnessKit`; its native SwiftUI application supplies the console, settings, credential handling, and optional Internet Access setup. SwiftBot is represented in Ruru as one service template and integration: the template provides familiar iconography and pairing guidance, not privileged semantics.

The core model is application-neutral:

- A **service** is an explicitly configured coordination group and permission scope.
- A **node** is a participating application instance with a stable identifier.
- A **capability** is a versioned function, such as lease ownership, presence reporting, or a resource catalogue.
- A **policy** is durable operator intent, separate from a lease and from a node's self-reported state.
- A **resource** and **location** describe application-owned content without turning Ruru into its host or transfer path.

Ruru can guard multiple services—up to 32 configured service clusters on its listener—each with a separate bearer token, owner, and term sequence. SwiftBot is the initial service, not the only supported one. A different application can use the same public lease contract, and a future coordination capability should not be coupled to Discord, recordings, or SwiftBot's internal configuration.

## 4. Lease guarding and failover semantics

### 4.1 Normal ownership lifecycle

The stable wire endpoints are:

- `POST /v1/lease/acquire`
- `POST /v1/lease/renew`
- `POST /v1/lease/release`

Requests identify `clusterID`, `nodeID`, and integer `term`; newer clients may also send an optional display-only `nodeName`. Successful acquisition or renewal returns an `ownerNodeID`, a term, and `expiresInSeconds`. The legacy SwiftBot JSON contract is preserved, including the original route names and fields.

A normal sequence is:

1. A SwiftBot instance acquires a lease for its configured service.
2. Ruru durably commits the new grant and its audit event before acknowledging it.
3. The owner starts or continues only its guarded work, fenced with the returned term.
4. The owner renews before the local deadline; the supported client renews at roughly one third of the lease duration.
5. A standby that receives `ownership_held` remains standby and does no guarded work.
6. On a planned handover, the owner stops and drains protected work before releasing; a new owner then acquires a later term.

Lease terms never decrease. An expired lease is never revived. A release does not decrease a term. A fresh acquisition after a handover receives a higher term even if the same node later becomes owner again.

### 4.2 Why lease expiry is not enough

Lease expiry limits how long a client may believe it owns the work. It cannot itself prevent a process that was paused, partitioned, or delayed from completing an external operation later. Correct integration requires two independent controls:

1. **Deadline discipline.** The client calculates a local monotonic deadline from the time it sent the successful lease request, reserves a stopping margin, and stops work by that deadline even if its renewal request is stuck.
2. **Fencing.** The protected resource or operation records the highest accepted term and atomically rejects effects carrying an older term. Typical examples are a database write, a file publication, or a downstream command that persists the highest term it has accepted.

Neither control substitutes for the other. A timer alone cannot stop a suspended process; a fencing token alone does not ensure timely work cessation. Also, Ruru cannot turn a non-fence-aware remote API—such as an already-submitted Discord request—into an exactly-once system. It protects permission to initiate work, not every possible external effect.

### 4.3 Failure behavior

If Ruru becomes unavailable, the current owner may work only until its last locally confirmed deadline. No standby may infer ownership from Ruru's outage, the peer's apparent failure, or a missed observation. This may cause a controlled service pause.

When Ruru restarts, it creates a new monotonic authority epoch and waits for the longest outstanding lease it had persisted before issuing grants again. During this quarantine it returns `503 authority_recovering`. It does not compare an old lease against a new process clock as though it remained live. Repeated restarts do not clear this wait. This is what avoids overlapping an old, possibly still-running owner with a newly granted one.

## 5. Durability, storage, and authority bounds

Ruru holds a lifetime file lock so one authority process owns one database. Lease state is stored in DuckDB through the official Swift package. A grant and its audit event are committed together; if the durable write fails, Ruru must not make the grant live in memory. Missing, corrupt, damaged, or otherwise unsafe authority storage fails closed rather than being silently replaced with an empty database.

The application deliberately does not migrate the historical SQLite authority into a fresh DuckDB store. Replacing a legacy authority requires an explicit operator workflow that stops and unpairs clients, archives the old storage, creates fresh terms and tokens, and requires re-pairing. Restoring an old ownership database in place is prohibited because it could reissue a term a client has already observed.

These guarantees are scoped. Ruru is currently a single authority, not a replicated consensus system. Its database memory budget, request sizes, concurrent connection admission, reports, and retained history are bounded to suit the intended older Intel Mac mini deployment. Production capacity, real WAN partitions, physical power failures, sleep/resume, and target Intel/Sequoia operation still require live validation.

## 6. How SwiftBot integrates

SwiftBot's relationship with Ruru is intentionally narrow at the authority boundary and rich at the application boundary.

### 6.1 Pairing and credentials

Ruru configures a SwiftBot service with a stable cluster ID, a per-service bearer token held in Keychain, and a chosen lease duration. SwiftBot can receive these through its existing **SwiftMesh → Recovery and Pairing** flow. Ruru also offers a single-use, operator-approved pairing-code protocol so an operator need not copy a long-lived bearer token directly.

The service token is scoped to one service cluster. It is not a Discord credential, a mesh transport credential, or a universal Ruru administrator credential. Ruru uses constant-time verification and keeps secrets in Keychain; it must not log bearer tokens.

### 6.2 Client integration

`RuruClient` is Ruru's supported public SwiftPM integration boundary. It is a small, application-neutral library for lease fencing, pairing, service/capability discovery, and participant-presence reporting. It deliberately has no SwiftUI, DuckDB, Cloudflare, or Ruru-app dependency.

SwiftBot has existing SwiftMesh client behavior and is the intended first adopter of the public package. Its dedicated migration to `RuruClient` is documented as following a published client release tag; SwiftBot-specific orchestration, persistence, and business logic stay within SwiftBot rather than migrating into the shared package. Older lease clients remain wire-compatible with the stable lease protocol.

### 6.3 Preferred Primary is not ownership

Ruru can store a per-service **Preferred Primary** node ID. It is an operator preference that compatible SwiftBot clients may read to guide an orderly return to a favored machine. It does not grant a lease, revoke a live owner, force a transfer, or prevent failover. The actual current owner is always determined by the lease.

This distinction prevents a configuration choice from being mistaken for safety proof. A Preferred Primary can be unavailable, and a non-preferred standby can still legitimately become lease owner when the live owner releases or expires.

### 6.4 Participant presence and safe visibility

Updated SwiftBot installations report participant presence approximately every 15 seconds, including while in standby. Reports can include a self-reported role, an optional credential-free HTTPS Web UI origin, and optional power/session-ending telemetry. Ruru displays these reports as observations with monotonic freshness and retention limits.

Presence does not acquire, renew, transfer, or prove a lease. A reported `active` role does not override the durable owner. A recent report does not prove that the participant can safely take over. On process restart, presence begins empty; stale or absent data is presented as unknown/stale rather than turned into a liveness conclusion.

For SwiftBot, a fresh Web UI origin from the node that actually holds the current lease can be included in failover or recovery alerts. Ruru does not probe that URL; it is a self-reported operator convenience link, not a reachability assertion.

### 6.5 Recording-library coordination

Ruru's resource catalogue is an opt-in, generic location directory. It allows a service's nodes to report bounded HTTPS resource endpoints under operator-approved origins. It does not move, inspect, stream, scan, or authorize media.

SwiftBot uses a deliberately small convention: each participating host can report a `swiftbot.recording-library.v1` resource location that points to its own recording-library API. A viewing SwiftBot instance then fetches libraries directly from participating hosts and applies its own access checks and presentation logic. Video, audio, thumbnails, and recording metadata do not transit Ruru.

The separation is important during failover. A SwiftBot server may serve its own recordings even while it is not the Discord bot's current owner, because reading a hosted library is not an exclusive lease action. Catalogue freshness describes only a recent report; it does not prove the location is healthy or reachable.

## 7. Security and operational model

Ruru's security model has several distinct scopes:

- **Service admission:** only explicitly configured service clusters are allowed to use the listener; a bearer token is scoped to one cluster.
- **Authority safety:** durable terms, lifetime locks, commit-before-acknowledgement, and restart quarantine protect lease semantics.
- **Transport exposure:** Ruru can operate locally or use user-initiated Cloudflare Tunnel setup for HTTPS Internet Access. The authority listener remains loopback for managed public access.
- **Observation safety:** participant reports and resource locations are bounded, authenticated within the service scope, and separate from lease authority.
- **Operator policy:** enabling a catalogue, approving an origin, or selecting a Preferred Primary is explicit, persisted intent. It is not granted by a node merely reporting information.

Ruru's HTTP listener has intentionally small limits: one request per connection, bounded headers/body, timeouts, and a limited number of coordination requests within the overall connection budget. The point is to preserve lease-renewal capacity and keep metadata capabilities from becoming a route to starve the authority.

Ruru's native console supplies service ownership, known-server observations, activity, pairing, settings, and alerts. Closing the window leaves the menu-bar service alive. Optional alerts can use macOS notifications and configured webhook destinations, but alerts are operational aids, not a replacement for clients honoring their local lease deadlines.

## 8. Compatibility and migration principles

Ruru preserves SwiftBot's established lease routes and JSON request/reply shape:

- `/v1/lease/acquire`, `/v1/lease/renew`, and `/v1/lease/release` remain the lease interface.
- `nodeName` is optional display data, so older clients remain valid.
- Ownership identity is the stable `nodeID` plus the term—not a server nickname, human-readable name, Web UI URL, or presence role.
- Capabilities are discovered explicitly. A client should feature-detect them rather than infer support from an application version.
- New coordination features do not change the lease schema or commit path, and failure of metadata functions should not make a healthy lease authority unavailable.

This allows Ruru to evolve without forcing every SwiftBot installation to upgrade at once. It also explains why Ruru does not special-case SwiftBot in its core protocol: compatibility and safety depend on stable generic contracts.

## 9. Implemented scope versus future direction

The design direction is a general service coordinator, not a promise that Ruru already schedules distributed work. The following distinction matters when discussing the project:

| Present or documented current capability | Explicitly outside the current implemented scope |
| --- | --- |
| Single-authority lease guarding with durable terms and restart quarantine | Replicated or multi-authority consensus |
| Per-service policy, presence observations, alerts, and bounded resource-location catalogue | Automatic application discovery and independent health probes |
| SwiftBot pairing, ownership integration, presence reporting, Web UI links, and recording-library endpoint convention | Ruru hosting, proxying, replicating, deleting, or retaining SwiftBot media |
| Explicit origin enrolment/approval for sharing | Trusting a node report as proof of readiness or reachability |
| A generic contract for future capabilities | Managed work assignment, routing, automatic replication, or exactly-once execution |

Any future operation capability needs its own authorization model, durable intent where appropriate, idempotency rules, bounded retries, fencing semantics, and observable outcomes. A lease alone cannot establish exactly-once distributed execution.

## 10. Evaluation and deployment guidance

For a first SwiftBot deployment, Ruru's documented preferred topology is one Ruru authority on an independent server and two or more SwiftBot participants. The SwiftBot service is intended to use a five-minute lease in that deployment. This is a trade-off: it tolerates a brief Ruru connectivity loss for the existing owner, but delays takeover after an owner failure and causes a full quarantine gap following an authority restart.

An evaluator should verify the following before treating the system as production-ready:

1. Every protected SwiftBot effect obeys its local deadline and is appropriately fenced, or is explicitly accepted as an unfenceable external effect.
2. Node IDs are stable and unique; display names are not used as identities.
3. Tokens remain in Keychain and never appear in diagnostics, logs, recordings, URLs, or source control.
4. The authority's DuckDB store, initialization marker, and lock are preserved across upgrades; no old snapshot is restored over a live authority.
5. Live two-Mac/WAN failover, authority restart quarantine, partition, suspend/resume, and power-loss behavior are tested in the intended environment.
6. Catalogue endpoints, if enabled, use exact approved HTTPS origins and SwiftBot applies its own access checks before serving or playing content.
7. Recovery procedures are rehearsed, including the deliberate pause that occurs when an authority cannot be reached.

The repository records successful automated builds and conformance tests for many protocol and safety cases. Those tests do not substitute for the remaining live-hardware, network, power, tunnel, Discord, and deployment exercises.

## 11. Glossary

**Authority:** The independently running Ruru process that grants exclusive permission for configured services.

**Lease:** A time-limited grant stating which node may perform a service's guarded work.

**Term / fencing token:** A strictly increasing number carried with protected effects to reject work from a former owner.

**Node ID:** A stable machine/application identity used for ownership and fencing decisions. It is not a display name.

**Restart quarantine:** The period after Ruru starts during which it refuses grants so an old owner cannot overlap a new one.

**Presence:** A bounded, self-reported observation about a participant; it does not establish ownership or readiness.

**Preferred Primary:** Operator intent for a compatible client to favor a node when practical; it is not a lease.

**Resource catalogue:** Ruru's optional generic directory of application-reported HTTPS locations; Ruru does not carry the content at those locations.

## 12. Instructions for an AI reader

When using this paper as context, preserve these conclusions:

1. Describe Ruru as a separate native macOS authority and capability-based coordinator, not as part of SwiftBot's runtime.
2. Describe SwiftBot as Ruru's first integration and a consumer of its generic contracts, not as the source of Ruru's authority semantics.
3. Do not equate presence, a Web UI link, a Preferred Primary setting, or catalogue membership with ownership.
4. Do not claim Ruru provides replicated consensus, automatic failover without client cooperation, exactly-once effects, media hosting, or proven remote health checks.
5. Treat lease expiry, local monotonic deadlines, fencing terms, durable commits, and restart quarantine as a single safety story. Omitting any part materially weakens the explanation.
6. Clearly label proposed coordination features—such as routing, replication, retention, and managed operations—as future work unless a later implementation and validation record says otherwise.

## Source documents

This paper synthesizes the repository's primary design documents. Consult them for normative implementation detail and current limits:

- [Architecture](ARCHITECTURE.md)
- [General coordination direction](COORDINATION.md)
- [Integration guide](INTEGRATIONS.md)
- [Coordination API](COORDINATION_API.md)
- [Ownership and storage](STORAGE.md)
- [RuruClient guide](../Clients/RuruClient/README.md)
- [Development log and validation limits](ROADMAP.md)
