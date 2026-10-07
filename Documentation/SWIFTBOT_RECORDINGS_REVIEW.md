# SwiftBot recordings and Ruru coordination review

Reviewed 2026-10-07 against the local SwiftBot checkout at `77152d8` (clean
working tree) and Ruru's current working tree. This is a static source review,
not a reproduction on the deployed Macs. Source references below are relative
to the SwiftBot repository unless identified as Ruru.

## Conclusion

Implementation follow-up (2026-10-07): SwiftBot's working tree now contains an
opt-in client and the first combined-library flow described here. It reports one
library endpoint per node using the existing v1 catalogue, discovers complete
lists directly from peers, and serves authenticated reads independently of bot
ownership. Stable node IDs and trusted Ruru origins replace browser-selected
destinations. This review records the original checkout; subsequent behavior,
setup and remaining limits are documented in SwiftBot's
`Documentation/RECORDING_COORDINATION.md` and the repositories' roadmaps.

Ruru can provide a recording/location directory independent of SwiftBot's active
Discord owner. Every participating Mac can report its own resources, and any
authorized SwiftBot can discover them without first becoming Primary. SwiftBot
must still implement reachable endpoints, content authorization and playback.
The current code contains concrete routing and failover defects that adopting
Ruru alone would not repair.

The reviewed feature indexes existing video files in local folders, aggregates
other nodes' libraries and proxies playback. This is not a coordinated capture
or file replication system. No reviewed media path copies recordings to another
Mac when ownership changes. A listing retained during an outage cannot supply
the missing bytes.

## Current flow

1. `RecordingsKit/MediaLibraryIndexer.swift` enumerates configured local folders.
   Local IDs are `source UUID|relative path`; snapshots include local paths and
   the node's display name.
2. `AppModel+Media.swift:606` collects local and remote libraries. A configured
   leader queries its registered peers. A configured standby queries only the
   leader's **local** library. A worker returns only its own library.
3. `ClusterCoordinator.swift:3360` registers peer callback URLs. HTTPS advertised
   URLs take precedence; otherwise it prefers the observed connection host plus
   the declared mesh listen port.
4. The WebUI receives a base64 descriptor containing item ID, owner name and
   owner URL. Playback goes browser → viewing SwiftBot → owning SwiftBot through
   `/v1/media/stream`, with mesh authentication on the second hop.
5. Library fetches have an eight-second request timeout and a five-minute cached
   outage fallback. Local video responses are capped at 8 MiB per request;
   remote responses are buffered through `URLSession.data(for:)`. Remote HLS is
   deliberately unavailable, so remote playback uses MP4.

## Findings

### P1 — The advertised public server does not route recording requests

`AppModel+MeshRecovery.swift:176` derives the public mesh address from the local
WebUI address. `AppModel+AdminWeb.swift:1716` installs the mesh handler on that
server. However, `AdminWebServer.swift:2532` forwards only `/v1/mesh/*` and three
`/cluster/*` paths. It omits `/v1/media/*`, whose handlers exist in
`ClusterCoordinator.swift:2638`.

Consequently, a peer can register successfully through its public WebUI hostname
while `GET /v1/media/library` at that same hostname reaches the WebUI's 404
fallback (`AdminWebServer.swift:4352`). Playback, thumbnail, frame and playback
choice routes have the same mismatch. This is a strong explanation for failure
when using those public addresses; the user's actual setup was not inspected.

Fix the explicit route forwarding in SwiftBot and retain mesh authentication.
Test the advertised WebUI entry point, rather than only the separate mesh port.
Ruru cannot make a missing HTTP route work.

### P1 — Recording aggregation follows the saved role after failover

`AppModel+Media.swift:610,641,1136` branches on `settings.clusterMode`, while
the runtime role is separate (`AppModel.swift:1171`). Promotion sets
`lastPublishedRole = .leader` without changing that saved preference
(`AppModel+MeshRecovery.swift:276`). A promoted standby therefore still takes
the standby library branch, querying its configured old leader instead of all
its registered peers. The media monitor checks the runtime role before entering
an aggregation helper that checks the saved role, so remote media triggers have
the same inconsistency. A demoted configured Primary has the inverse mismatch.

Use runtime role where current leadership is necessary. For browsing, prefer
discovery independent of leadership: Ruru is particularly useful here. Even
without failover, a standby cannot see a third node's recordings through the
leader because the mesh library handler supplies only a local snapshot
(`AppModel.swift:779`, `ClusterCoordinator.swift:4441`).

### P1 — A browser-supplied descriptor controls the authenticated destination

The item descriptor is base64 JSON, not a signed destination binding
(`AppModel+Media.swift:76,86`). Stream/thumbnail/frame handlers trust its
`ownerBaseURL` (`AppModel+Media.swift:790`). The remote fetch methods build the
URL and add mesh authentication without resolving the owner against a trusted
node directory (`ClusterCoordinator.swift:4628,4662,4686`). Even the generic
mesh host validation used during registration is absent from these fetches.

The separate WebUI media access token authenticates a session, not this
descriptor's destination. A permitted caller can therefore substitute a URL
and cause an authenticated outgoing request to an unrelated destination.
`AppModel+ClipPeople.swift:151` checks a member's node/item pair but does not bind
the endpoint. No exploit or remote request was performed during this review.

Resolve an opaque node/resource ID through a trusted, configured directory on
the server. Validate exact allowed origins, redirects and transport policy;
never accept a browser-provided destination as authority to attach mesh
credentials. Ruru's origin admission helps, but SwiftBot must also enforce the
destination when making requests. Remove automatic HTTPS-to-HTTP fallback from
the new path (`ClusterCoordinator.swift:4713`).

### P2 — Registration and retained metadata do not establish playability

Without a public HTTPS address, registration derives a callback from the source
host and declared port (`ClusterCoordinator.swift:3368,3427`). An outbound
registration can succeed while that reverse connection is unavailable through
NAT or a tunnel. Ruru reporting would avoid that reverse callback for discovery,
but playback still needs a configured reachable route or an explicit relay.

`fetchRemoteMediaLibrary` returns retained data for up to five minutes without
adding a stale/reachability field (`ClusterCoordinator.swift:4534`). The WebUI
item model receives no such freshness state. Local scans similarly retain old
items when a volume is unavailable (`MediaLibraryIndexer.swift:75,113`). These
are useful retention behaviors, but the resulting entries must not imply that
the source can currently play them. Report receipt, successful folder scan,
endpoint reachability and readable bytes are different observations.

Ruru provides monotonic report freshness and stale locations. That freshness
proves only a recent report; SwiftBot must preserve source-unavailable state
and validate playback separately. Do not refresh unavailable files indefinitely
as healthy locations just because the SwiftBot process is running.

### P2 — Current identities cannot describe interchangeable copies reliably

`MediaLibraryIndexer.swift:96` uses a folder UUID and relative path as identity.
Moving or renaming a file changes it; copying a file into a separately configured
folder on another Mac produces another identity. Routing decides whether an item
is local by its owner's display name (`AppModel+Media.swift:796`), and registration
deduplicates nodes by name (`ClusterCoordinator.swift:3379`). Duplicate or renamed
node names can therefore affect routing and saved recording metadata.

Use stable node IDs separately from display names. Add an opaque resource ID
that survives moves, and preserve it when intentionally replicating that item.
Separate identity from a content/version check before treating two locations as
interchangeable. Different cameras or player perspectives are separate resources,
even when they belong to the same recording session.

### P2 — Cross-node editing is unfinished

Multiview export explicitly rejects two recordings on different nodes
(`AppModel+Media.swift:925`). Remote export submission stores only the initial
external job (`AppModel+Media.swift:896`, `MediaExportCoordinator.swift:18`);
the reviewed media API has no remote job-status polling/result retrieval path.
These export controls are currently archived from the active WebUI, so this is
a boundary for future work rather than the primary browsing blocker.

Ruru could eventually coordinate durable operations with IDs, acceptance,
progress and results. Cross-node editing also requires authorized input transfer
or a processing host that can read both files; assignment alone cannot provide
that. It should follow basic catalogue/playback integration.

## What the existing Ruru capability can do

Ruru's `resource-catalogue.v1` already admits service-scoped reports without a
lease, holds several node locations for one logical resource, enforces configured
HTTPS origins and exposes monotonic freshness. It isolates metadata from the
lease database and renewal commit path. SwiftBot currently has no client for it.

The current contract is sufficient for a small integration pilot, not a complete
recording library replacement:

- It admits 128 locations per node, 512 per service and 2,048 globally, with
  eight upserts per batch and a 4 KiB request body.
- Every retained location needs re-reporting before its 90-second freshness
  expires. Entries disappear after 600 seconds; process restart starts empty.
- Resource metadata is only namespace, ID, title and URL. It carries no size,
  capture time, duration, game, participant permissions, codec or variant state.
- URLs must be HTTPS with no query, fragment or credential. Existing
  `/api/media/stream?id=...` links and signed playback URLs cannot be reported
  verbatim. Add a stable path endpoint that performs its own access checks.
- Discovery is not routing, automatic replication, a durable historical archive
  or confirmation that another copy is playable. A shared service token is not
  separate authentication of a node.

See Ruru's [v1 contract](COORDINATION_API.md). Keep recording metadata and
permissions in a focused SwiftBot capability/client. If a full recording index
is needed, design a bounded paged metadata contract and storage isolation first;
do not simply raise limits in the lease listener. Reporting a node/library
endpoint instead of every file is another possible bootstrap, but it retains
per-node library fetches and does not provide per-recording copy lookup.

## Suggested implementation order

1. Fix public media routing, runtime-role aggregation and trusted destination
   resolution in SwiftBot. Establish a two-Mac playback test through each Mac's
   actual advertised address.
2. Introduce stable node/resource IDs and a path-based, authenticated recording
   endpoint. Keep browsing and serving available on standby nodes independently
   of exclusive Discord ownership.
3. Add an opt-in SwiftBot Ruru client: discover capability support, serialize
   bounded reports per node with jitter/backoff, report only its own locations,
   and query revision-checked catalogue pages. Keep reporting independent of
   timely lease renewals. Re-report after Ruru restarts.
4. Resolve node/resource IDs server-side and fetch rich recording metadata from
   the serving SwiftBot. Start with existing WebUI authentication and SwiftBot
   proxying to minimize access-model changes. Direct browser-to-owner playback
   would need explicit session/grant exchange between Macs; never publish the
   Ruru bearer token or mesh secret to a browser or catalogue.
5. Verify failure behavior, then consider playback routing, richer catalogues,
   replication and managed exports as separate capabilities. Change copies only
   with content/variant compatibility checks; do not silently switch byte ranges
   between different encodes mid-playback.

Ruru should retain metadata and policy on the older Mac mini. Recording files,
video bytes, transcoding and export execution remain on participating SwiftBots.
Keep the core application-neutral; do not couple Discord leadership to the
ability to report or serve a recording.

## Validation still required

This review read the media/index/export code, public and mesh routing, registration,
promotion/demotion, relevant tests, and both apps' architectural contracts. Existing
recording regression tests cover range parsing and local folder outage/recovery,
not end-to-end public media routing or a three-node library after promotion.

Before claiming a working integration, test public media routing with valid and
invalid mesh auth; three nodes with browsing from Primary and Standby; promotion
and handback with saved roles unchanged; duplicate display names; tampered owner
URLs and redirects; missing volumes and recovered hosts; retained stale reports;
Ruru restart/re-report; more than one report batch; byte-range seeking and pinned
quality; and existing member authorization on remote recordings. Measure lease
renewal latency under catalogue traffic on the target Intel/Sequoia Mac.

XcodeGen and documentation diff checks passed. No app runtime changes, builds,
hosted tests, production requests, credential reads,
tunnel changes or deployments were performed. The actual cause of the historical
failure remains unverified without a live multi-Mac reproduction.
