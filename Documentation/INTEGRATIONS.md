# Integrating another app

Ruru primarily supports SwiftBot and also admits other applications that use
its ownership protocol. This is lease guarding, rather than passive uptime
monitoring or automatic service discovery.

## Register a service

In **Guarding → Add Service**, choose an application kind, service name and a
unique cluster ID. Open that service’s **Connection Details** and configure all
its participating servers with the endpoint, cluster ID and bearer token.
The token authorizes only this service. A separate service can have an owner at
the same time; its ownership term is independent. Up to 32 services share one
authority listener, persistent database and optional HTTPS tunnel.

SwiftBot uses **SwiftMesh → Recovery and Pairing**. Existing SwiftBot pairing,
cluster identity and credentials are preserved. “Other app” is a generic lease
integration: it does not imply a built-in adapter for any named application.

## Client contract

Send JSON over HTTPS with `Authorization: Bearer <service token>`:

```json
{"clusterID":"backup-worker","nodeID":"server-a","nodeName":"Worker Mac","term":0}
```

- `POST /v1/lease/acquire` obtains permission if there is no live owner. Success
  returns `ownerNodeID`, `term` and `expiresInSeconds`. Competing servers receive
  409; they must not perform the guarded work.
- `POST /v1/lease/renew` uses the current owner’s stable node ID and granted term.
  Expired leases cannot be revived. A successful renewal extends permission;
  409 means ownership expired or changed.
- `POST /v1/lease/release` uses that same node ID and term. Success returns
  `{"released":true}`. Release never decreases the term.

`nodeName` is optional cosmetic metadata. Nodes use stable IDs across restarts.
Routine renewals are not written to the activity log. There is no two-server
limit: any number of participants can compete, with one owner per service.

Leases last 30 seconds. Renew well before expiry; SwiftBot renews every five
seconds. Set an earlier **local monotonic deadline**, accounting conservatively
for request latency and a safety margin. Stop guarded output by that deadline
unless renewal succeeds. On failure, recovery (503), or loss of the authority,
never infer ownership from another server being unreachable. See [storage and
fencing limits](STORAGE.md), especially the absence of exactly-once external
effects and the full restart quarantine.

A service token used for another configured cluster is rejected with 403. An
unknown cluster is also rejected. Missing/incorrect credentials receive 401.
`GET /health` reports only the readiness of the authority, without exposing
service names, server IDs or credentials.

## What the console knows

Known Servers comes from successful ownership history and the last stored
owner. Past participation is not proof of current uptime, and a standby server
that never held ownership may not appear. Activity retains the last 256
transitions across services. Probes, alerting, standby heartbeats and service
adapters beyond SwiftBot are not implemented yet.
