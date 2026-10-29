# Ruru design

Follow SwiftBot's current native console, as defined by SwiftBot's
`Documentation/DESIGN.md` and `ConsoleOverview` views. The earlier bare status
window is no longer the visual baseline. This app remains native SwiftUI and
must run on macOS 15 Sequoia, including the Intel Mac mini.

All Web UI design and implementation is shelved until Ruru is active and in use.
Use the native console for current operator flows; see [Web UI status](WEB_UI.md).

## Layout and surfaces

- Use `NavigationSplitView` with a SwiftMiner-style 200pt sidebar: Overview,
  Guarding, Coordination, Monitoring, Internet Access and Activity. Navigation starts directly
  below the window controls, without an app branding or section header. Match
  SwiftMiner's 14pt row typography, 8pt outer gutters, 2pt row gaps, sidebar
  material and animated 11pt rounded selection. Keep the sidebar free of a
  status/version footer; preserve native button accessibility and
  reduced-motion/transparency fallbacks.
  The extra 20pt over SwiftMiner accommodates the full Internet Access label.
  Service cards open the corresponding destination.
- Reuse the local adaptations in `WitnessConsoleStyle.swift`: `ConsolePageHeader`,
  `ConsoleSection`, inset row groups, icon tiles and status badges.
- Large system titles, 36pt horizontal page gutters, 32pt top and 40pt bottom
  insets, 24–32pt section gaps, and a 1120pt maximum content width match SwiftBot.
- Use quiet continuous rounded panels: 20–22pt outer panels, 14–16pt inner rows
  and cards, subtle semantic strokes and shadows. Keep sections full width.
- Use system typography and semantic colors. Materials and native sidebar chrome
  adapt to appearance and accessibility. Do not force dark mode, custom fonts,
  decorative glows or web-style layout abstractions.
- A main page header may stack its actions when narrow. Values and issue details
  wrap; stable numeric widths prevent the live countdown from moving controls.

## Content and controls

- Show actual ownership prominently. Empty ownership is a neutral waiting state;
  recovery is a warning, listener failure is an error, paused services are neutral.
- Use the bot's readable node name or saved nickname for Current Owner and
  Activity. Keep the internal node ID in Bot Details; never infer Primary or
  Failover from an ID or the order bots connect.
- Status colors always accompany text. Show complete error details.
- Separate public HTTPS from the local HTTP listener.
- Credentials are edited in modal drafts. Show Copy Token rather than revealing
  the witness token. Cloudflare tokens remain in Keychain.
- Settings preferences apply immediately, as macOS settings windows do. Console
  sheets (connection, credentials, policies) still commit on Save.
- Activity search and header remain visible above the scrolling event list.
- Stop/Pause explain their operational effect using native confirmation dialogs.
- Closing the window preserves the menu bar service and tunnel.
- Settings is a separate native preferences window, matching SwiftMiner’s compact
  top icon tabs: General, Alerts, Updates and Backup. General groups app presence and startup
  controls; connection controls live under Internet Access → Connection Settings.
  Each tab is a native grouped `Form` (`.formStyle(.grouped)`, available on
  Sequoia) sized to its content in a 540pt-wide window: plain section headers,
  leading labels with secondary descriptions, trailing controls and footnotes
  as section footers. Do not use console cards, icon tiles or large titles here.
  There is no Save/Revert bar. A failed save shows an inline warning and restores
  the saved value. The app menu’s Settings command (⌘,), menu bar
  Settings and Overview actions open the same window without changing console
  navigation. Closing either window leaves the menu bar service running.
- Alerts uses a searchable rules list and a single editor in console surfaces,
  within the normal 1120pt content width. Edit the name and enabled state in the
  editor header. The main form has two sections: Alert me when (one condition
  menu grouped by source, targets and applicable thresholds) and Notify me
  (destinations and optional recovery). Events show no threshold or recovery.
  Keep cooldown, repeats, quiet hours, severity and Activity recording under a
  collapsed More options disclosure; its summary exposes configured overrides.
  Rule Info opens status, recent triggers and notification previews in a popover.
  Open incidents explain what to check next and offer a Review action opening
  the affected target, service or Ruru connection page. Unverified incidents
  require fresh evidence and never offer a manual "mark healthy" action.
  History lists open incidents (unverified ones in orange, never green) and
  per-destination delivery results. Existing rules retain all saved settings.
- Settings → Alerts links to Alerts for rules and groups "Deliver To" (macOS
  notifications, Discord and Notify! with Set Up…/Replace…/Remove, Send Test).
  If rules cannot be saved it shows the earlier "Alert Me When" toggles (service
  down, failover, Ruru problems, participant power/session status).
  Discord's webhook URL and Notify!'s token are entered in secure setup sheets
  and kept in Keychain; Notify!'s destination ID is saved with preferences.
- Show a lease like a one-time code (Passwords' verification code): the
  ownership term in large monospaced digits grouped in threes, rolling with a
  numeric transition when it changes, beside a countdown ring for the current
  grant sized to the service's lease length. The ring interpolates between
  one-second polls, refills on each renewal, and is green while renewals keep
  up, orange ("Renewal late") below a third, red in the last seconds. No
  progress bars for leases. Respect Reduce Motion. Countdown text updates at
  most once per second; animate the ring stroke between ticks without rebuilding
  labels at frame rate. Unowned and recovering leases have no countdown timer.
  After five minutes without input in Ruru, replace the ring with a status SF
  Symbol. Current renewals show a green
  `arrow.trianglehead.2.clockwise.rotate.90.circle.fill` and “In Sync” (lease
  renewals only, not application data synchronisation); late renewals retain
  orange/red warnings, recovery is orange and no owner remains neutral. Fade
  briefly on status changes, with no continuous pulse or rotation. Mouse/keyboard
  input, activation or reopening restores the ring using the current grant.
  Respect Reduce Motion for these fades too. One app-local input monitor and
  one monotonic inactivity deadline control presentation only; authority work,
  polling and alerts continue while idle or the window is closed.
- First run opens a five-step setup assistant sheet that gets Ruru working,
  then pairs SwiftBot: Welcome, Public Address, Keep Ruru Running, Pair
  SwiftBot (Add SwiftBot, then the shared pairing panel; Skip for other apps),
  Ready (with Add Your First App, or Open Guarding once a service exists). Step dots, Finish Later, Back and one primary action.
  Steps read real state so it resumes correctly. A public address is expected;
  "Skip — Local Testing Only" is a small link.
- Cloudflare setup (assistant and Internet Access) is token → choose one of the
  token's domains → subdomain (default "ruru") with a live address preview →
  Connect, showing a step checklist, then "Reachable from the internet".
  Failures name the step; a connector that doesn't register within 90 seconds
  shows its last output lines (secrets redacted). Overview's summary lists "needs attention" items
  (finish setup, stopped, no public address, no services, unpaired service,
  servers waiting to pair), each with the one action that fixes it.
- Pairing codes appear in Connection Details → Pair a Server in the same
  one-time-code style as leases: grouped monospaced characters and an expiry
  ring, with Cancel Code. Pending requests show server name, node ID and age
  with Reject and Approve, both there and in a Pairing Requests section at the
  top of the service page.
- Services are equal: Guarding lists only configured services, starting empty.
  The SwiftBot template shows SwiftBot's app icon; other services use an SF
  Symbol tile. Add Service and Edit include a lease-length picker.
- Settings → Backup shows the last automatic snapshot (Show in Finder, Snapshot
  Now), Export… and Restore…. Restore opens a sheet summarising the file, an
  optional Restore settings switch, and two required acknowledgements (other
  authorities stopped; servers may need to re-acquire) before a Restore button.
  Footnotes explain the Time Machine exclusion, raised terms and that no
  credentials are exported.
- About is the standard About panel (icon, name, version/build and a Release
  Notes link), opened from the app menu and the menu bar menu, not a Settings tab.
- Settings → General's “Show Ruru in” picker offers Dock + Menu Bar or Menu Bar
  (default), following Otter's App Presence control, with a description that
  follows the selection. There is no Dock-only mode, because the menu bar
  service must remain. Ruru always follows the system appearance.
- Settings → Updates mirrors SwiftMiner's channel and update-check
  controls with Sequoia-native styling. Preferences apply immediately. Missing
  publishing configuration shows a plain unavailable message and disabled
  controls. No build-setting names appear in the product flow. Installing an
  update may interrupt authority service; explain that restart quarantine applies.

No macOS 26-only APIs, third-party UI libraries or dependencies on SwiftBot's
app target are permitted. Use the native Sequoia equivalent where SwiftBot uses
newer Liquid Glass controls.

## Overview composition

Top to bottom: header (Overview, More menu, Start/Stop, Guarding); a compact Ruru
card; four equal summary cards; Guarded Services; full-width Recent Activity.

- The Ruru card is about Ruru only: app icon, name, status badge, "Running on
  <Mac> · Uptime …" and one authority line derived from service state (normal,
  stopped, starting/recovering, requires attention). A held lease never counts
  as authority health. Actionable issues (finish setup, pairing, no public
  address, tunnel or monitoring failures) follow inside the card with their fix.
- Summary cards (Guarding, Internet Access, Activity, Monitoring) use SwiftBot's
  168pt minimum width with a 2×2 fallback and open their page. Monitoring counts
  enabled targets, reports failing checks as incidents, and shows neutral text
  when there are no targets, all are paused, or no check has finished yet.
- Guarded Services is a compact table (Service, Ownership, Participants, Status)
  that collapses to two-line rows when narrow. Rows open that service's details in
  Guarding; Manage Services opens the list. Status keeps lease ownership, contact
  and application-reported readiness apart: Ready/Synchronising/Outdated/Degraded
  only from a fresh operational report, Contact stale, Unowned, Recovering, or
  plain "Owned" (neutral) when a lease is held and nothing else is known.
  Participants counts known nodes, which includes historical ones.
- Recent Activity is the merged newest-first feed (five rows).
- System facts (computer, architecture, memory, macOS, version, storage) live in
  Settings → General → System, not on Overview. Alert settings live in Settings.

## Guarding

Use service-neutral navigation and global Overview copy. SwiftBot is the first
service, not the app’s identity. Guarding lists service names, application kinds
and ownership state; a detail view shows ownership, known servers, recent
activity and per-service connection details. Add Service uses a modal draft;
renaming does not interrupt ownership. Use “server” or “participant” for generic
clients, and SwiftMesh pairing instructions only for a SwiftBot service.

Service icons are display-only. Add and Edit Service accept an `.app` (its Finder
icon, and its name when none is typed) or an image dropped anywhere on the sheet
or chosen with Choose…; “Use Default” returns to the template icon. Icons are
stored as 256 px PNGs in `Application Support/Ruru/ServiceIcons/<service id>.png`,
outside `configuration.json`, and never affect leases, wire protocol or RuruClient.

Distinguish current ownership from health. Label historical participants' contact
“Presence unknown”; do not call them connected, online or healthy without fresh evidence.
Empty service ownership remains a neutral state.

Known Servers also includes authenticated presence reports from standbys. Show
Current owner independently of the reported role and Recent contact/Last seen.
At 45 seconds show Contact stale and stop displaying the role as current; old
clients with only ownership history show Presence unknown. Reports expire after
600 seconds; history remains. Do not describe contact as proof of failover readiness.
Server Details opens as a sheet, independent of where the clicked row or Activity
lies in the scroll view. Expose the animated lease code as one stable accessible
description containing its term and remaining grant time.

Preferred Primary is optional and secondary: show it as one compact row under
Known Servers (star, name or "None", a borderless Change menu with Choose… and
Clear, explanation in its help tooltip), never in the Ownership panel.
Its sheet offers No preference, observed servers and manual node-ID entry for
unobserved standbys. Show the selected stable ID and a separate marker on known
server rows. Do not relabel the owner when a preference changes or imply the
target is online. Explain compatible-client handover and continued failover.

Service details include Remove with a confirmation describing lost renewal,
normal lease expiry and retained terms/history. All services can be removed,
including SwiftBot; an empty list explains how to add another service. A SQLite
startup block exposes Set Up DuckDB in Overview, Guarding and Connection Settings. Its modal
requires explicit offline/unpaired acknowledgements, explains the local archive
and fresh pairing details, and leaves the authority stopped after setup.

Guarding and Coordination details link directly to the same service in the
other capability. Name the distinction in the row: ownership guarding versus
optional resource sharing. Sidebar help describes each page's purpose. Connection
Details explains shared service-token trust; server names/IDs are not separately
authenticated, and remembered participants are observations rather than membership.
Removal copy refers to existing client deadlines, never a fixed 30-second expiry.
Backup/restore copy uses the actual maximum restore quarantine and distinguishes
settings-only restores. Preserve the warning about reconciling newer lost terms.

## Coordination

Use the shared header, sections, inset rows and native sheets. Start with a
separate card for each app/service, using its name and app icon, and open a scoped
detail page with a back action. Keep that service’s features, settings, connection
details and resources together. Add Service is available here as well as Guarding;
both use the same identity and credentials. Avoid a global resource view with a
service picker. Include Remove in each service detail header, with a confirmation
that explains removal from both Coordination and Guarding, cleared observations,
revoked reports/lease renewal and normal ownership expiry. Preserve hosted files
and durable ownership history. Show removal failures on the detail page and
return to the app/service list after success. Edit catalogue opt-in/allowed HTTPS
origins in a Save/Cancel draft. Show pending website counts on service cards and
a Website requests section above the catalogue in the service detail. Each row
shows the reported server name and exact HTTPS origin, with Reject and Approve
actions. Use Enable & Approve when reporting is off; show the existing origin
limit before allowing approval. Requests alone do not change permissions.
Show application-neutral resource names, namespaces, reporting servers, URLs and
fresh/stale report badges. Copy URL is explicit; reports do not prove reachability
or ownership. Search narrows the first 100 visible locations. Empty states explain
client reporting and service opt-in. Recordings and artifacts are examples, not
special cases in the shared UI. Keep credentials in the existing service sheet.

## Monitoring

A sidebar page of reachability targets, each a TCP port, DNS server or HTTP(S) address.
Rows show a status badge (Up, Down, Paused, Checking…), the last response time or
failure reason and a 30-check history strip; a detail sheet shows 60 checks, status
changes and settings. A target is reported down only after its configured number of
consecutive failures and recovers on the first success. Monitoring is observation
only: it never affects leases, ownership or failover, and the page says so. Confirmed
down targets appear in Overview's attention list and Monitoring card, in the global
activity feed, and as alerts (Settings → Alerts → “A monitored target goes down”).
Targets take a custom icon exactly like services (drop an app or image on the sheet, or
Choose…); it is shown on rows and in the detail sheet and shares the service icon store.
New HTTP(S) targets without a chosen icon also make one bounded, same-origin request for
`/favicon.ico`; the result is optional and never affects the reachability check.
