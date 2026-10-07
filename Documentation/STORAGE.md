# Ownership and storage

- `POST /v1/lease/acquire`, `/renew`, and `/release` use SwiftBot's existing JSON
  protocol and require `Authorization: Bearer …`.
- Only explicitly configured service clusters are admitted. Each has a separate
  bearer token, independent term, and one live owner. Cross-service credentials
  and unconfigured clusters are rejected.
- Only one live owner per service is granted. The lease lasts 30 seconds; SwiftBot renews
  every five seconds and applies an earlier local monotonic output deadline.
- Ownership terms never decrease. Grants are acknowledged only after the DuckDB
  transaction commits to persistent storage. Lost/corrupt storage
  fails closed; the app never silently resets an existing authority.
- A process restart with outstanding ownership waits a full lease before new
  grants. Repeated restarts do not skip that wait; earlier clock epochs are never
  treated as active leases. An instance lock prevents simultaneous authorities
  using the same database.
- The last 256 ownership transitions are retained; renewals are not logged.
  Logs contain node IDs and terms, never bearer credentials or bot data.
- `GET /health` exposes only readiness, with 503 during recovery/storage failure.

Non-secret settings live in `~/Library/Application Support/Ruru/`; the live
`leases.duckdb`, its markers, locks and archives live in its `Authority/`
subfolder. The bearer token stays in Keychain. An initialization marker prevents
a missing database from silently becoming a fresh authority after restart.
Preserve it and the database's terms across updates. **Never copy an older
ownership database back into place**; it would reissue terms bots have seen.

## Backups

- `Authority/` is excluded from Time Machine, so a Time Machine or Migration
  Assistant restore cannot roll back terms. `authority-created`, beside the
  settings, is backed up: if it exists while `Authority/` has no initialized
  database, startup fails closed and points to Restore from Backup.
- While the authority is open, Ruru writes a daily secret-free lease snapshot
  (terms, last owners, history and reported names) to `Snapshots/`, keeping 14.
  Snapshots are in Time Machine. Settings → Backup can also snapshot on demand.
- **Export** writes one JSON file: settings plus a fresh snapshot (or the newest
  file if the database is unavailable). It omits bearer tokens, Cloudflare
  credentials and the Cloudflare tunnel identity.
- **Restore** accepts an export or a bare snapshot. It stops the service, reads
  and checkpoints current terms through the live store, closes it, then takes
  both lifetime locks. It builds `leases.restoring.duckdb` beside the live file,
  moves the current database/WAL to `Authority/Restore Archives/<time>/` (copying
  the marker), and renames the rebuilt file into place. Every service's term is
  `max(backup, current) + 1,000,000`; leases are ownerless with a non-zero expiry,
  so the next open applies the full 30-second restart quarantine. Ownership and
  deadlines are never restored. An interruption leaves the marker without a
  database, which fails closed; repeating the restore is safe. Settings import
  keeps this Mac's tunnel and listener. Existing Keychain tokens are reused;
  services without one get a new token and must be paired again.
- Restore requires that no other authority for those services is running. Ruru
  cannot verify that; the confirmation sheet asks for it explicitly.

The bundle identifier and Keychain service are `dev.ruruapp.ruru`; data lives in
`~/Library/Application Support/Ruru/`. Before any deployment these replaced
`com.swiftmesh.witness` and `SwiftMeshWitness` without migration. The repository folder is `ruru`, the Xcode project and scheme are `Ruru`,
and the application product is `Ruru.app`. The DuckDB retired-SQLite marker keeps its
original `SwiftMeshWitness` text, because it is compared byte-for-byte.

This version deliberately does **not** migrate SQLite leases, names or history.
If old SQLite storage or its initialization marker is present, startup refuses
to create an empty authority. Stop and unpair every participating client, then
choose **Set Up DuckDB**. The explicit flow archives SQLite files/sidecars/marker,
retains both lock paths, retires older binaries, checkpoints fresh cluster IDs
and tokens, and creates a new DuckDB authority. It stays stopped until you start
it and re-pair clients. Existing, damaged or interrupted DuckDB storage cannot
be overwritten by this flow. Do not run the old app
afterward. Fresh DuckDB installs also write a safety marker that prevents older
app binaries from initializing a competing SQLite authority. No live installation is reset by
the build or tests.

Removing a guarded service revokes grants and renewals without deleting durable
leases, terms or history. Existing permission expires within 30 seconds.
Re-adding its cluster uses a new token and retains fencing against the former
owner. Inactive Keychain items are retained but not admitted. SwiftBot removal
is persisted; an empty catalog rejects all lease requests and still serves
health. Catalog removal works during startup failure and never resets storage.

DuckDB Swift is pinned to **1.1.3**, the latest stable tag in the official Swift
repository at implementation time. Newer upstream Swift tags are development
versions. Xcode resolves and compiles this dependency; runtime operation requires
no package manager or downloaded extensions. The authority uses one connection,
two DuckDB worker threads and a 128 MB database memory budget (not a total process
memory limit). Target-Mac resource measurements remain outstanding.

The witness fences permission to act. Discord does not enforce its fencing
tokens; an already-sent request may complete. There is no exactly-once external
effect guarantee. If this one witness is unreachable, exclusivity takes precedence
over continued bot availability.
