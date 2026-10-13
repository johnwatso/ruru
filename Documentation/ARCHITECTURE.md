# Ruru architecture

This repository is independent from SwiftBot. It has four Xcode targets,
including a helper built only for storage tests:

| Target | Responsibility |
| --- | --- |
| `Ruru` | Sequoia-compatible SwiftUI menu bar app, native sidebar console, host settings, Keychain credentials, login control, and Internet Access setup. |
| `WitnessKit` | Actor-isolated lease authority, durable DuckDB store through the official Swift API, HTTP parser/router, bounded Network listener, Cloudflare API setup and connector supervision. No SwiftUI dependency. |
| `WitnessKitTests` | Unhosted XCTest tests; isolated temporary databases and loopback sockets, no real Keychain or login items. |
| `WitnessStorageProbe` | Test-only native process used to verify recovery after SIGKILL; never shipped inside the app. |

The application owns the lease store for its whole lifetime, independently of
the status window. Listener pause/restart preserves the same authority epoch and
leases. Process restart creates a new monotonic epoch, waits out the longest
outstanding grant recorded in the database, and refuses earlier-epoch renewals.

Every service is an equal entry in the settings' `services` list, with its own
cluster ID, Keychain token (`service-<id>`), lease length and display names.
There is no built-in service; `kind` (SwiftBot or Other app) is only a template
for the icon and pairing instructions, and SwiftBot keeps its own app icon.
`GET /v1/service` lets a client discover its service's capabilities, lease
length and current lease with its own token. `Clients/RuruClient` is the
reference Swift client; its conformance tests run against the real server.
Alerts (`RuruAlerts.swift`) watch each poll for services whose owner stops
renewing, failovers and authority problems, and deliver them to macOS
notifications and an optional Discord webhook kept in Keychain.
Failover/recovery embeds can link to the current owner's self-reported HTTPS
Web UI origin from a fresh participant report. Matching uses service and stable
node ID; display names never determine alert ownership. Addresses are ephemeral,
credential-free and unprobed, independently of resource catalogue opt-in.
Fresh UPS, battery and planned-session transitions are also edge-triggered;
their alert category is opt-in. A bounded DuckDB participant activity history
is separate from ownership history and is never an authority input.
The versioned operational-status capability is an additional bounded,
in-memory diagnostic channel. It uses authenticated node reports with stable
component codes, expires after restart, and is never an authority input.

## Coordinator direction

Ruru's intended direction is a general service coordinator, with lease guarding
as its first implemented capability. Future development should preserve room
for application-neutral discovery, resource catalogues, routing, policy and work
coordination. SwiftBot recordings are an initial use case for this direction.
The extension boundaries and adoption stages are recorded in
[Coordination](COORDINATION.md). The first opt-in resource catalogue is implemented
in a separate in-memory Swift actor; authenticated discovery, reports and paged
reads are documented in [the v1 contract](COORDINATION_API.md). Operator policy
persists by stable service metadata ID. Observations expire monotonically and
start empty after process restart. No lease database schema or commit path is
changed. SwiftBot now has an opt-in client that reports recording-library endpoints
and combines their contents in its own Recordings view, independently of bot
leadership. All media stays on SwiftBot hosts; Ruru carries only the directory.
Paired clients can propose their own HTTPS origin through the generic enrollment
route. Bounded ephemeral requests appear under their service; only local operator
approval checkpoints and publishes an enabled allowlist. SwiftBot offers this
sharing choice during failover pairing using the existing Ruru credentials.
Managed work, replication and coordinator routing decisions remain future work.

## Wire compatibility

Routes are `/v1/lease/acquire`, `/v1/lease/renew`, `/v1/lease/release`.
The request has `clusterID`, `nodeID`, and an integer `term`. Updated SwiftBots
also include an optional `nodeName` for display. Older requests remain valid.
Success returns `ownerNodeID`, `term`, `expiresInSeconds`; release returns
`{"released":true}`. Errors return a machine-readable `error` with
400/401/403/409/503 status. JSON field names match SwiftBot's `MeshWitnessClient`.

`POST /v1/service/policy` is a separate, read-only authenticated route for the
configured service's Preferred Primary and preference revision. It never
changes ownership and returns no credential/display-name data. Legacy lease
request/reply JSON is unchanged. See [the client contract](PRIMARY_PREFERENCE.md).

Bearer authorization uses a constant-time CryptoKit HMAC check. The listener admits only explicitly configured service clusters. Each service
has a separate Keychain bearer token, scoped to that cluster. It never accepts
arbitrary new clusters from requests. Participants within a service are trusted; this token is separate from mesh transport and
Discord credentials. TLS is supplied by Cloudflare Tunnel when Internet Access is configured. An
existing external HTTPS route can also be used.

The TCP listener accepts at most 32 concurrent requests, at most 8 KiB of headers
and 4 KiB of body, with a five-second read/response deadline. Duplicate headers,
ambiguous lengths, chunked requests, and pipelining are rejected. One request is
served per connection. At most four classified coordination connections are
admitted within the existing 32-connection budget; overflow returns 429. Requests
without a complete line still share the total admission budget. Startup has a
bounded timeout; failures are visible in the native status window.

## Durability and fencing

The DuckDB schema retains the original `leases` fields, with explicit BIGINT
terms and DOUBLE expiry values. Transactions use `BEGIN TRANSACTION` and durable
`COMMIT`; DuckDB's persistent write-ahead log supplies crash recovery. Audit events and
the grant are committed in the same transaction. Current-epoch membership is
updated only after commit; a failed write must never make an old lease live.
The file lock is held even when the HTTP listener is stopped.
An initialization marker prevents recreating a missing database on later process
startup. Preserve it with the database; it is not a user-reset control.

No SQLite data migration is included. Existing SQLite files, sidecars or the old
initialization marker prevent creating fresh DuckDB terms. Replacing an old
authority requires the explicit **Set Up DuckDB** flow and client re-pairing.
The user confirms every client is stopped/unpaired and the old witness is retired.
Under both lifetime locks, replacement checkpoints new cluster IDs and tokens,
archives SQLite files, retires old binaries before moving data, then initializes
a new DuckDB authority. Existing/damaged DuckDB storage is never replaced.
Interrupted replacement fails closed. Fresh setup
persists both initialization intent and an older-app retirement marker before
database creation; interrupted setup fails closed. Existing startup validates
the complete schema and never creates missing tables. Both the old SQLite lock
path and the new DuckDB lock are held for the authority's lifetime.

The official `duckdb-swift` package is pinned to stable 1.1.3, rather than a
development tag. All application-owned code is Swift; dependency internals may
use other languages through Swift APIs. One persistent connection, two worker
threads, a 128 MB DuckDB memory budget, and disabled external access keep this
authority bounded. The budget is not a cap on total process memory. No SQLite
library or runtime extension is linked by the app.

The durable expiry marker remains intact during restart quarantine. Clearing it
before the wait completes would let a second restart skip the wait. Persisted
expiry values are never compared against the new process's clock as active leases.
Wall time is used only for human-readable audit timestamps.

Grant failure preserves the former term and owner. Term exhaustion, damaged or
missing storage, and witness recovery all fail closed. The database cannot be
safely reset or restored to an older snapshot under active clients.

## Bot display names

Ownership and fencing always use `nodeID` and `term`. A name cannot acquire a
lease, identify a preferred Primary, or authorize a different node. Accepted
requests may update their own name in a separate `node_names` table keyed by
cluster and node ID; the original lease schema is preserved. Names commit with
the accepted transaction, survive restarts, and are retained only while a lease
or one of the bounded audit events references that node. Failed requests cannot
change names; blank, oversized or multiline hints are ignored.

The app can override a bot's reported name with a local nickname in non-secret
settings. This works with existing SwiftBot versions that send only an ID.
Saving a nickname never stops the listener, connector or lease. Overview and
Activity use the same label; the full node ID is available in Bot Details.

## Operation on the older Mac

Deployment target 15.0 applies to the app, framework, and test target. Release is
universal (Intel and Apple silicon). All UI uses APIs available on Sequoia; no
macOS 26-only materials, AI, video processing, or bundled web framework is used.
The UI refreshes once per second; lease requests use small DuckDB transactions.
Resource reporting uses bounded batches and a separate actor with no I/O. Resource usage has not been benchmarked on the Mac mini.

The initial app uses a logged-in user session and optional `SMAppService.mainApp`
login registration. **Show Ruru in** defaults to Menu Bar and changes activation policy
immediately without restarting the listener. The menu bar remains available; the
Dock icon reopens the window. Closing it does not stop the service. A standalone
pre-login daemon or crash-restarting helper can be added later if required; the
UI-free WitnessKit boundary leaves that possible without changing lease semantics.

The visible application name and product are Ruru. Bundle identifiers, Keychain
accounts, storage directory, HTTP protocol and tunnel naming identity remain
stable across the rebrand. The project, application target and scheme are named
`Ruru`; the repository folder and Icon Composer source are `ruru` and `ruru.icon`.

## Internet Access

The Cloudflare clients and connector supervision are adapted from SwiftBot's
implementation, with no source/project dependency on the bot repository. The
app creates a dedicated `ruru-<installation UUID>` tunnel.
Retries reuse only that identity; DNS conflicts fail before management writes.
The flow checks the API token, lists scoped zones (including pagination), checks
the hostname, creates/reuses the dedicated tunnel, checkpoints its ID and token,
sets the loopback ingress plus catch-all 404, and creates a proxied CNAME.

The app checkpoints tokens in Keychain and non-secret settings before publishing
DNS. Failed disk/Keychain writes prevent ingress publication. A failed later API
step leaves the saved setup paused and retryable; it does not delete or overwrite
other routes. API `success:false` is failure even with HTTP 200. The API token is
used only for provisioning; connector startup uses its own stored tunnel token.
It is passed through `TUNNEL_TOKEN`, never argv, configuration JSON or logs.

The supervisor bounds exit retries to five, handles network changes, buffers
fragmented registration lines, and tags process callbacks/retries by generation
so stopped connectors cannot reappear. Every 60 seconds it requests `/health`
with a random query and no-cache policy. Readiness JSON with 200/503 proves the
route works; three failures trigger a connector restart. A recovery 503 must not
restart the lease authority. Stop/quit cancels retries and terminates the helper.

The helper is a pinned universal resource with both upstream archive digests
verified. Application builds require no Homebrew, connector download, external
proxy, root access, or connector installation. Xcode resolves the pinned DuckDB
Swift package when it is not cached. Setup remains user initiated and the
listener stays on IPv4 loopback for managed access. No live tunnel, login item,
power setting or remote Mac was changed during development.

## Software updates

Ruru embeds Sparkle **2.9.5**, matching SwiftMiner, through its native Swift API.
The app owns one updater for its lifetime. Settings drafts expose Stable/Beta,
background prompts and automatic downloads, with Check for Updates also in the
application and menu bar menus. Background checks default on; automatic downloads
default off. Sparkle owns its scheduler and persisted update preferences; there
is no second polling timer. A separate Ruru preference selects the channel.

ShipHook owns release signing, publication and appcast items. The stable feed is
`https://johnwatso.github.io/ruru/appcast.xml`; beta uses `/ruru/beta/appcast.xml`.
`docs/` holds the source feeds for publishing, initially empty. The ShipHook
Ed25519 public key is pending; the build setting `SPARKLE_PUBLIC_ED_KEY` is empty
and the updater cannot start until a valid public key is embedded. No private
release key or local signing pipeline is part of this repository.

Downloaded updates follow Sparkle's normal install-on-quit behavior. Ruru does
not copy SwiftMiner's mining-specific forced/scheduled restart policy. A requested
update relaunch waits for listener/connector shutdown, and ordinary termination
also awaits shutdown. Durable terms, lifetime locking and restart quarantine
remain owned by WitnessKit. Update checks do not restart the authority. Preview
mode never starts Sparkle, checks feeds or writes updater preferences.

## Native console

The console combines SwiftBot's current Overview design with SwiftMiner's
compact sidebar. It uses shared large page headers, quiet rounded surfaces,
inset settings rows, status capsules and service cards. `WitnessConsoleStyle.swift`
and `WitnessSidebar.swift` adapt those views locally; the witness has no
build/source dependency on either app or a UI framework.

Overview summarizes the authority and all guarded services. Guarding lists
configured services and opens each service’s owner/term/countdown, known servers,
connection details and scoped activity. Coordination starts with app/service
cards; each opens its own feature settings, connection details, resource locations
and fresh/stale reports. Service creation is shared with Guarding. Internet Access
owns Cloudflare setup, public/local transport and
pause/resume. Activity keeps its search/header above a scrolling ownership
history. Settings is a separate SwiftUI Settings window with SwiftMiner-style top
icon tabs for General and Updates. General groups app presence and startup;
Internet Access owns the connection settings sheet. Preferences share the lifetime
app model/updater and apply each change immediately; saves are serialised and
failures restore the saved value. Each window saves only its own fields, preserving concurrent preference/connection edits. Settings → Backup
owns snapshots, export and the explicit restore described in STORAGE.md. Ruru follows the
system appearance; an `appearance` key saved by earlier builds is ignored and
dropped on the next save. The app menu (⌘,) and menu bar open the same
preferences window without changing console navigation. About Ruru (app menu
and menu bar) opens the standard About panel. Connection and API
credentials stay in sheets. Navigation identity follows the selected
page, while service lifetime remains owned by the app model.

All UI uses macOS 15 APIs; macOS 26-only glass effects/buttons are not used. The
console preserves lease fencing, Keychain accounts and Cloudflare provisioning.
Display metadata is isolated from lease identity as described above.
SwiftBot service rows and detail headers use locally bundled light/dark app
logos; other application kinds retain a generic icon.

Launch with `--preview-screenshots` for stable screenshot fixtures, including
Home Mac/Backup Mac ownership history and `https://gaurd.ruruapp.dev`. This flag
enables preview isolation for both the model and updater. Running/connected
status is simulated without opening storage, loading credentials, starting a
listener/connector, provisioning Cloudflare or registering login items.
Copied UI-test bundles can also set `RuruScreenshotPreview=true` in their plist
to preserve this isolation when UI tools relaunch without arguments. This key
is absent from normal generated app/Release configuration.

## Deployment preference

The intended SwiftBot deployment uses one Ruru authority on one server. The
operator prefers this simpler arrangement for a basic Discord bot; additional
Ruru servers or replicated authority infrastructure are outside the current
scope. The selected SwiftBot service lease length is five minutes (300 seconds),
configured through Guarding on the deployed authority, rather than changing the
default for every service.

The current Primary can continue within its last confirmed lease while Ruru is
unreachable. It stops guarded work when that permission expires; a Standby
cannot acquire ownership while Ruru is unavailable. A longer lease also delays
takeover after a Primary failure. After Ruru restarts, the full longest persisted
lease quarantine starts at launch, so even a brief authority outage can cause a
gap before grants resume. This choice does not introduce indefinite continuation
past expiry.

## Guarded services

SwiftBot is the initial service, preserving its existing cluster ID, bearer
Keychain account, saved server names and durable database. Additional SwiftBot
groups or other applications can be added in Guarding. A service has a stable
metadata ID, display name, application kind and unique protocol cluster ID. The
app admits up to 32 configured services on the same listener/database and tunnel;
there is no two-participant limit within a service. Each cluster has its own term
and owner. Credentials are stored only in Keychain, never in service metadata.

Adding a service persists its token and metadata before updating listener
admission. It does not restart the listener, tunnel, store or clock epoch, nor
change existing leases. Renaming a service/server is cosmetic. Settings drafts
preserve catalog updates. Additional service cluster IDs are fixed after setup;
removal revokes admission while retaining durable leases, terms and history.
Any service can be removed, and that state survives relaunch. An empty catalog serves health but admits no leases. Already granted
permission expires normally within the service's lease length. Re-adding the same cluster uses
a new token and the existing lease/term, preserving fencing. Inactive Keychain
items are retained but are not loaded/admitted. Removal works during a database
startup failure and never resets storage. Other services and the authority epoch
remain intact. Settings drafts cannot resurrect a removed service.

Activity snapshots include the existing database cluster column and all 256
retained transitions. Known servers combine successful ownership history with
authenticated presence reports in a separate bounded in-memory actor. Updated
clients report every 15 seconds even in standby. Contact is fresh for 45 seconds,
stale until 600 seconds, then discarded; restart clears it. Current ownership is
always derived from the lease, while reported roles remain self-reported. Old
clients without reports show unknown presence. The capability shares the four
metadata-request slots and preserves the lease schema, commit path and deadlines.
See [participant presence](INTEGRATIONS.md#participant-presence-v1). Independent
uptime probes and automatic application discovery remain future work.
Other apps must implement the lease protocol and stop output before their local
monotonic permission expires; see [integrations](INTEGRATIONS.md).

Per-service Primary preferences are non-secret settings keyed by stable service
metadata ID. Selection/clearing checkpoints and synchronizes configuration
before updating the live router. The router publishes a validated immutable
policy alongside each admitted service credential; updating it preserves the
store, epoch, terms and live leases. Service removal deletes its preference and
revokes reads. New clusters from SQLite replacement start without preferences;
changing the initial service's cluster clears its preference. Settings drafts
preserve concurrent preference edits. Node IDs remain independent from names,
observed history and current ownership. Compatible clients implement failover
and coordinated return; the authority never forces a transfer.
