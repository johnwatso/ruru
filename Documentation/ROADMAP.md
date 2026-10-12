# Development log and next steps

## 2026-10-12 — SwiftBot planned session-end handoff

- Participant presence can carry an optional `sessionEnding` flag. Ruru's Known
  Servers view displays a fresh system logout/power-off notice; it remains an
  ephemeral observation and does not affect lease authority.
- SwiftBot listens for macOS's workspace will-power-off notification. During
  app termination it cancels periodic presence, reports the notice, drains and
  saves local work, then releases the Ruru lease through the existing route.
  Failed drain/save skips early release so the normal lease deadline applies.
- Updated the typed RuruClient and API/operations documentation. Debug builds
  of both Ruru and SwiftBot passed, and `git diff --check` is clean. Tests were
  not rerun after this lifecycle extension; live logout/power-off remains
  unexercised.

## 2026-10-12 — Participant UPS telemetry contract

- Added optional power-source, external-power, battery percentage and estimated
  remaining-time fields to participant presence v1 and its typed RuruClient API.
  Reports replace prior snapshots, numeric ranges are bounded, and the fields
  remain ephemeral display metadata independent of lease and authority state.
- Updated integration/OpenAPI documentation and real-server client conformance
  coverage. SwiftBot's power-source reader and participant-card UI are being
  handled in the parallel integration lane; no live UPS or production service
  was accessed for this contract change.
- Claude reported 153 Ruru and 926 SwiftBot tests passing for the UPS integration
  before this shutdown flag was added. The current Debug builds also pass; no
  physical UPS state was exercised.

## 2026-10-12 — Transport diagnostic foundation and client contract coverage

- Added a bounded, read-only transport diagnostic backend. It independently
  checks the loopback listener and public `/health` route, carries the
  connector's retry/last-public-success telemetry, and distinguishes ready,
  recovery, unreachable and unconfigured hops. It performs no connector
  lifecycle action and cannot touch lease, storage, authority epoch or service
  state. Native UI wiring is intentionally serialized after the concurrent UI
  changes settle.
- Extended real-server RuruClient conformance coverage for public readiness
  and the fact that restart quarantine refuses an otherwise-valid renewal as
  well as a new acquisition. Release/publish remains deferred: no tag or
  remote change was made.
- Added [the operator runbook](OPERATIONS.md) for the two-client failure drill,
  restart quarantine, UPS/network path and immutable-backup rules. The drill
  is a manual acceptance activity and has not been run against live Macs.
- Validation: XcodeGen, `git diff --check`, the Debug build and the full Xcode
  suite passed. No live tunnel, client, Keychain, database, pairing or network
  state was changed; the documented two-Mac/WAN drill remains outstanding.

## 2026-10-12 — Public RuruClient package foundation

- Added a public SwiftPM manifest at the repository root. The Ruru repository
  now exposes only the application-neutral `RuruClient` library product; the
  native macOS authority remains an Xcode project and is not a package product.
  Remote SwiftPM clients can therefore depend on the versioned Ruru repository,
  which is not possible from a nested package manifest.
- Ruru's Xcode project retains a matching nested client manifest for its local
  dependency. Pointing that project at the root manifest makes Xcode resolve
  the project as its own package and creates invalid `.swiftpm/xcode` metadata.
  The root manifest is for external consumers only; the generated empty
  metadata directory was removed before regenerating the project.
- Added client package documentation covering dependency setup, fencing and
  deadline obligations, semantic-versioning expectations and the release gate:
  the client unit suite plus Ruru's real-server conformance tests must pass.
  The repository README and `Documentation/INTEGRATIONS.md` identify the root
  manifest and product.
- SwiftBot is the intended first adopter. Its existing `MeshWitnessClient` will
  be replaced in a dedicated migration after RuruClient receives a published
  release tag; its app-specific orchestration and persistence remain outside
  the shared package. No SwiftBot source or configuration changed here.
- Validation: XcodeGen, `git diff --check`, Ruru Debug build and the full Xcode
  suite passed (150 tests) with the root package resolved as a local dependency.
  No GitHub tag/release was created and no production/test authority, Keychain,
  pairing, tunnel or service configuration was changed.

## 2026-10-11 — Redacted authority diagnostics

- Added an on-demand plain-text diagnostic report, available from Settings →
  General and the menu bar. It captures the local authority state, bounded lease
  history, per-service lease/capability counts and current participant freshness
  using the snapshots already maintained by the app; it does not introduce
  probes, client metadata fields, durable telemetry or database reads.
- Report labels are local aliases. It excludes bearer tokens, Keychain values,
  Cloudflare credentials, endpoints, reported URLs, hostnames and raw error
  text. Export uses the standard macOS save dialog and reveals the saved file in
  Finder.
- Validation: XcodeGen, `git diff --check` and the full Xcode suite passed
  (150 tests), including report content, bounded-history fields, redaction
  guarantees and the UTC filename. The standard save-dialog flow has not yet
  been exercised manually in a live app window; no production storage,
  Keychain, listener, tunnel or login setting was changed.

## 2026-10-11 — OkiDoki review and retained diagnostics ideas

- Reviewed OkiDoki's ten-commit prototype against Ruru. Its heartbeat shell,
  Cloudflare setup, client scaffolding and general coordination direction are
  superseded by Ruru. No runtime code was imported. Its healthy-peer count is
  not independent failure confirmation, and its in-memory terms and wall-clock
  freshness must not replace Ruru's durable lease fencing or monotonic expiry.
- Archived [OkiDoki](https://github.com/johnwatso/OkiDoki) on GitHub after
  publishing a README notice that Ruru supersedes it. Updated its description
  and homepage to point to Ruru; source and commit history remain available.
- Retained optional future diagnostics from OkiDoki's node model: reported
  application name/version, process uptime and explicitly self-reported
  connectivity observations. These may help explain mismatched client versions,
  recent process restarts or a participant's view of an outage. They are backlog
  ideas, not implemented fields or permission to promote a node.
- If a concrete integration needs them, extend application-neutral participant
  reporting with bounded optional metadata and feature discovery. Preserve old
  clients, the 4 KiB request limit, service isolation, monotonic freshness and
  expiry on restart/removal. Omission should withdraw prior values; label unknown
  or stale observations clearly. Do not add coordinator probes, arbitrary host
  labels, machine identifiers or URLs just to populate diagnostics.
- Before shipping, validate metadata bounds/invalid values, older-client
  compatibility, withdrawal/freshness/restart, cross-service authorization and
  lease renewal latency under reporting load. Uptime is reported telemetry, not
  proof of liveness; connectivity reports never change lease ownership.
- Validation for this review: local source/history and live GitHub metadata
  checked; main matched the clean local checkout, with no other remote branches,
  PRs, issues, tags or releases. Documentation-only change; no app build, live
  deployment or new diagnostics implementation was performed.

## 2026-10-09 — Single-server deployment preference

- Recorded the operator's choice of one Ruru authority and a five-minute
  SwiftBot lease. Additional Ruru servers and authority replication are outside
  the current scope; existing expiry and restart quarantine remain required.
- This is a documented deployment choice. The deployed Mac mini's service
  setting has not been changed from this workspace. Existing Guarding controls
  already support 300 seconds; no runtime or global default change was needed.
- Validation: documentation diff checked; no executable changes in this entry.

## 2026-10-09 — Failover safety review and outstanding-grant fixes

- Reviewed authority exclusivity, durability, expiry, restart quarantine,
  instance locks, restore, service admission, observation/preference separation
  and listener/tunnel lifecycle against the existing primary design references.
  Recorded evidence and operational limits in [the review](FAILOVER_REVIEW.md).
- Fixed lease shortening: renewals retain earlier outstanding permission and
  its persisted quarantine length, even if the shorter renewal reply is lost.
  Invalid stored durations now fail startup closed.
- Hardened RuruClient against stalled renewals, expired/damaged replies and
  mismatched renewal terms; added a stopping margin and awaited stop/drain before
  cancellation releases. The Python example independently expires its worker
  during blocked HTTP, updates renewal deadlines, and has isolated CI checks.
- Validation: final full Xcode suite/build passed with 148 tests, including the
  cancellation-during-renewal regression; 4 Python example tests passed. Universal
  Release passed; app and WitnessKit contain x86_64 + arm64, with macOS 15.0
  verified on all four slices. XcodeGen and `git diff --check` passed.
  No production settings/data or SwiftBot code changed. Real two-Mac partitions,
  suspend/resume, power loss and Intel/Sequoia hardware remain unverified; Ruru
  remains a single authority whose outage pauses guarded work.

## 2026-10-09 — New owner's Web UI in failover alerts

- Participant presence v1 accepts an optional bounded HTTPS `webUIURL` origin,
  independently of catalogue sharing. Credentials, queries, fragments and
  non-root paths are rejected. Omission withdraws a URL, and it disappears from
  stale reports after 45 seconds; restart and credential revocation clear it.
- SwiftBot reports its own configured website, including in standby; RuruClient
  exposes the optional URL too. Failover and recovery embeds show a clickable
  Web UI domain from the fresh current-owner report, matched by cluster/node ID.
  Alert transitions now compare stable node IDs, so duplicate names work and
  cosmetic renaming cannot look like failover. Lease routes/storage are unchanged.
- Updated API/integration docs and all eleven local embed previews. The URL is
  reported metadata, with no reachability claim or background probe. Both apps
  need updated builds for SwiftBot website reporting; older clients remain valid.
- Validation: Ruru's full 138-test suite passed, plus final build/11 alert tests;
  SwiftBot build/22 mesh tests passed. Tests cover website validation, freshness,
  withdrawal, node identity and lease isolation. SwiftBot's final build and all
  22 mesh tests also passed after the formatting fix. All eleven previews passed
  light/dark and narrow-layout checks. Final Release build passed; app and
  WitnessKit contain x86_64 + arm64, and both app slices target macOS 15.0.
  Live Discord/two-Mac failover and actual Intel/Sequoia execution remain unverified.

## 2026-10-08 — Clearer Discord webhook embeds

- Added event icons, severity colours (including blue informational messages),
  category footers and timestamps. Service alerts show the service plus last,
  previous or current owner; failover owners sit side by side. Pairing requests
  show the service and requesting server with a short approval instruction.
- Embed descriptions avoid repeating the names in the fields. Native
  notification wording is preserved. Names and details are escaped for Discord
  formatting, long Unicode text is truncated with an ellipsis, empty fields are
  omitted, and payloads remain bounded with mentions disabled.
- Updated Discord setup copy to explain the names included in alerts.
- Validation: Debug build and all 135 Xcode tests passed; the final description
  changes passed a build and all 9 focused alert tests. Release build passed;
  app and WitnessKit binaries contain x86_64 + arm64, with macOS 15.0 verified
  on both app slices. No live Discord post, client-rendering check or execution
  on Intel/Sequoia hardware was performed.
- Follow-up: rendered all eleven message examples from the actual payload
  serializer in a local Discord-style preview. Inspected light/dark renders and
  checked all examples at 360px and 768px without horizontal overflow or script
  errors. Screenshots are in `.artifacts/webhook-preview/`; exact Discord client
  layout remains unverified.

## 2026-10-08 — Standby participant visibility

- Added application-neutral `participantPresence` v1 discovery and authenticated
  `/v1/participants/report`, independent of lease acquisition. A bounded actor
  holds 32 nodes per service, uses monotonic 45-second freshness/600-second
  retention, starts empty after restart, and clears removed/rotated scopes.
  Presence shares the existing four metadata connection slots; the durable lease
  schema, terms, quarantine and commit path are unchanged.
- Known Servers combines reports with ownership history, shows Current owner
  separately from reported role/recent contact, and displays Last seen, Contact
  stale or Presence unknown. RuruClient exposes `reportPresence(role:)`; SwiftBot
  now sends reports from its monitoring loop on both Primary and Standby, with
  feature detection for older Ruru versions. Both apps need updating for standby
  presence; re-pairing is not required when the service credentials are unchanged.
- Validation: full Ruru suite passed (133 tests), including a real server/client
  standby report while another node holds ownership, unchanged term/renewal,
  scope authentication, validation, bounds, freshness, revocation and mixed
  presence/catalogue load with lease renewals. The first run hit the existing
  restart conformance test's asynchronous lock-release race; isolated recheck and
  the final full run passed. After the client error-mapping change, all 22 focused
  conformance/presence/coordination tests also passed. Final Debug and universal
  Release builds passed; app and WitnessKit contain arm64/x86_64 with a 15.0 app
  deployment target. SwiftBot's final isolated build and 21 mesh tests passed.
- Native preview verified owner, fresh standby and stale contact rows, plus
  details for a node with no ownership history. Server details use a sheet so
  rows remain usable when Activity is below the viewport. The animated lease
  has one stable accessibility label, avoiding the observed macOS 27 label
  recursion; preview renewals now update every second and refill every five.
  Screenshot: `.artifacts/participant-preview/standby-presence.png`.
- UI tooling briefly relaunched a preview without its arguments and opened the
  existing local development authority data. Copied test bundles can now carry
  `RuruScreenshotPreview=true` to retain model/updater isolation on relaunch;
  the Release plist was checked and does not contain it. No remote Mac,
  credentials, login item or tunnel was changed. Actual deployment to the user's
  Macs and Intel/Sequoia execution remain unverified.

## 2026-10-08 — Setup assistant, Cloudflare domain picker and needs-attention list

- First launch opens a setup assistant scoped to getting Ruru itself working
  before any servers: Welcome; Public Address; Keep Ruru Running (login item,
  auto-start, notifications, Discord); Ready (status checklist and Add Your
  First App). Apps and pairing happen afterwards in Guarding.
- Cloudflare setup now starts from the token: it lists the token's domains
  (zones), you pick one and a subdomain, and Ruru connects. The separate
  `/user/tokens/verify` call is gone (it rejects account-owned tokens and had a
  5-second timeout); listing zones is the check, and the header-injection guard
  moved there. Cloudflare transport errors are readable ("didn't respond in
  time", DNS, offline), reads retry once on timeout, every provisioning failure
  names its step, and the tunnel health probe allows 15 s. After provisioning,
  Ruru waits up to 90 s for the connector to register; if it doesn't, the error
  includes the connector's last output lines with long tokens redacted. The
  Internet Access sheet uses the same flow.
- Steps resume from real state; `setup.completed` and `setup.localOnly` are the
  only stored progress. Finish Later leaves a "Finish setting up" item on
  Overview; More → Run Setup Assistant… reopens it.
- Overview's summary lists what needs attention, each with one fixing action:
  finish setup, Ruru stopped, no public address, no services, a service without
  servers, servers waiting to pair.
- Validation: full suite passed (129 tests, zero failures), including domain
  listing, no use of the user-only verify endpoint, step-named failures and the
  header-injection guard. Clicked through every step in `--preview
  --preview-setup` (domains and connection simulated). Not exercised: a real
  Cloudflare account. The original timeout on the Mac mini was not reproduced
  here; the likely causes (5 s token check, unnamed URL timeouts, a connector
  that never registered with no explanation) are addressed, and a repeat will
  now say which step and why.

## 2026-10-08 — Pairing codes

- Connection Details → Pair a Server creates a single-use, 10-minute code
  (8 characters from an unambiguous alphabet, shown as `XXXX-XXXX`). A server
  sends it to unauthenticated `POST /v1/pair`, which uses it up and creates a
  pending request; Ruru notifies the operator, who approves or rejects it on
  the service page or in the sheet. Only then does `POST /v1/pair/status`
  return the cluster ID, token and lease length, once.
- Bounds: 8 live codes, 16 pending requests, 10 wrong codes per minute before
  a one-minute pause. Codes and requests are in memory only; removing a
  service revokes them.
- RuruClient gains `RuruPairing.pair`. OpenAPI and INTEGRATIONS.md document it.
- Validation: full suite passed (126 tests, zero failures), including an
  end-to-end test where RuruClient pairs with the real server, is approved, and
  acquires a lease with the received credentials. Checked the sheet in the
  isolated preview. SwiftBot does not support pairing codes yet; it still
  needs the manual details until it adopts `/v1/pair`.

## 2026-10-08 — Lease shown as a one-time code

- Replaced the service detail's 30-second progress bar (which twitched between
  full and nearly full on every renewal and ignored per-service lengths) with a
  Passwords-style display: the term as grouped monospaced digits and a smooth
  countdown ring with seconds inside, coloured by renewal health.
- The screenshot preview now simulates a renewal every 5 seconds.
- Reduced Preferred Primary from its own panel to one compact row under Known
  Servers with a Change menu; its explanation moved to a tooltip.
- Debug build passed; checked in the isolated preview in light and dark.

## 2026-10-08 — General-purpose services, client package and alerts

- **Equal services.** Removed the built-in SwiftBot service (fixed `swiftbot`
  ID, top-level cluster ID/name/removed flags, special Keychain account,
  `swiftmesh` default). Settings hold one `services` list; a fresh Ruru has
  none. `kind` is a template only; SwiftBot keeps its app icon. Keychain
  accounts are `service-<id>`. Pre-release settings without `services` are
  rejected rather than read as empty (no migration; nothing deployed).
- **Per-service lease length** (10–300 s, default 30), editable without
  interrupting the owner. Each grant stores its length; restart quarantine
  waits out the longest stored grant. Restores use 300 s because the previous
  authority's lengths are unknown.
- **Per-service history**: 256 events kept and 64 shown per service.
- **`GET /v1/service`**: capabilities, lease length, recovery and current lease
  for the caller's token only.
- **RuruClient** Swift package (`Clients/RuruClient`) with `maintain`, fencing
  deadlines measured from send time, and release on cancellation from an
  uncancelled task (a real bug the conformance tests caught). OpenAPI
  description, Python example and a conformance checklist in INTEGRATIONS.md.
- **Alerts**: service down (no takeover within 15 s), failover, and Ruru
  problems (listener, tunnel, snapshots), each with a resolved message. Planned
  releases, stops and restart quarantine never alert. Delivered to macOS
  notifications and an optional Discord webhook (official Discord hosts only,
  stored in Keychain, no mentions, repeats suppressed for a minute). New
  Settings → Alerts tab with Send Test.
- **Naming**: user-facing "witness" text, the Cloudflare tunnel name
  (`ruru-<id>`) and the auth context string now use Ruru.
- **CI**: GitHub Actions on macOS 15 runs the suite, the package tests and a
  universal Release build with architecture and deployment-target checks.
- **Docs**: integration guide rewritten for any app, including behaviour when
  Ruru is unreachable and a Cloudflare rate-limiting recommendation.
- Validation: full Xcode suite passed (121 tests, zero failures), plus
  4 RuruClient package tests; local universal Release build verified x86_64 +
  arm64 at macOS 15.0. `CoordinationTests.testSlowCatalogueConnectionsLeaveRoomForLeaseRequests`
  failed once under full-suite load and passed alone three times (timing-
  sensitive; unchanged code). Not exercised: real notification delivery, a real
  Discord post, CI on GitHub's runners, and the Intel Mac mini.

## 2026-10-08 — Backups, snapshots and safe restore

- Moved the live lease database into `Application Support/Ruru/Authority/`,
  excluded from Time Machine. A backed-up `authority-created` marker makes a
  later missing database fail closed instead of starting at term zero.
- Added daily secret-free lease snapshots (`Snapshots/`, newest 14), Export
  (settings + current terms/history, no tokens or tunnel identity) and Restore
  from an export or snapshot. Restore archives the current database and
  rebuilds it with every term raised to `max(backup, current) + 1,000,000`,
  ownerless, so the next open quarantines for a full lease. LeaseStore now
  quarantines on any non-zero stored expiry (released leases store 0).
- New Settings → Backup tab with a confirmation sheet requiring explicit
  acknowledgements.
- Debug build and full suite passed (106 tests, zero failures; 8 new backup
  tests cover raised terms, quarantine, archives, a missing database, an open
  authority, damaged/foreign files, tunnel stripping, rotation and the
  fail-closed marker). Checked the Backup tab layout in the isolated preview,
  where actions are disabled. Not exercised: Export/Restore panels and the
  restore sheet in a real (non-preview) run, Time Machine itself, and
  SwiftBot's behaviour on a +1,000,000 term jump.

## 2026-10-08 — App presence picker replaces Appearance

- Removed the System/Light/Dark Appearance picker; Ruru always follows the
  system appearance. An `appearance` key saved by earlier builds is ignored and
  dropped on the next save (new test covers decoding and re-encoding).
- Replaced the Show in Dock switch with an Otter-style “Show Ruru in” picker:
  Dock + Menu Bar or Menu Bar, with a selection-specific description. It still
  stores `showInDock`, so existing choices carry over; no Dock-only mode.
- Debug build and full suite passed (98 tests, zero failures); checked the
  General tab in the isolated preview.

## 2026-10-08 — dev.ruruapp.ruru bundle identifier

- Changed bundle identifiers to `dev.ruruapp.ruru` (app), `.kit` and `.tests`;
  internal queue labels to `dev.ruruapp.ruru.*`; Cloudflare User-Agent to
  `Ruru/0.2`. Regenerated the project with XcodeGen.
- At the owner's request (no deployments yet), also renamed the Keychain service
  to `dev.ruruapp.ruru` and the data folder to `Application Support/Ruru`, with
  no migration. Development data under `SwiftMeshWitness` and Keychain items for
  `com.swiftmesh.witness` are left untouched and unused; delete them manually.
- Debug build and full suite passed (98 tests, zero failures); built Info.plist
  reports `dev.ruruapp.ruru`. Keychain access prompts on an existing install and
  Release/universal signing were not verified.

## 2026-10-08 — Instant-apply Settings and standard About panel

- Settings now applies each change immediately and the Save/Revert bar is gone.
  Preference saves run one after another and write the latest values, so quick
  edits cannot trip the model's single-save guard; a failed save shows an inline
  warning and restores the saved value. Launch at login reflects the real
  registration state after each change. Update preferences apply directly.
- Removed the About tab. About Ruru (app menu and menu bar menu, since the app
  menu is hidden without a Dock icon) opens the standard About panel with a
  Release Notes link.
- Debug build and full suite passed (98 tests, zero failures). In
  `--preview-screenshots`, choosing Dark applied instantly and the About panel
  opened from the app menu. The menu bar About item was reviewed in code only.
  Login registration and live Sparkle preference writes were not exercised.

## 2026-10-08 — Native grouped Settings layout

- Rebuilt the Settings window tabs as native grouped forms instead of nested
  console cards: leading labels with secondary descriptions, trailing switches,
  pickers and buttons, section footnotes, and a 540pt window that sizes to each
  tab. Updates uses a channel menu plus a Last checked/Check Now row; About shows
  the app icon, version and build. Save/Revert is a compact footer, hidden on
  About unless a draft is pending. Draft and save behaviour are unchanged.
- Debug build and the full Xcode suite passed (98 tests, zero failures). Checked
  all three tabs in light and dark appearance with `--preview-screenshots`.
  Sequoia/Intel rendering and a universal Release build were not re-verified
  for this layout-only change.

## 2026-10-08 — Separate native preferences window

- Moved Settings out of the console sidebar into a native SwiftUI Settings scene,
  following SwiftMiner’s compact top icon tabs. General (appearance and startup),
  Updates and About share one draft with persistent Save/Revert controls. The
  application menu (⌘,), menu bar and Overview actions open the preferences
  window without changing console navigation. Operational connection controls moved
  to Internet Access → Connection Settings in the console. Each save applies only
  its own fields, preserving edits saved in the other window. The app model and
  updater remain shared with the main window and lifetime menu bar service.
- Added a saved System/Light/Dark appearance preference, defaulting to System for
  existing configurations. Appearance and Dock visibility apply on Save without
  restarting the listener or tunnel. Retained startup/login controls, connection
  settings and the existing Stable/Beta and background update preferences.
- XcodeGen, Debug and universal Release builds passed. The full Xcode suite passed
  with 98 tests and zero failures before the final tab regrouping/connection move;
  the final presentation was rebuilt and verified manually. New temporary-storage coverage verifies appearance
  persistence while preserving service identities and policies; legacy decoding
  retains System appearance. `lipo` confirmed x86_64 and arm64 in the app and
  WitnessKit framework; both app slices target macOS 15.0. Sparkle’s read-only
  preflight passed with the expected missing publishing public key.
- Checked the actual native preferences window in an isolated preview: ⌘, and
  application-menu opening/reopening, General’s combined appearance/startup
  controls, tab drafts, Revert, Save via ⌘S, light/dark appearance and disabled
  preview update controls. Checked the relocated Connection Settings sheet and
  verified a saved connection edit survives saving a pending General draft.
  Closing preferences preserved console navigation. Screenshots and build/
  test logs are retained under `.artifacts/settings-preview` and `.artifacts`.
  Menu-bar opening with the main window closed was reviewed in code, not verified
  independently through the UI automation. Intel/Sequoia execution, live feeds
  and installation remain unverified. Final builds used signing disabled after
  Finder metadata on cached Debug bundles blocked local Xcode signing; the manual
  preview used an ad-hoc-signed temporary copy outside Documents. No production settings, Keychain, login
  items, storage, tunnels or release signing/publishing were changed.

## 2026-10-07 — SwiftBot standby status homepage

- Simplified the sibling SwiftBot standby WebUI to a separate status page for
  all visitors, selected by runtime ownership. A small public role probe restores
  the normal dashboard on takeover and removes it on demotion. Recording/media
  serving and mesh synchronization remain independent of the browser surface;
  Ruru still carries only discovery/ownership metadata.
- SwiftBot XcodeGen/Debug build and 89 focused tests passed, including new raw
  HTTP coverage for the status page, role changes, write denial and retained
  media forwarding. Checked the isolated standby preview and automatic takeover/
  demotion with a bookmarked admin page and open dialog. Screenshots retained
  under `.artifacts/standby-webui`; setup/design guidance updated. No Ruru runtime
  changes, real multi-Mac failover, deployment or production settings changes.

## 2026-10-07 — WebUI-first SwiftBot pairing review

- Redesigned the sibling SwiftBot WebUI Pair SwiftBot dialog and native Join
  confirmation. Joining starts at WebUI → SwiftMesh → Pair SwiftBot; its local
  recordings choice is carried to native confirmation and first-launch review.
  The URL hint only preselects the choice, preserving local confirmation and
  the existing pairing/lease contracts. Ruru operator approval stays explicit.
- SwiftBot XcodeGen and latest Debug build passed, along with 87 focused tests,
  inline JavaScript syntax and diff checks. Checked native dark/light confirmation,
  sharing selection, paired state, first-launch review and WebUI copy/cancel in
  isolated fixtures. Updated previews are under `.artifacts/max-pairing`.
  No Ruru runtime changes, live John/Max pairing, deployment or production
  credentials/settings changes. Previous universal Release validation still
  applies to Ruru; no new Ruru build was required for this SwiftBot UI work.

## 2026-10-07 — Max-side pairing preview

- Added an isolated Debug screenshot scenario in the sibling SwiftBot checkout,
  using its actual native Join confirmation and synthetic connection details.
  Verified sharing selection, Max's own website and paired/Done state; screenshots
  retained under `.artifacts/max-pairing`. SwiftBot XcodeGen/Debug build passed.
- Preview actions use only in-memory fixture state. No Ruru runtime changes,
  deployed pairing, production credentials or first-launch onboarding checks.

## 2026-10-07 — Recording sharing during failover pairing

- Added application-neutral authenticated origin enrollment using the existing
  service connection. Clients can propose a website while reporting is off;
  proposals cannot grant access. Ruru's service cards show pending counts, and
  Website requests exposes exact-origin approval/rejection. Approval preserves
  existing origins and checkpoints the enabled policy before publishing it.
- Pending requests/rejection markers are ephemeral, capped at eight per service
  and 64 total, with fixed 600-second monotonic expiry. Token rotation, service
  removal and explicit disabling clear requests. The existing coordination
  connection quota, request bounds and lease storage/ownership protocol remain.
- SwiftBot offers a local sharing choice in Join confirmation and first-launch
  pairing confirmation, including deep links. It reuses the inherited Ruru
  connection and stable enrollment ID, requests its own website automatically,
  then reports after approval. Failover and sharing remain separate choices;
  Ruru never transports media. Updated both repositories' setup guidance.
- XcodeGen and the full Debug Xcode suite passed: 97 tests, zero failures.
  Coverage includes authentication/scope/version validation, pending/approval,
  withdrawal, rejection/expiry, token/service revocation, per-service/global
  capacity, leases with a full proposal queue, and persisted policy limits.
  SwiftBot passed 101 focused tests, including real pairing with isolated
  credentials and sharing persistence against stale settings saves. Release build
  also passed with signing disabled; `lipo` verified x86_64 + arm64 slices in
  the app and embedded WitnessKit framework, and the app targets macOS 15.0
  in both slices. Execution on Intel/Sequoia remains unverified.
- Native dark approval UI checked in a separate temporary preview bundle:
  pending card count, exact website row, approval removes the request and adds
  its allowed origin. Preview opens no storage, Keychain or listener. Actual
  John/Max connectivity, SwiftBot pairing UI visuals, Intel/Sequoia execution
  and mixed deployed versions were not exercised. Nothing was deployed;
  production credentials, storage, DNS, tunnels and releases were untouched.

## 2026-10-07 — SwiftBot combined recording libraries

- Implemented the client in the sibling SwiftBot working tree. Each sharing Mac
  reports one `swiftbot.recording-library.v1` / `library` location, using the
  existing service-scoped v1 catalogue and stable enrollment node ID. Complete
  recording lists come directly from peers, keeping Ruru's capacity independent
  of file count. Ruru's shared contracts remain application-neutral.
- SwiftBot's combined Recordings view and authenticated public media reads work
  independently of Discord ownership. Playback follows the owning SwiftBot →
  website SwiftBot → viewer. Ruru carries only endpoint/freshness metadata and
  never receives recording lists, paths, thumbnails or media bytes. Browser URLs
  cannot select the destination for mesh credentials.
- Updated architecture, coordination, client API and integration guidance;
  retained the original source review with an implementation follow-up. Setup
  and limits are in SwiftBot's `Documentation/RECORDING_COORDINATION.md`.
- Ruru XcodeGen and the full Debug Xcode suite passed: 92 tests, zero failures.
  No Ruru runtime changes were needed for this integration. SwiftBot validation
  is recorded in its own roadmap. No deployed John/Max setup, actual network
  failover, Intel/Sequoia execution or new universal Release binary was checked.
  Nothing was deployed; credentials, tunnels and release metadata were untouched.

## 2026-10-07 — SwiftBot multi-node recordings review

- Reviewed the clean SwiftBot checkout at `77152d8`: recording discovery,
  public/mesh routing, playback authentication, registrations, failover roles,
  identities and export boundaries. Recorded findings and a staged integration
  in `SWIFTBOT_RECORDINGS_REVIEW.md` and linked it from the documentation index.
- Identified missing public `/v1/media/*` forwarding, saved-role aggregation after
  promotion, browser-controlled authenticated destinations, and limitations in
  freshness, copy identity and remote exports. Ruru can supply independent
  resource discovery; SwiftBot still owns reachable authenticated media serving.
- Compared the proposal with the implemented bounded, ephemeral v1 catalogue.
  Existing query-based playback URLs, rich metadata and full-library scale need
  deliberate client/contracts work. No SwiftBot or Ruru runtime behavior changed.
- XcodeGen and documentation diff checks passed; source review was static.
  No builds, hosted tests, live
  multi-Mac reproduction, credentials, production storage, tunnel changes or
  deployments. Historical failure cause and Intel/Sequoia capacity remain
  unverified; the review lists the required integration scenarios.

## 2026-10-07 — Coordination organized by app and service

- Replaced the shared catalogue page and service picker with separate app/service
  cards. Each opens its own coordination feature settings, connection details,
  resource reports and search, with a back action to the app/service list.
  Service identity, admission policy and API scope remain unchanged.
- Added Add Service directly to Coordination, reusing Guarding’s service creation
  and credential mapping with coordination-specific presentation. Shared app
  icons preserve the SwiftBot logo. Separate groups for the same app remain
  independently configured service entries.
- Separated screenshot fixtures into SwiftBot recordings and a Build Server
  artifact service, illustrating the hierarchy without mixing resources between
  apps. Core resource/catalogue contracts remain application-neutral; future
  integrations can expose additional features within their own service pages.
- Updated architecture, design and coordinator/client guidance with the app-first
  console model. XcodeGen, Debug build and documentation diff checks passed.
  Native dark preview verified app/service cards, both scoped detail pages,
  per-service settings drafts and back navigation. The running authority was
  left untouched; inspection used a separate temporary, ad-hoc-signed preview
  bundle with no storage, Keychain, listener or updater activity.
- This is a navigation/presentation change. No automated tests were added or
  rerun; protocol/runtime behavior was not changed. Light/narrow layouts, a new
  universal Release build and Intel/Sequoia execution were not validated here.

## 2026-10-07 — Swift stale-owner fencing validation

- Added five independently written Swift regression scenarios informed by etcd's
  stale-owner example. Temporary DuckDB authorities and the authenticated JSON
  router issue real Ruru grants; a test-only cooperating resource atomically
  checks terms with its mutation. Rejected writes leave data and fence unchanged.
- Covered delayed writes after takeover at the exact expiry boundary, stale
  renew/release requests, same-node reacquisition, retained terms after authority
  restart/quarantine, and independent service term scopes. A separate scenario
  demonstrates that term comparison alone can accept expired work before the
  successor's term reaches the resource, preserving the need for client deadlines.
- Added `LEASE_REFERENCES.md` with source/license links, provenance, integration
  requirements and validation limits. No upstream source, prose or assets were
  copied/translated and no dependencies were added; the new Swift remains under
  Ruru's MIT license. Future copied adaptations must retain upstream notices.
- XcodeGen, the Debug build and the full Debug Xcode suite passed: 92 tests, zero failures,
  including all five new scenarios. The test build compiled the app and framework
  on arm64. The fixture has in-memory state; resource persistence, SwiftBot output,
  Discord effects, actual machine pauses/network partitions and Intel/Sequoia
  execution were not validated. No new universal Release build was performed.
  Runtime lease behavior, schema and wire protocol remain unchanged.

## 2026-10-07 — First general resource coordinator slice

- Added an application-neutral, versioned resource/location catalogue alongside
  lease guarding. Authenticated capability discovery, batches of up to eight
  upserts/removals and revision-checked 20-location pages are scoped by service.
  Recording and artifact examples exercise namespaces and multiple host locations
  without application-specific fields in the core.
- Operator opt-in defaults off. Saved policy uses stable service metadata IDs and
  up to eight validated HTTPS origins. Removal/re-adding cannot transfer opt-in;
  token rotation, disabling and narrower origins revoke affected observations.
  Settings drafts preserve concurrent catalogue-policy edits. Policy changes
  publish to the catalogue independently of the lease router/listener.
- Observations live in a separate bounded Swift actor with no disk/network I/O.
  ContinuousClock freshness lasts 90 seconds; locations expire after 600 seconds.
  Empty node reports cannot revive old locations. A process restart starts empty;
  listener restart in the same process preserves ageing. The lease schema,
  locks, term/ownership behavior and quarantine are unchanged.
- Added explicit per-node/service/global capacity bounds and at most four
  classified coordination connections within the existing 32 total. Request
  size and five-second deadlines remain unchanged. Unclassified connections
  still share the total budget; this is not general flood protection.
- Added the native Coordination page, service selection, Save/Cancel opt-in and
  origin drafts, resource search, URL copy and fresh/stale states. Screenshot
  mode includes recording/artifact fixtures. Native dark/light layouts, search,
  invalid-origin feedback and disabling/clearing were checked in isolated
  preview. No credentials, production storage, tunnel or login settings changed.
- XcodeGen and the Debug build passed. The full Xcode suite passed 87 tests,
  including new auth/version/isolation, monotonic expiry, namespace/location,
  paging, atomic rejection, capacity, revocation, process restart and quarantine
  cases. Loopback tests exercised 40 reports alongside 10 lease renewals and
  four incomplete metadata connections alongside a successful lease request.
  Tests caught and corrected a Swift exclusivity issue during origin pruning.
- Added `COORDINATION_API.md` with client examples, limits, trust and retry rules.
  SwiftBot reporting/playback integration is not implemented; real client
  adoption, durable catalogues, routing, replication and managed operations
  remain future work. Intel/Sequoia execution, target-Mac latency/resource
  measurements, a new universal Release build and narrow-window visual checks
  were not performed for this slice.

## 2026-10-07 — Simpler README purpose

- Removed the explicit light/dark screenshot links; the README image still
  switches automatically with the reader's appearance. Documentation diff
  checks passed; no runtime validation required for this markup change.
- Replaced the README's version-specific preview note with an early-development
  note explaining that Ruru is being designed around SwiftBot's needs and is
  highly likely to change. Documentation diff checks passed; no runtime or
  deployment validation performed for this wording change.
- Reworded the README introduction and purpose around making complicated service
  coordination easy to manage. Shortened Highlights to the main user-facing
  features while keeping the ownership explanation and preview limitations.
- Reviewed wording against the architecture and checked the documentation diff.
  Documentation-only change; no runtime tests, Release build or target-Mac
  validation performed.

## 2026-10-07 — General coordinator direction

- Recorded Ruru's intended direction as an application-neutral coordinator with
  lease guarding as its first capability. Added `COORDINATION.md` covering shared
  identities, versioned capability contracts, resource/location catalogues,
  freshness, policy and eventual managed operations. SwiftBot recordings are a
  first candidate use case, with a distinct second use case required to assess
  the shared contract before implementation.
- Added this direction to architecture, integration guidance, documentation
  navigation and repository contributor instructions so future work preserves
  lease compatibility, service isolation and bounded authority resources.
- Broader coordination remains future, low-priority work. No runtime, schema,
  protocol, UI or deployment change was made. Reviewed guidance against current
  service identities, shared-token trust and listener limits; documentation
  checks only, with no build, tests, Release or target-Mac validation required
  for this design record.

## 2026-10-07 — Overview card alignment and sidebar cleanup

- Quick Actions and System now share equal card heights in the wide Overview
  layout. Content stays at the top, leaving spare space below Quick Actions.
  The narrow stacked layout retains natural card heights.
- Removed the sidebar's Running/status badge and version footer, including
  its unused model dependency and version helper. Authority status/version
  remain in Overview and the menu bar.
- XcodeGen and the Xcode Debug build passed. Native light/dark previews verified
  equal card outlines and the empty sidebar bottom. Refreshed both cursor-free
  README Overview images and left the preview open. No automated tests,
  narrow-window visual check or universal Release validation were run for this
  UI-only change.
- Re-took both README screenshots after the final layout fix, verifying equal
  Quick Actions/System outlines, no sidebar footer or cursor, and the corrected
  `gaurd.ruruapp.dev` address. Both native captures are 2610 × 1700 pixels.
  Refreshed the dark capture again from the open preview at the user's request;
  visual inspection passed, with the light image retained.

## 2026-10-07 — Screenshot preview and SwiftBot branding

- Added `--preview-screenshots`, which independently enables isolated preview
  mode in the app and updater. It displays a running authority, stable Home Mac
  ownership, Backup Mac history, a Preferred Primary and a connected sample
  HTTPS address at `https://gaurd.ruruapp.dev`. All service and tunnel status is
  display-only; no production storage, Keychain, listener, Cloudflare setup,
  login item or updater is used.
- SwiftBot services now use locally bundled copies of SwiftBot's current light
  and dark app logos in the Guarding list and service detail header. Other app
  kinds retain their generic service icon, with no dependency on SwiftBot's
  project.
- XcodeGen and the Xcode Debug build passed. Native preview verified Overview,
  the SwiftBot logo in the list/detail header, sample owner/preference/history,
  and the Internet Access address. Left the preview running for screenshots;
  window captures omit the cursor. Automated tests, dark-mode Guarding checks
  and universal Release validation were not run for this UI/fixture change.
- Corrected the preview domain to the owned `ruruapp.dev` domain. Rebuilt Debug
  and verified `https://gaurd.ruruapp.dev` in Overview and Internet Access;
  relaunched the isolated preview for screenshots.
- Captured matching cursor-free Overview PNGs in light and dark appearance at
  2610 × 1700 pixels. README uses theme-aware picture sources with direct links
  to both images. Preview-only `--preview-light`/`--preview-dark` flags set this
  process's appearance and a consistent 1305 × 850 window; system appearance
  preferences are untouched. XcodeGen/Debug build and visual inspection of
  both captures passed. No automated tests or Release validation were run for
  these capture controls and documentation updates.

## 2026-10-06 — Per-service Preferred Primary

- Added Guarding → service → Preferred Primary. Choose an observed server or
  enter a stable node ID for an unseen standby; clear restores normal selection.
  Current Owner remains separate and observed servers are not invented from a
  preference. Metadata is keyed by stable service ID, saved durably before
  publication, with revisions that survive relaunch and increment on actual
  changes. Removing/replacing a service clears its preference. Settings drafts
  preserve newer preferences instead of overwriting them.
- Added authenticated read-only `POST /v1/service/policy`, version 1, scoped to
  the existing service credential and cluster. Clearing returns explicit null.
  Live policy edits preserve the listener, store, lease owner, term and expiry;
  policy reads never grant ownership or write audit events. Quarantine still
  blocks grants even when policy reads succeed. Lease request/reply JSON stays
  unchanged. Added the client contract and a Claude implementation prompt.
- All **75 Xcode Debug tests passed**, including isolated durable configuration,
  revision overflow, service isolation/removal, live router changes, unavailable
  preferred-node failover and restart quarantine. Native development preview
  verified known-node selection, manual unseen standby entry, invalid-ID
  rejection, cancellation and clearing while the existing owner stayed put.
  The preview uses in-memory fixture metadata and touches no production storage,
  listener, Keychain or update preferences.
- Universal Release passed, version **0.2.0**, build **2026100615**. Verified
  Intel/Apple silicon slices in all eight bundled Mach-O executables/frameworks,
  macOS 15.0 load commands for Ruru, WitnessKit and the connector, and no SQLite
  linkage or test helper. Strict signatures passed before/after ZIP extraction;
  every bundled file and symlink matched the source. Sparkle's development
  preflight passed with ShipHook's public key still pending and updates disabled.
  The extracted Release preview confirmed manual and observed-server changes
  while preserving the owner; saved a Preferred Primary documentation image
  and stopped the preview. No production settings or credentials were edited.
- Refreshed `Build/Release/Ruru.zip` (**73.8 MB**, 73,813,354 bytes), SHA-256
  `8a90ae1135f40b7f2a5c50774f6c556bd648011971fae594724c29d52b397d20`.
  The prior export is retained under
  `Build/Previous/2026100612-before-preferred-primary/`. This remains an ad-hoc
  development package. Actual Intel/Sequoia execution and coordinated handback
  remain unverified; SwiftBot still needs the client integration. No publishing
  or release-key setup changed for this feature.

## 2026-10-06 — Sparkle support and ShipHook handoff

- Added Sparkle **2.9.5**, matching SwiftMiner's installed package, through its
  Swift API. Adapted its standard updater UI wording, Stable/Beta channels,
  background prompt preference and optional automatic downloads. Added Check
  for Updates to Settings, the application menu and menu bar menu. Preferences
  remain drafts until Save. Sparkle owns scheduling and persisted check/download
  preferences; Ruru stores only its channel selection.
- Default background checks are enabled and automatic downloads disabled.
  Updates use normal install-on-quit behavior rather than mining-specific forced
  restart timing. Requested update relaunches await listener/connector shutdown;
  ordinary termination retains the same shutdown path. Lease terms, protocol,
  database locking and restart quarantine are unchanged. Preview never starts
  Sparkle, checks a feed or writes update preferences.
- ShipHook owns signing, publishing and appcast items. Added empty source feeds
  under `docs/`, generated Info.plist properties in `project.yml`, Sparkle
  licensing, a distribution entitlement file and a read-only Swift configuration
  preflight. The owner confirmed ShipHook's public key is not available yet;
  `SPARKLE_PUBLIC_ED_KEY` is intentionally empty and updates remain disabled.
  The temporary local key generated before that clarification was deleted and
  was never used to sign or publish anything. No private key remains part of
  this setup. No ShipHook job, GitHub release or live authority was changed.
- All **69 Xcode Debug tests passed**, including valid Stable/Beta feed selection
  and rejection of missing/unresolved signing keys or unsafe feeds. The built
  bundle's development preflight passed; strict publishing validation correctly
  fails without ShipHook's public key. Native preview verified the update section
  and unavailable controls. Universal Release passed. Verified arm64/x86_64
  in the app, WitnessKit, connector, Sparkle and its nested helpers; app/authority
  code still targets macOS 15. Strict signatures passed before and after ZIP
  extraction; binary/icon/licence hashes matched and no SQLite linkage or test
  helper was bundled. The extracted Release preview verified the final update
  section; saved a Software Updates documentation image and stopped previews.
- Refreshed the development export at `Build/Release/Ruru.zip` (**73.7 MB**),
  build **2026100612**, SHA-256
  `72458181fe9d1905db24a7da2ca665324a68ba887b112a1b64abb4df66649d7d`.
  Preserved the previous export under `Build/Previous/2026100604-before-sparkle/`.
  No release signature was generated. Live feeds, final archive signatures and end-to-end update/relaunch
  need ShipHook provisioning; actual Intel/Sequoia execution remains untested.

## 2026-10-06 — Service removal, Dock option and SwiftBot Overview

- Added Remove in guarded-service details with a native confirmation. Every
  service, including the original SwiftBot entry, can be removed and stays
  removed after relaunch. An empty catalog is valid and rejects lease requests.
  Admission revocation retains leases, terms and history; another service keeps
  running. Re-adding a cluster gets a new token and preserves fencing against its
  former owner. Inactive Keychain items remain stored but are not admitted.
  Catalog edits also work when startup is blocked and do not access/reset storage.
- Added Settings → Appearance → Show in Dock, off by default. Save applies the
  activation policy without restarting the listener; the menu bar and window
  reopening remain available. Settings persistence now synchronizes the saved
  file and directory before acknowledging catalog changes.
- Diagnosed the reported startup error: old SQLite files remain locally. Added
  explicit Set Up DuckDB, requiring acknowledgement that all clients are stopped
  and unpaired and the old witness is retired. It checkpoints fresh cluster IDs
  and tokens, holds both lock paths, archives legacy files/sidecars/marker, retires
  older binaries before moving data, and creates fresh DuckDB storage. It never
  replaces existing/damaged DuckDB files. Setup leaves auto-start disabled and
  the service stopped; every remaining client needs fresh pairing details.
- Reworked Overview using SwiftBot's current console source: the real app icon
  and status dot, version/node/monotonic uptime facts, named issue review actions,
  visible lifecycle control, four adaptive service cards, Quick Actions and a
  read-only System inspector. Catalog ownership remains in Guarding. Narrow
  windows use 2×2 cards and stacked panels; wide windows use a strip and paired
  panels. All controls use Sequoia APIs, without SwiftBot's macOS 26 glass styles.
- All **66 Xcode Debug tests passed** with zero failures, covering persistent
  primary removal, empty catalogs, live revocation of all lease actions,
  unaffected services, retained terms and non-overlap on re-add, legacy archives,
  failed checkpoints, active locks and refusal to replace damaged/native storage.
  Native isolated previews verified removal while startup is blocked, its
  confirmation/empty state, both setup acknowledgement gates and simulated setup,
  saved Dock preference and window reopening, plus narrow/wide Overview layouts.
  Preview operations never touched real Keychain, storage, listeners or login items.
- Universal Release passed. Verified arm64/x86_64 slices and macOS 15.0 load
  commands in the app, framework and connector, strict signatures before and
  after ZIP extraction, matching binary/icon/licence hashes, and no SQLite
  linkage or bundled test helper. The extracted app's native preview verified
  service removal/re-addition, the new Overview and Dock changes retaining the
  selected page. Refreshed the README's Overview and Guarding screenshots.
- Refreshed `Build/Release/Ruru.zip` (**72.6 MB**), build **2026100604**, with
  SHA-256 `59f5d6a6505fd7862a48a98cf050f3c2a91be3fd351521f5958313486e68c801`.
  Preserved the previous export under
  `Build/Previous/2026100603-before-removal-dock-overview/`.
  Actual Intel/Sequoia execution, target-Mac resource measurements, production Keychain
  provisioning, offline replacement and paired-client drills remain unperformed.
  The owner's actual SQLite files have not been archived or changed.

## 2026-10-06 — SwiftMiner sidebar

- Replaced the sidebar's branding header and sectioned list with a local SwiftUI
  adaptation of SwiftMiner's flat rows, sidebar material, typography, spacing,
  rounded selection highlight and drag selection. Kept all five Ruru destinations
  and the status/version footer. Used a 200pt column so Internet Access fits in
  full; SwiftMiner uses 180pt. Native buttons expose selected state, with reduced
  motion/transparency and increased-contrast fallbacks using macOS 15 APIs.
- Regenerated the project with XcodeGen. Universal Release build passed and
  the application binary contains arm64 and x86_64; strict bundle signature
  verification passed. Checked all destinations, full labels and drag selection
  in the isolated native preview. Refreshed Overview and Guarding README images
  using ephemeral sample services, then stopped that preview process.
- No lease/storage behavior changed, so the existing 58-test backend suite was
  not rerun for this UI-only change. Actual Intel/Sequoia execution and system
  accessibility preference combinations were not exercised. The existing ZIP
  export remains the earlier Guarding build; the new sidebar is in source and
  the verified Release build. No production configuration was changed.

## 2026-10-06 — Independent guarded services

- Added **Guarding** to the native sidebar, with a service list, Add Service and
  Rename flows, per-service ownership, known servers, connection details and
  retained activity. Overview and the menu bar summarize all guarded services.
  SwiftBot is the first service; additional SwiftBot groups and other apps are
  admitted through the same lease protocol, with no two-participant limit.
- Added a persisted service catalog and unique Keychain credentials scoped to
  each configured cluster. Legacy SwiftBot settings, token account, names,
  leases and Cloudflare identity remain intact. Live service addition updates
  admission after persistence without restarting the listener or existing leases.
  Terms and restart quarantine remain shared-store safety invariants.
- Exposed the database’s existing cluster field in activity snapshots; names
  and activity now stay scoped to a service. Known servers reflect successful
  retained ownership participation, not uptime or standby health. No passive
  probes, alerts, discovery or third-party application adapters are claimed.
- All **58 Xcode Debug tests passed**, including independent terms, credentials
  rejected across service boundaries, more than two competing participants,
  invalid registry updates preserving the old listener, legacy catalog decoding,
  separate name scopes and crash quarantine across three services.
- Isolated native preview checks passed for navigation, duplicate-group rejection,
  adding a generic service, its scoped connection sheet and cosmetic rename.
  Updated the README screenshot and added a Guarding preview image. Only ephemeral
  preview state changed; no real Keychain, storage, tunnel or login item was used.
  Universal Release passed. Verified arm64/x86_64 slices and macOS 15.0 load
  commands for app/framework/connector, strict signatures before and after ZIP
  extraction, matching binary/icon/licence hashes, and no SQLite linkage or
  bundled test helper. The extracted Release preview launched successfully.
- Refreshed `Build/Release/Ruru.zip` (**72.3 MB**), build **2026100603**, with
  SHA-256 `c37c247415762ab3eac05cf93be25c0fbc9225e22a5d94e27ac345d744058381`.
  Preserved the prior export under `Build/Previous/2026100602-before-guarding/`.
  Signing/notarisation, actual Intel execution, target-Mac resource measurements,
  real per-service Keychain provisioning and a multi-service deployment drill
  remain outstanding. No live service, remote Mac, tunnel or login setting changed.

## 2026-10-06 — Ruru project, icon, and GitHub preparation

- Renamed the repository folder to `ruru`, generated project to
  `Ruru.xcodeproj`, application target/scheme to `Ruru`, and app source directory
  and entry point to `Sources/Ruru/RuruApp.swift`. Regenerated with XcodeGen.
  Persisted bundle, Keychain, settings and tunnel identities remain unchanged.
- Integrated the owner's `ruru.icon` Icon Composer asset as the application icon.
  Xcode generated `ruru.icns` for the macOS 15 fallback and compiled modern icon
  resources. Exported the compiled icon and captured the native isolated Overview
  for the README without opening storage, Keychain, a listener or login items.
- Prepared a SwiftMiner-style README with centred branding and badges, concise
  highlights, and links to setup, storage, development and release guides.
  The owner approved `johnwatso/ruru` and the MIT licence. Added the licence and
  draft release notes; the app also bundles its own MIT licence. Local
  documentation links all resolve. No repository or
  public release has been created or pushed.
- All **51 Debug tests passed with zero failures** after the Xcode target/scheme
  rename. Universal Release passed from the final folder. Verified x86_64/arm64
  and minimum macOS 15.0 in the app, framework and connector, generated icon
  resources, no SQLite linkage or bundled storage-test helper, and strict
  signatures before and after ZIP extraction. The extracted Release app launched
  successfully in its isolated native preview.
- Refreshed `Build/Release/Ruru.zip` (**72.1 MB**), with an export receipt and
  `Ruru.zip.sha256`. SHA-256:
  `74120c15e5d2da52f66e16da8e57975b8a08f2367c1f2221cc469419f6f9cb48`.
  Preserved the earlier Ruru export under
  `Build/Previous/2026100601-before-project-and-icon/`. Distribution signing and
  notarisation, actual Intel/Sequoia icon rendering and resource measurements,
  and a complete paired-bot failover drill remain outstanding. No production
  storage, live tunnel, login item, power setting or remote Mac changed.

## 2026-10-06 — Ruru and DuckDB Swift

- Renamed the visible application, menu bar, window, sidebar, About and product
  to **Ruru**, version **0.2.0**, build **2026100601**. Kept the internal Xcode
  project/scheme, bundle identifiers, Keychain accounts, settings directory and
  Cloudflare tunnel identity stable.
- Replaced runtime SQLite access with the official DuckDB Swift package pinned
  to stable **1.1.3**. Application-owned code is Swift; wrapped native engines
  and the existing bundled Cloudflare connector are allowed dependencies.
  The engine uses a persistent connection, two workers, a 128 MB database memory
  budget and disabled external access. There is no app SQLite linkage or
  extension download, and no new runtime script.
- At the owner's request, omitted old-data migration. Existing SQLite storage
  prevents creating fresh terms; replacing it requires an explicit offline
  authority reset and bot re-pairing. Fresh installs keep both lifetime lock
  paths and a persisted retirement marker that rejects older app binaries.
  Missing/corrupt state and incomplete setup fail closed.
- Xcode Debug tests passed: **51 tests, zero failures**. Includes SIGKILL of a
  separate native test authority after an acknowledged grant, WAL recovery,
  full restart quarantine, transaction rollback after lease/audit writes,
  retired-app locking and preservation of unsupported/corrupt storage. Existing
  protocol, expiry, fencing, display-name and Cloudflare tests also pass.
- Universal Release passed. Verified x86_64/arm64 slices and minimum macOS 15.0
  for the app, framework and connector, absence of SQLite linkage and test helpers
  in the app, and signatures before and after ZIP extraction. The isolated native
  Release preview launched successfully; Overview, sidebar/menu and Settings/About
  branding were checked visually and through accessibility. A development signing
  entitlement allows the ad-hoc embedded framework while retaining hardened
  runtime; shared-team distribution signing/notarization remains outstanding.
- Exported **Ruru.app** as a **69.0 MB** archive at `Build/Release/Ruru.zip`.
  ZIP SHA-256: `b8254165ab6cfa6391c27a6e40f03d21d662b08bc1013bf60ef8bfe9e3fe2ac1`.
  Finder metadata added by the synced workspace prevented strict verification
  of a loose copied bundle; the archive was produced from the clean build and
  its extracted signatures and binary hashes were verified. The original export
  was preserved. Actual Intel execution, Sequoia/OpenCore resource use and a
  complete paired-bot failover drill remain unverified for this revision. No
  production storage, live tunnel, login item, power setting or remote Mac changed.

## 2026-10-05 — Initial native witness

- Created a separate local Git repository and generated Xcode project.
- Added a native status window/menu bar service, connection details, draft settings,
  Keychain-only bearer credential, and optional launch at login.
- Ported the SwiftBot lease protocol to an independent actor and system SQLite
  authority. Added monotonic expiry, durable terms, commit-before-grant, restart
  quarantine, bounded HTTP handling, and a lifetime database lock.
- Targeted macOS 15.0 and universal Release binaries for the 2012 Intel/OpenCore
  Sequoia Mac mini in Invercargill, with Apple silicon support for development.
- Debug app/test and universal Release builds passed with 24 XCTest tests and
  no failures, including real loopback protocol requests, competing owners,
  repeated restarts, failed commits, missing/corrupt state, and term fencing.
  Verified x86_64/arm64 slices and macOS 15.0 load commands in the Release app.
  The only build warnings were Xcode's skipped AppIntents metadata extraction.
- Launched the isolated native preview without Keychain, listener, or login
  changes. Visual/interaction verification was unavailable because the native
  computer-use connection closed. The actual Sequoia/OpenCore Mac, live HTTPS
  tunnel, login registration, and paired bots remain untested. No remote
  deployment or GitHub repository has been created. Source changes are uncommitted.

## Deployment work

- Validate the redesigned console and startup behavior on the actual
  Sequoia/OpenCore Mac mini. Initial app launch and tunnel setup are confirmed.
- Use the app's Internet Access setup on the witness Mac and pair both bots.
- Choose login/power settings and run controlled failure/return/partition drills.
- If operation before login or automatic recovery after a crash is required,
  add a separately supervised service/helper while retaining WitnessKit semantics.
- Add distribution signing/notarization and updates when publishing
  is requested.

## 2026-10-05 — Built-in Cloudflare Internet Access

- Adapted SwiftBot's Cloudflare setup into the witness: scoped token verification,
  zone discovery, its own persistent tunnel identity, safe DNS creation, and a
  bundled universal connector. Added native setup, status, pause/resume, Keychain
  credentials, startup reconnect, network/health supervision, and quit cleanup.
- Setup refuses other services' DNS records, checkpoints secrets/IDs before
  publication, and never relies on a SwiftBot instance to host the witness route.
  Existing settings load without enabling public access. Cloudflare credentials
  never enter the exported bot connection details.
- Debug app/test build passed with **38 XCTest tests**, including mocked API/DNS
  setup, conflict rejection before writes, checkpoint failure, retry safety,
  legacy settings, fragmented helper output, token passing, and all lease tests.
  Universal Release build passed. App, framework, and helper contain x86_64 and
  arm64 slices with minimum OS 15.0; bundle signature verification passed.
- Both upstream connector archive SHA-256 digests were verified; the arm64 helper
  runs `--version`. This development Mac cannot execute x86_64 binaries (Rosetta
  unavailable), so Intel execution still needs the real Mac mini. Native UI
  inspection failed because the computer-use pipe closed; layout, real Keychain
  setup, live Cloudflare, login operation and physical Mac checks remain pending.
  Source changes remain uncommitted; no real Cloudflare account or Mac mini was
  configured during development.

## 2026-10-05 — Desktop export for the target Mac

- Exported the universal Release app to `~/Desktop/SwiftMeshWitness.app` and a
  42.2 MB transfer archive at `~/Desktop/SwiftMeshWitness.zip`.
- Verified bundle signatures before export and after extracting the ZIP. App,
  framework, and connector hashes match the built app and retain x86_64/arm64
  slices. Development signing remains ad hoc; notarization and actual target
  Mac execution are pending. No settings, Keychain credentials or database were
  included, and no remote installation or configuration was performed.

## 2026-10-05 — SwiftBot console design

- Rebuilt the window around SwiftBot's current native console design: sidebar
  navigation, large page headers, quiet glass surfaces, service status cards,
  inset settings rows, semantic status colors, and the shared Cloudflare artwork.
  Added a local design reference and attribution for the reused visual patterns.
- Overview emphasizes the active owner, lease countdown, authority health, and
  recent ownership events. Internet Access has dedicated setup and management;
  Activity supports searching ownership history; Settings saves explicit drafts.
  Connection details and credential setup use styled native sheets. Stop Service
  and Pause Internet Access require confirmation in the console.
- Kept lease/storage semantics, settings paths, Keychain identities, and
  Cloudflare provisioning unchanged. All visual APIs support macOS 15.0.
- Debug tests passed with **38 tests and zero failures**. Universal Release build
  passed; version **0.1.0**, build **2026100523**, minimum macOS **15.0**. Verified
  Intel/Apple silicon slices for the app, framework, and bundled connector,
  signature validity, and binary hashes after ZIP extraction. Exported the new
  app and **42.6 MB** ZIP to the Desktop; retained the previous export under
  ignored `Build/Previous/2026100518/`. ZIP SHA-256:
  `a7b41555a9b45a66d86d393cbbd36d482defb1a1df4a644527b91a099666bbf3`.
- The owner's screenshot confirmed the original app running with Cloudflare
  connected on the target Mac; `https://witness.swiftbot.dev/health` returned
  HTTP 200 with `ready: true`. A complete failover drill remains unconfirmed.
  The redesigned window could not be visually inspected because the native
  computer-use connection closed. Target-Mac visual/interaction checks remain
  outstanding; no live service or remote Mac was stopped for this redesign.

## 2026-10-05 — Readable Current Owner

- Replaced the large monospaced node ID with a readable bot name and Mac icon.
  Bot Details holds the full selectable/copyable ID and a saved display-name
  draft for existing bot installations. Overview and Activity share the same
  names, including search. Saving a nickname preserves the listener and lease.
- Updated SwiftBot to send its configured SwiftMesh node name as optional
  metadata on acquire/renew/release. Accepted requests persist their own names
  separately from lease identity; failed requests cannot change names. Name
  changes never determine ownership or Primary preference. Older requests,
  settings and lease databases remain compatible.
- Debug witness tests passed: **43 tests, zero failures**. SwiftBot's Debug
  app/test build and all **16 MeshReliabilityTests** passed, including name
  changes preserving an existing deadline. Native visual checks and installing
  the updated SwiftBot on live nodes remain pending. Existing bots can use the
  witness's local nickname control immediately.
- Universal Release and signature checks passed for the app, framework and
  connector, including macOS 15.0 load commands and matching binary hashes after
  ZIP extraction. Refreshed the Desktop app and **42.7 MB** ZIP (version 0.1.0,
  build 2026100523); preserved the prior console export under ignored
  `Build/Previous/2026100523-before-owner-names/`. ZIP SHA-256:
  `e34371f06187f3516fe27d740c8542aa5ea55d6373b9ee5b21c2e6134ae3ed2e`.


## GitHub Pages website — 9 October 2026

- Added a static landing page in `docs/` with the existing Ruru owl icon, actual development-preview screenshots, feature descriptions, and documentation links.
- Added an illustrated looping failover demo covering lease expiry, standby acquisition, primary recovery, and compatible-client handback. Includes pause/resume, restart, reduced-motion behavior and page-visibility suspension. The demo does not claim physical server startup or traffic routing.
- Added a GitHub Actions Pages workflow that publishes all of `docs/`, preserving stable and beta update-feed paths. No application code or existing feed files changed.
- Validation: JavaScript syntax, all local asset references and in-page anchors; desktop and 390px phone layout without horizontal overflow; pause/restart and screenshot tab selection including keyboard navigation; no browser warning/error logs during checks. GitHub deployment has not been performed. Native app builds are not required for these static website additions.


### Website screenshot refresh — 9 October 2026

- Replaced the outdated Guarding and Preferred Primary website images and refreshed Overview for consistency. All three are matching 2610 × 1700 dark-mode native window captures of the current preview console.
- Captured with ScreenCaptureKit's `showsCursor = false`; no images were retouched or synthesized. Preview uses the existing isolated fixtures, including current sidebar navigation, SwiftBot branding, the renewal ring, presence reports and compact Preferred Primary row.
- Verified refreshed images in the local website and updated the downloadable package. Updated Guarding's screenshot caption to describe the service-list view accurately.
- Used a private copy of the existing Debug app with a preview-only launcher and the bundle preview flag; production app source, preferences, storage, Keychain and services were not modified. UI source files predate the successful Debug binary used for capture.
- Additional validation limit: a fresh isolated Debug build compiled but failed at code signing due to resource-fork/Finder metadata in generated resources, including after one metadata-cleanup retry. The website captures use the existing successfully built Debug app; this screenshot update does not claim a fresh native build passed.

### Website screenshot presentation — 9 October 2026

- Hide the macOS purple capture indicator in the unused upper-left titlebar area with a responsive CSS cover shared by all three screenshot tabs. Native screenshot files and app content remain unchanged.
- Verified the rendered local browser preview without the badge, checked screenshot tabs, and refreshed the downloadable website archive. Added a stylesheet cache version so the refreshed presentation loads immediately.
