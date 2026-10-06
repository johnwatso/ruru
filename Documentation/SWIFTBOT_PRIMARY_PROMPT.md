# Claude prompt for SwiftBot

Paste the following into Claude while working in the SwiftBot repository:

```text
Implement Ruru-controlled Preferred Primary selection in SwiftBot. Work only in
SwiftBot; Ruru's side is complete. Read AGENTS.md, Documentation/AI_CONTEXT.md,
Documentation/DESIGN.md and the client contract at
/Users/john/Documents/GitHub/ruru/Documentation/PRIMARY_PREFERENCE.md first.

Ruru now stores a Preferred Primary per guarded service, separate from Current
Owner. The SwiftBot client should honor it without weakening lease safety.

API: POST /v1/service/policy at the configured Ruru/witness endpoint, using the
same service bearer token as lease requests and JSON {"clusterID":"swiftmesh"}
(use the actual configured cluster ID). A 200 response is:
{"version":1,"clusterID":"swiftmesh","preferredPrimaryNodeID":"server-a","preferenceRevision":1}
The node ID can be explicit null. Revision is a nonnegative Int64, incremented
on selection or clear; it is not a lease term. IDs are stable, case-sensitive,
1–128 UTF-8 bytes, without control characters or surrounding whitespace.
Missing/wrong auth is 401; unknown/cross-service cluster is 403; malformed body
is 400; unsupported routes/methods are 404. Policy reads may succeed during
restart quarantine while lease acquisition/renewal still returns 503.

Extend the existing witness client with a validated policy response and bounded
request timeout. Poll roughly every five seconds while witness-backed SwiftMesh
is active. Cancel polling on stop/config changes; reject stale/out-of-order
responses and reset cached intent when endpoint, cluster or token changes. Do
not initiate new handovers from stale, failed, malformed or unsupported reads.
An older witness returning 404 keeps existing behavior. Handle equal-revision
responses consistently and validate explicit null versus a missing ID field.
Never log bearer tokens. A policy response never grants permission to act.

Use stable enrollment node IDs, not display names or hostnames, to identify the
preferred eligible paired Primary/Standby. Check how authenticated peer identity
is represented; if handback currently identifies targets by name/address, carry
and verify the stable ID in existing authenticated membership/handback messages
as needed, with safe compatibility. A Worker must not become Primary merely
because its ID is selected. Unknown/offline/unready preferred nodes must leave
failover available. Clearing the preference restores normal client selection.

Integrate with ClusterCoordinator.requestCoordinatedHandback(), the existing
prepare/commit/abort flow, ownership callbacks and AppModel+MeshRecovery rather
than adding a second election or forcing a settings role change. Ruru's current
preference should determine the handback target instead of solely the locally
configured Primary; preserve explicit operator pause/manual safety controls and
explain how the existing automatic-handback setting applies. Prevent oscillation
between old local reclaim policy and the Ruru-selected target. Do not rewrite
clusterMode when receiving policy or saving unrelated settings.

Safe return/change: the target must be paired, healthy, desired-running and
caught up; the current owner freezes/drains output and synchronizes state before
releasing ownership; the target acquires a valid new witness lease before any
output or writes. Retain term fencing, monotonic local deadlines,
DiscordService.outputAllowed and restart quarantine. A lost commit/release
response never authorizes output, and the old owner cannot resume after actually
relinquishing. Abort safely before commitment; after uncertainty remain passive
until authority permission is established. When Ruru is configured but offline,
never fall back to an election that bypasses witness leases. Policy 200 is not
proof the authority is ready or that the preferred server is online.

Show Preferred Primary separately from Current Owner in the existing SwiftMesh
UI, including a clear unavailable/unsupported state. Ruru is the editor; do not
add a remote preference write API or duplicate Cloudflare setup in SwiftBot.

Add meaningful isolated tests for persisted/current selection, offline preferred
fallback, returning preferred handback, preference changes during an active
lease/transfer, clear/null, unavailable/legacy 404, malformed/unknown versions,
out-of-order responses/config changes/cancellation, ineligible Workers, stable
identity and Ruru quarantine/unreachability. Assert no overlapping output and no
lower terms. Use fake sessions, clocks and credentials; no real Keychain or live
bots. Run the repository's required Xcode build/tests, update its roadmap and
report validation limits. Do not publish, deploy or change Sparkle/signing.
```
