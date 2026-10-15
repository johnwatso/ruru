# Individual server credentials — fresh-pairing design

Status: proposed, not implemented. Existing pairings still use a shared service
token. This design addresses independent server revocation without changing
lease grants, fencing terms, expiry or restart quarantine.

Adoption decision: this is a single-operator deployment. Require fresh pairing
of each existing SwiftBot Mac instead of building token migration, mixed
admission or per-server migration tracking. This document does not change any
running credentials or production storage.

## Current operator boundary

Pair only servers trusted to act within the entire service. A reported node ID
is not an authenticated identity. Removing a service denies admission to the
whole group; removing a remembered server name or resource origin does not
revoke its token. Ruru currently cannot revoke one paired server independently.
Do not present observed participants as an authoritative membership list.

If a server is compromised, stop affected clients and use a deliberate service
credential replacement and re-pairing procedure. Do not assume deleting that
server from a display revokes access, or that revocation cancels an outstanding
lease before its client's local deadline.

## Proposed contract

- Advertise a new optional `nodeCredentials` capability, version 1, through
  authenticated service discovery. Keep all current lease JSON and public
  `RuruClient` APIs source-compatible. Version the credential contract separately
  from the unchanged lease protocol; do not silently reinterpret old tokens.
- Each client obtains its own individual credential during fresh pairing.
  Local approval binds a generated credential to the service metadata ID,
  protocol cluster ID and stable node ID. The credential is a random bearer
  secret with at least 256 bits of entropy, delivered once through pairing.
  The client stores it in Keychain. The result identifies its credential kind
  and version. Older pairing responses remain decodable by the public client,
  but a legacy service token is not accepted by the new admission policy.
- Every authenticated route resolves a principal first. A node credential
  admits only its own node ID for acquire, renew, release, presence, readiness,
  catalogue reports and origin proposals. Discovery and catalogue reads remain
  service-scoped. An omitted/mismatched node ID is rejected before mutation.
  Matching a display name never authenticates a node.
- `RuruClient` gains typed credential-kind metadata and an opt-in pairing API;
  existing initializers and legacy pairing retain their public contract when
  talking to an older authority. This does not promise old credentials will
  authenticate after adoption of the new policy. Update the integration guide,
  OpenAPI and real-server conformance tests together.
- Operator revocation is local. A revoked credential cannot acquire, renew,
  report or read. It does not transfer ownership or erase terms. Any existing
  grant ages out normally; revocation is not proof that remote work has stopped.

## Storage and failure isolation

Keep credential admission state outside the lease database and its transaction
path. Persist a bounded registry (at most 32 services and 32 current credentials
per service) containing credential ID, service/node binding, secret verifier and
revocation state. Use a reviewed random-secret verifier and constant-time
comparison; store no plaintext bearer secret in the registry, logs or backups.
For the first implementation, replacement means revoking a credential and
freshly pairing that node; no overlap or automatic token conversion is needed.
Local labels have no authority meaning.

Publish an immutable admission snapshot to the listener only after a registry
change has durably committed. Requests do not await registry disk I/O. Revocation
becomes effective for newly admitted requests after that snapshot is installed;
an already admitted request may finish. Document that boundary, and test the
concurrent revoke/renew race without shortening existing grants.

Missing, damaged or unfinished credential storage must never silently revert to
legacy admission, recreate credentials or reset lease terms. A persisted
initialization/policy marker is required to distinguish a new install from lost
credential state. Fail closed for affected admission while keeping the authority
database, current terms and quarantine intact. Node credentials are excluded
from portable backups; restoring to a new Mac requires new pairing.

## Adoption by fresh pairing

1. **Prepare a coordinated update:** stop guarded work on existing SwiftBots
   and install matching Ruru and SwiftBot builds. Preserve service identities,
   the authority database, fencing terms, history and resource policy. No data
   reset is required or permitted as an authentication shortcut.
2. **Adopt the new policy explicitly:** warn that all existing shared-token
   client connections will lose access and require pairing again. Durably
   initialize individual admission and disable legacy client admission before
   accepting new credentials. No dual-token mode, conversion or migration
   progress UI is needed. A failed initialization must fail closed.
3. **Pair every Mac independently:** SwiftMesh currently forwards the shared
   Ruru token in its sealed pairing response. Remove that forwarding for the
   new policy; never copy a Primary's individual credential to a backup. Each
   Mac needs its own locally approved Ruru pairing. Do not add enrollment
   delegation in this change.
4. **Resume under existing lease rules:** pairing does not grant ownership.
   Clients must acquire normally, honour restart quarantine and retain their
   local deadline and fencing checks. Revoking an old credential does not
   establish that its outstanding lease or remote work has stopped.
5. **Manage trust directly:** show approved credentials separately from
   observed participants. Revoking and re-pairing one node must not change
   other credentials, service identity, terms or resource policy.

There is no compatibility period after adoption. An old client must receive an
authentication failure, never an implicit fallback to shared-token access.

## Acceptance before implementation is considered complete

- Existing public client APIs and legacy response decoding retain conformance
  against older authorities; fresh pairing uses the versioned new contract.
- A node cannot impersonate another node through any authenticated route.
- Legacy credentials are refused after explicit adoption, including after
  restart, missing/corrupt registry data and restored settings.
- Revocation and replacement survive restart; response loss never causes secret
  re-delivery; failed persistence never acknowledges enrollment or revocation.
- SwiftMesh never copies one node's individual credential to another Mac.
- Token redaction, request bounds, brute-force admission bounds and service
  isolation hold. Auth-store failure cannot reset ownership or fencing terms.
- Load and concurrent-revocation tests show the existing lease admission,
  renewal latency and outstanding-grant guarantees remain intact.

This is a separate security implementation from the operational-visibility work.
It requires contract and failure review before enabling individual admission.
