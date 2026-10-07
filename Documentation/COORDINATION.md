# General coordination direction

Ruru should grow into a coordinator for services across multiple servers and
applications. Lease guarding is the first implemented capability. SwiftBot
recordings are a useful first example for broader coordination; the shared
architecture should also accommodate other catalogues, endpoints and workloads.

This document records the general direction and extension boundaries. The first
opt-in resource catalogue is now implemented; see [the v1 client contract](COORDINATION_API.md).
Routing, replication and work assignment remain future work. Existing lease
clients remain compatible.

## Shared concepts

Keep the shared model small and application-neutral. Introduce these concepts
when a concrete capability needs them, with stable identifiers and explicit
service boundaries:

| Concept | Responsibility |
| --- | --- |
| Service | An explicitly configured coordination group and permission scope. |
| Node | A participating instance within a service, with stable identity and separately reported availability. |
| Capability | A versioned function a service or node supports, such as ownership, catalogue reporting or playback. |
| Resource | A logical item within a service and capability, independent of its storage location. |
| Location | A node's reported copy of a resource or endpoint that can serve it. |
| Policy | Saved operator intent, distinct from observed state and execution permission. |
| Operation | A scoped request and its acknowledgement/result, if managed work is introduced. |

Existing service metadata IDs, protocol cluster IDs and node IDs have different
roles. Preserve their current meanings and credential mappings. A future service
may use coordination capabilities without competing for exclusive ownership;
adding that model requires an explicit migration from the current guarded-service
catalogue. Resource IDs belong to a service and capability namespace, and a file
path, display name or playback URL is not its identity.

## Console organization

Coordination starts with individual app/service cards. Opening a service shows
its own coordination features, settings, connection details and observations.
SwiftBot recordings belong inside SwiftBot; another app's resources and settings
belong inside that app. There is no shared resource page with a service picker.
A service can expose additional feature panels as its integration grows, while
using the common core contracts where appropriate. Resource catalogue is the
first implemented feature, not the definition of all coordination.

Guarding and Coordination use the same stable service identity and credentials.
A service can be added from either page; adding it does not require it to acquire
a lease or enable catalogue reporting. Separate configured groups for the same
application remain separate service cards and permission scopes. Remove is also
available within each Coordination service page. It removes the shared service
from both Coordination and Guarding, with confirmation of revoked admission and
cleared reports; files and durable ownership terms/history are retained.

Paired clients can request approval for their own HTTPS website using their
existing service credentials. Sharing remains a separately enabled capability:
a proposal cannot enable reporting or change lease policy. Website requests are
bounded and ephemeral; local approval persists the exact origin before admission.
SwiftBot exposes this local choice within failover pairing, while Ruru's contract
remains application-neutral. See [origin enrollment](COORDINATION_API.md#request-approval-for-a-server-origin).

## Capability boundaries

Use focused Swift modules with typed, versioned contracts and validation. Keep
application-specific metadata and workflows in their capability module. Generic
coordination should not depend on Discord, SwiftBot recording formats or a
particular application's configuration. SwiftBot branding and pairing guidance
remain presentation/integration details.

Add contracts alongside the existing lease protocol. Capability support should
be explicit and discoverable by an authenticated client; unsupported versions
must return a clear result. A node reporting a capability or resource does not
thereby acquire a lease, receive permission to execute work, or enable a feature
for its service. Operator configuration controls admission.

The UI-free framework boundary remains useful. New capabilities can use separate
Swift targets if their scope warrants it; renaming WitnessKit, creating an empty
plugin framework or adding unused protocols is not required in advance. The
first concrete implementation should establish the smallest reusable contract.

## Ownership, observation and execution

Lease ownership answers who may perform a particular exclusive activity.
Availability answers what has been observed recently. Several nodes may serve
resources concurrently, including while another node owns the bot's active work.
Keep these facts separate in the API, persisted model and console.

Known Servers currently derives from ownership history. It must not become an
implicit online-node registry. Future reports need an explicit freshness model,
bounded expiry and an unknown/stale state. Use monotonic time for live freshness
and conservatively treat prior-process observations as unverified after restart.
Wall-clock timestamps support display and audit, not proof of current liveness.

Managed operations need explicit authorization, durable intent where required,
idempotency rules, bounded retries and observable results. Assignment or a timeout
alone cannot prove execution or exactly-once effects. Exclusive work needs
resource-appropriate fencing and cooperating clients; retain the existing lease
terms and deadlines wherever the lease capability is used.

## Safety and capacity

Keep the lease store, its lifetime locks, fencing terms and restart quarantine
intact. Metadata capability outages should leave the ownership capability usable.
Broad coordination may degrade independently; authority readiness and capability
readiness must be distinguished without changing the current `/health` contract.

Bound reports, catalogue pages, retained metadata, concurrent requests and
background work. The current listener's 4 KiB body limit and shared 32-request
admission budget suit lease traffic. Catalogue reporting needs an explicit
pagination/batch contract and an admission/storage execution strategy that keeps
long reports or scans from delaying renewals. Changes to shared limits require
lease-focused load and failure validation on the target Mac.

Keep capability storage and migrations distinct from the lease schema and commit
path. Decide whether separate tables/connections or a separately owned store
provide sufficient isolation when implementing a real capability. Each store
needs explicit ownership, recovery and migration rules; existing authority data
must never be silently replaced or restored to older terms.

Authorize access by service, capability and operation. The current shared service
token trusts participants within that group; a reported node ID is not separately
authenticated identity. Define participant authentication and operator permissions
before introducing per-node restrictions or destructive cross-server operations.
Keep secrets in Keychain and out of resource metadata, advertised URLs and logs.
Validate advertised origins and scope any probes to configured destinations.

Ruru coordinates metadata, policy and requests. Participating applications own
their storage, streaming and workload execution. This keeps the coordinator's
resource budget focused on the older Mac mini and lets each application implement
the appropriate data transfer and access rules.

## Adoption stages

1. Apply these boundaries to ongoing work. Preserve the generic service model,
   existing lease compatibility and UI-free core; avoid new SwiftBot assumptions
   in shared authority code.
2. Establish a small authenticated capability/reporting contract. The v1
   catalogue implements this boundary, with recordings and artifact locations
   exercised by tests and preview fixtures. Real client adoption is still needed
   to assess the contract beyond these examples.
3. Implement a read-only resource/location catalogue and freshness reporting.
   This first Ruru slice is complete, with ephemeral bounded observations and
   operator opt-in. SwiftBot's first client reports recording-library endpoints
   and combines full libraries in its own Recordings view. Each host serves media
   independently of Discord ownership; Ruru never carries video or thumbnails.
   The viewing SwiftBot currently proxies playback after its own user checks.
4. Introduce routing policy and managed operations only as needed. Replication,
   retention, deletion and work assignment each need their own permissions,
   failure semantics and client implementation.

Before expanding scope, validate service isolation, old-client compatibility,
restart behavior, storage failure and lease latency under catalogue load. Actual
Intel/Sequoia execution and capacity measurements remain necessary before claiming
the target Mac can support an implemented coordination workload.
