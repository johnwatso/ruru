# Ruru design

Follow SwiftBot's current native console, as defined by SwiftBot's
`Documentation/DESIGN.md` and `ConsoleOverview` views. The earlier bare status
window is no longer the visual baseline. This app remains native SwiftUI and
must run on macOS 15 Sequoia, including the Intel Mac mini.

## Layout and surfaces

- Use `NavigationSplitView` with a SwiftMiner-style 200pt sidebar: Overview,
  Guarding, Internet Access, Activity and Settings. Navigation starts directly
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
- Settings commit on Save; Revert discards the draft. Navigation never saves.
- Activity search and header remain visible above the scrolling event list.
- Stop/Pause explain their operational effect using native confirmation dialogs.
- Closing the window preserves the menu bar service and tunnel.
- Settings → Appearance offers Show in Dock, off by default; it applies on Save.
- Settings → Software Updates mirrors SwiftMiner's channel and update-check
  controls with Sequoia-native styling. Preferences apply on Save. Missing
  publishing configuration shows a plain unavailable message and disabled
  controls. No build-setting names appear in the product flow. Installing an
  update may interrupt authority service; explain that restart quarantine applies.

No macOS 26-only APIs, third-party UI libraries or dependencies on SwiftBot's
app target are permitted. Use the native Sequoia equivalent where SwiftBot uses
newer Liquid Glass controls.

## Overview composition

Match SwiftBot's `ConsoleOverviewView` and `HostSummaryCard`: the real 108pt app
icon with a live status dot, app name/status/environment, and version/node/uptime
facts. Put named issue review actions at the foot of the summary. Follow with
four equal service cards (Authority, Guarding, Internet Access, Activity), using
SwiftBot's 168pt minimum width and a 2×2 fallback. Quick Actions and a read-only
System inspector share equal card heights when side by side, with spare space
below the shorter card's content. They stack at natural heights when narrow; Recent
Activity follows. Keep the full catalog and individual ownership in Guarding.
Uptime is display-only and uses the monotonic service start instant. Use native
Sequoia button styles in place of SwiftBot's macOS 26 glass controls.

## Guarding

Use service-neutral navigation and global Overview copy. SwiftBot is the first
service, not the app’s identity. Guarding lists service names, application kinds
and ownership state; a detail view shows ownership, known servers, recent
activity and per-service connection details. Add Service uses a modal draft;
renaming does not interrupt ownership. Use “server” or “participant” for generic
clients, and SwiftMesh pairing instructions only for a SwiftBot service.

Distinguish current ownership from health. Label past participants “Previously
observed”; do not call them connected, online or healthy without fresh evidence.
Empty service ownership remains a neutral state.

Keep Preferred Primary in a separate service-detail panel from Current Owner.
Its sheet offers No preference, observed servers and manual node-ID entry for
unobserved standbys. Show the selected stable ID and a separate marker on known
server rows. Do not relabel the owner when a preference changes or imply the
target is online. Explain compatible-client handover and continued failover.

Service details include Remove with a confirmation describing lost renewal,
normal lease expiry and retained terms/history. All services can be removed,
including SwiftBot; an empty list explains how to add another service. A SQLite
startup block exposes Set Up DuckDB in Overview, Guarding and Settings. Its modal
requires explicit offline/unpaired acknowledgements, explains the local archive
and fresh pairing details, and leaves the authority stopped after setup.
