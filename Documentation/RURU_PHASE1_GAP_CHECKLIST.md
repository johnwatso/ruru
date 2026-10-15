# Ruru phase-one protocol gap checklist

This is a source-based planning note for the first Ruru expansion discussed in
SwiftBot. It distinguishes already-shipped coordination primitives from actual
gaps; it does not authorize or implement protocol changes by itself. The aim is
to avoid rebuilding lease behavior that Ruru and `RuruClient` already provide.

Phase-one validation on 2026-10-13: the Xcode `Ruru` scheme passed the focused
`RuruClientSafetyTests` (7 tests) and the `PairingTests`, `WitnessHTTPTests`,
and `ClientConformanceTests` suites (28 tests). This validates the existing
service-token pairing, authorization boundaries, and lease lifecycle; it does
not add per-node authentication or replace SwiftBot's peer data plane.

## Existing foundations

- **Exclusive ownership and fencing:** `/v1/lease/acquire|renew|release`,
  `/v1/service`, monotonic terms, persisted lease state, restart quarantine,
  and preferred-primary intent are implemented. Preferred-primary is not a
  grant or promotion command.
- **Safe client lifecycle:** `RuruLeaseClient` handles acquire/renew/release,
  minimum-term acquisition (releasing an insufficient grant before reporting
  loss), monotonic local deadlines, stop-before-release cancellation,
  malformed or expired grants, and transport stalls. Integrations still must
  stop side effects at the deadline and fence the protected resource with the
  term.
- **Enrollment and service credentials:** one-time codes, operator approval,
  expiry/rejection, and one-time delivery are implemented. The delivered
  credential is currently the service bearer token, not an independently
  revocable per-node identity.
- **Observation:** participant presence and roles are bounded, expiring,
  self-reported, and explicitly separate from ownership. A service token
  authenticates the group; the reported `nodeID` is not authenticated.
- **Capability discovery and metadata:** service capability discovery,
  coordination catalogue, origin enrollment, and an application-neutral
  `RuruClient` package exist. Resource routing, config replication, and managed
  job dispatch do not.

See [Integrations](INTEGRATIONS.md), [General coordination direction](COORDINATION.md),
[Coordination API](COORDINATION_API.md), and the implementations in
`Sources/WitnessKit/LeaseStore.swift`, `Pairing.swift`, `ParticipantPresence.swift`,
and `Clients/RuruClient`.

## Gaps and decisions

A concrete fresh-pairing proposal is in
[Individual server credentials](SERVER_IDENTITY.md). It includes the SwiftMesh
pairing change needed to avoid copying one server's credential to another.
The operator accepts re-pairing every Mac; no mixed-admission period or token
migration is planned. Existing lease state and public client contracts remain
protected.
The proposal is not an implemented authentication capability.

| Area | Current gap | Phase-one action / decision |
| --- | --- | --- |
| Node membership and trust | No durable authoritative node registry; presence is an ephemeral observation. Pairing delivers a shared service token, so a trusted participant can report another node ID. | Implement and review the proposed node-bound credentials, independent pairing and revocation as a separate security change. Adoption requires fresh pairing and refuses old shared client tokens; no mixed-mode migration is needed. Preserve lease state and public client compatibility with older authorities. |
| Desired roles and readiness | Preferred Primary stores operator intent; participant role is self-reported. Neither establishes readiness or permits promotion. | Preserve this separation. If readiness is needed, define an app-owned readiness report and show it as observed/untrusted input; Ruru must not turn it into lease authority implicitly. |
| Ownership lifecycle | Core APIs and client state machine already exist. App-specific drain/readiness and side-effect fencing remain the integrator's responsibility. | No new generic lease route indicated. Validate SwiftBot's stop/drain-before-release behavior and fencing obligations as part of migration; only extend RuruClient for a demonstrated reusable gap. |
| Failure semantics | Single authority by design. Authority outage pauses guarded work after the local deadline; no quorum or automatic authority failover. | Keep the single-authority model for this phase. Document/test outage, restart quarantine, expired lease, process recovery, and stale-term rejection. Treat replicated Ruru authority as a separate project. |
| Configuration sync | No general config replication contract. Catalogue and presence are observations, not desired-state replication. | Out of phase one. Later, define allowlisted/versioned config, ownership, conflict, rollback, secret exclusion, and authorization separately from lease storage. |
| Managed work/offload | No task claim/dispatch/heartbeat/cancel/result API. | Future phase: first decide whether Ruru owns scheduling metadata only. Define idempotency, retries, cancellation, worker capability, task fencing, result durability, and payload/data-plane boundaries before implementing endpoints. |
| Public ingress | Web UI origins are reported metadata; catalogue origins are allowlist policy. Ruru does not proxy or route application traffic. | Keep tunnel/ingress ownership separate; do not infer it from presence or catalogue enrollment. |

## Recommended first implementation slice

1. **Do not duplicate the lease protocol.** Make a SwiftBot migration checklist
   against the existing `RuruClient` conformance/safety suite and the app's
   lifecycle hooks. Add tests only where the integration exposes a concrete
   gap (especially drain, process restart, and stale-term side effects).
2. **Resolve the identity decision before protocol work.** If per-node
   authentication is required, write a focused proposal for credential
   lifecycle and compatibility with current service tokens. Otherwise record
   service-scoped trust as an explicit boundary and do not build a registry
   that merely duplicates presence.
3. **Keep scheduling and replication as separate designs.** They have different
   durability, authorization, data-volume, and failure requirements from
   ownership. Do not add placeholder routes or schemas ahead of a client use
   case.

## Acceptance checks before replacing SwiftBot transport

- Existing and older lease clients remain compatible; unsupported optional
  capabilities are feature-detected.
- At most one node performs fenced work; the protected resource rejects stale
  terms atomically with each side effect.
- The client stops by its monotonic local deadline even if renewal is stalled;
  planned handback drains before release.
- Ruru restart/recovery, authority outage, network partition, and client restart
  are covered by deterministic conformance tests; outage never implies
  promotion.
- Identity and token scope are explicit: either per-node revocation is tested,
  or group-token trust is documented and accepted for the first migration.
- Presence, preferred-primary intent, resource catalogue, and any future
  readiness signal cannot grant ownership or authorize work.
- No configuration secrets, user tokens, media, or job payloads are copied
  into generic coordination metadata.
