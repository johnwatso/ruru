# Development log and next steps

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
