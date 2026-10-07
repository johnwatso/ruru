# Resource catalogue v1

Ruru now provides an opt-in, application-neutral catalogue of reported resource
locations. Several servers can report the same recording or artifact without
competing for exclusive ownership. Ruru stores metadata; clients host files,
authorize playback/downloads, and serve content themselves.

This is a first development slice. SwiftBot now has an opt-in library-directory
client for its combined Recordings view; see the integration convention below.
Replication, deletion, retention jobs, routing decisions and work assignment are
not implemented. The contract is versioned but may evolve during early development.

## Enable and authenticate

In **Coordination**, open the app/service card, then **Resource catalogue →
Settings…**, enable its catalogue and enter the allowed HTTPS server origins. An origin is scheme, host
and optional port, such as `https://media.example.com` or
`https://media.example.com:8443`. Paths, credentials, queries and fragments are
not origins. Paired clients can alternatively propose their own origin for local
operator approval, as described below. Only URLs at those exact configured origins
are admitted. Empty origin lists allow discovery/reads but admit no resource locations.

Use the service's existing endpoint, `clusterID` and Keychain-backed bearer token
from that service’s Connection Details. All routes below are POST with JSON and `Authorization: Bearer …`.
No lease acquisition is needed to report or read a catalogue. Old lease and
Preferred Primary clients are unchanged; `/health` still describes lease readiness.

The group token trusts all participants in that service. `nodeID` is a reported
identity, not a separately authenticated principal. A trusted participant can
report as another node. Per-node permissions and destructive operations require
a future authentication design. Tokens and signed URLs must not appear in metadata.

## Discover capabilities

`POST /v1/coordination/capabilities`

```json
{"version":1,"clusterID":"swiftmesh"}
```

The reply includes `version`, `clusterID`, `enabled`, `capabilities`,
`allowedOrigins`, `enrollmentSupported: true`, and the limits below. `capabilities` is
`["resource-catalogue.v1"]` when enabled, or `[]` when disabled. This route remains
available when the catalogue is disabled, including enrollment support; report/read
return 403 in that case. Older authorities may omit `enrollmentSupported`; clients
must then use manual origin setup.
Supporting a capability never grants permission to perform exclusive work.

## Request approval for a server origin

`POST /v1/coordination/enrollment`

```json
{
  "version": 1,
  "clusterID": "swiftmesh",
  "nodeID": "backup-mac",
  "nodeName": "Backup Mac",
  "origin": "https://max.swiftbot.app",
  "withdraw": false
}
```

`nodeName` is optional; other fields are required. The existing service bearer
and scope checks apply even when its catalogue is disabled. `origin` must be an
exact canonical HTTPS origin, at most 256 UTF-8 bytes; the node ID/name use the
existing 128/256-byte limits. A request proposes access only. It never enables
reporting, changes an allowlist, probes a URL or acquires ownership.

The reply is `{"version":1,"clusterID":"swiftmesh","status":"pending"}`.
Statuses are `pending`, `rejected`, `approved` (only when the saved catalogue is
enabled and that exact origin is allowed), or `withdrawn`. Clients must rediscover
capabilities and validate the saved allowed origins before reporting or sending
content credentials; an enrollment reply alone is not routing authority.

In Ruru, open the service in **Coordination → Website requests** and review its
exact website. **Approve** adds that origin to the saved policy, enabling its
catalogue if necessary. The configuration checkpoint precedes live admission.
The eight-origin limit still applies, and existing origins remain allowed.
**Reject** hides the request and returns `rejected` on repeat submissions until
its original ten-minute expiry. Approval authorizes the origin for the service,
not an independently authenticated node. Display names and IDs are group reports.

Requests and rejection markers are in memory, limited to eight per service and
64 per authority. They expire 600 seconds after their first receipt; repeated
submissions do not extend that deadline. Clients may resubmit after expiry or a
process restart. Set `withdraw: true` to remove that node/origin's request or
rejection marker. Withdrawal does not remove an approved origin or an existing
resource location; resource withdrawals use `/report` separately. Token rotation,
service removal, and changing an enabled catalogue to disabled clear requests.
An authenticated client may later submit a new proposal while it is disabled.

## Report a bounded batch

`POST /v1/coordination/report`

```json
{
  "version": 1,
  "clusterID": "swiftmesh",
  "nodeID": "home-mac",
  "nodeName": "Home Mac",
  "resources": [
    {
      "namespace": "recordings",
      "resourceID": "session-42",
      "title": "Community catch-up",
      "url": "https://media.example.com/recordings/session-42"
    },
    {
      "namespace": "artifacts",
      "resourceID": "nightly-macos",
      "title": "Nightly macOS build",
      "url": "https://media.example.com/artifacts/nightly-macos"
    }
  ],
  "removed": []
}
```

`nodeName` is optional. Other fields are required. Resource identity is
`(clusterID, namespace, resourceID)`. Each reporting node contributes its own
location for that identity, so multiple copies coexist. Applications must use
stable IDs shared across their copies, rather than a URL or file path as identity.
Namespaces hold application semantics; the core has no recording-specific fields.

`resources` upserts only the reporting node's supplied locations; omitted items
are retained until removed or expired. `removed` contains up to eight objects
with `namespace` and `resourceID`, deleting only that node's observations. This
does not delete files. Duplicate keys or keys in both lists reject the whole
batch. Validated capacity changes are atomic. A successful reply is
`{"version":1,"accepted":true}` and is an in-memory acknowledgement, not a durable
storage or workload acknowledgement.

Serialize batches per node. Repeating an upsert refreshes that location's report
time; repeating a removal is harmless. There is no client sequence or fencing
token in this observational protocol. Avoid concurrent out-of-order batches.
Ruru receipts determine ordering; stronger client-session ordering is future work.

Re-report **each retained location** regularly, for example every 30 seconds with
jitter. Freshness lasts 90 seconds from monotonic receipt. Empty reports update
the node's display metadata but do not refresh its old resource locations. Stale
locations remain visible until 600 seconds from their last individual report,
then disappear. Freshness describes a report, not confirmed reachability.

URLs must use HTTPS, be at a configured origin and contain no user information,
query or fragment. Ruru does not fetch, probe or automatically open them. Clients
own content access control; credentials and presigned query URLs are unsuitable
for this catalogue. Return an application endpoint that performs its own access
checks instead.

## Read pages

`POST /v1/coordination/catalogue`

```json
{"version":1,"clusterID":"swiftmesh","offset":0}
```

The reply contains `version`, `clusterID`, an opaque `revision`, up to 20
`locations`, and an optional `nextOffset`. A location includes `clusterID`,
`nodeID`, optional `nodeName`, the reported `resource`, `ageSeconds` and `fresh`.
Sort order is node ID, namespace, then resource ID. Stale entries are included
and must not be represented as available/healthy.

For the next page, send `nextOffset` as `offset` and echo `revision`. A report,
removal, expiry or admission change within that service invalidates its revision.
On 409 `catalogue_changed`, discard accumulated pages and begin at offset zero.
Changes in another service do not invalidate this service's pages. Freshness ages
are evaluated per read; recheck them when using results. Missing `nextOffset`
means the traversal is complete. Offset must be a nonnegative multiple of 20;
nonzero offsets require a revision.

## Bounds and failure behavior

| Bound | Value |
| --- | --- |
| Request body / headers | 4 KiB / 8 KiB, unchanged for leases |
| Upserts / removals per report | 8 / 8, also subject to the byte limit |
| Page size | 20 locations |
| Nodes per service | 16 |
| Locations per node / service / authority | 128 / 512 / 2,048 |
| Allowed origins per service | 8 |
| Namespace / resource ID / title / URL | 64 / 128 / 128 / 512 UTF-8 bytes |
| Report freshness / retention | 90 / 600 seconds |
| Enrollment requests / rejection markers per service / authority | 8 / 64 |
| Enrollment lifetime from initial receipt | 600 seconds |
| Classified coordination connections | 4 of the existing 32 total |
| Connection deadline | 5 seconds, unchanged |

Small batches may still exceed the byte limit; split them further. Expiry frees
capacity. Catalogue capacity does not evict other participants to admit a report.
Retry 429 with backoff, keeping reporting independent of timely lease renewal.

Error replies have `error`: 400 `invalid_request`, `invalid_report` or `invalid_enrollment`; 401
`unauthorized`; 403 `forbidden_cluster` or `capability_disabled`; 404 `not_found`;
409 `unsupported_version` or `catalogue_changed`; 429 `catalogue_capacity`, `enrollment_capacity` or
`coordination_busy`. The transport also returns its existing parser errors.

Coordination is classified once a complete request line arrives, including while
the body is incomplete. Four such connections may remain active; additional
ones receive 429. Unclassified connections still share the original total budget.
This provides capacity separation for normal metadata traffic, not protection
from a general connection flood. Target-Mac latency/capacity measurement remains
required before increasing limits or making deployment guarantees.

## SwiftBot combined recording libraries

SwiftBot's opt-in integration reports one location per Mac with namespace
`swiftbot.recording-library.v1`, resource ID `library`, title
`SwiftBot recording library`, its stable enrollment `nodeID`, and URL
`https://<that Mac's Web Interface origin>/v1/media/library`. Allow each Mac's
exact HTTPS origin in this service's policy, either manually or by approving its
automatic enrollment request. SwiftBot offers local recording sharing during
SwiftMesh pairing and reuses the inherited Ruru connection; this does not require
a separate service or lease. This is an authenticated API endpoint; a browser opening the URL directly does not acquire content access.

The convention uses the existing generic contract. Ruru does not inspect the
namespace, fetch the URL, store individual recording metadata or proxy media.
SwiftBot reads the directory, fetches complete libraries directly from their
hosts and presents them together in its existing Recordings view. A viewer on
John's website plays Max's recording through Max → John → viewer. Video, audio
and thumbnails never traverse Ruru. Each server opts in separately and can serve
recordings while its Discord bot is on Fail Over; no lease is needed for these reads.

Reporting library endpoints avoids one catalogue slot per file. Existing origin,
node, batching, freshness and admission limits remain unchanged. SwiftBot owns
the recording list's bounds and content authorization, and validates reported
destinations before sending mesh credentials. This convention does not identify
replicas of individual files or introduce routing/managed-work permission.

## Storage and console

The catalogue is a separate bounded Swift actor with no DuckDB, disk or network
work. Only operator policy persists in non-secret configuration under the stable
service metadata ID. Policy checkpoints precede live admission changes. Disabling,
service removal and token rotation clear observations; narrowing origins removes
locations no longer permitted. Re-adding a service does not inherit opt-in.

Stopping/restarting the listener in the same process preserves observations and
their ageing. A process restart creates an empty catalogue, so clients must
re-report. There is no catalogue database migration, and the lease schema,
lifetime locks, terms and restart quarantine remain intact. Reporting during
lease quarantine never grants ownership.

The Coordination page lists separate app/service cards. Each detail page owns its
feature settings, connection details, pending website requests and resources,
with search, URL copy and
fresh/stale reports. It displays up to 100 matching locations; search narrows
larger catalogues. Add Service is available from both Coordination and Guarding,
using the same service catalogue. Remove in a service’s Coordination detail page
removes that shared service from both pages, revokes reporting/lease admission and
clears its observations, while retaining hosted files and durable lease history.
A coordinator-only client can use it without
acquiring a lease. `--preview-screenshots` supplies SwiftBot recording fixtures and
a separate Build Server artifact example, without opening storage, Keychain or
listeners.
