# Enhanced monitoring (`/.well-known/ruru`)

App developers: start with [Adding Ruru status to your app](APP_STATUS.md)
and the [JSON Schema](ruru-status-v1.schema.json). This page is Ruru's design.

**Status:** phases 1 and 2 are implemented (the contract, the `RuruClient`
builder and enhanced HTTP(S) monitors in the native and Web consoles). Phase 3
(alerts on reported state) and phase 4 (private documents) are not. The
operator approved phases 1–2 as a v1-scope exception (see
[below](#v1-scope-exception)).

Today an HTTP(S) monitor tells the operator one thing: whether a URL answered
with 200–399 in time. This proposal lets any app opt in to richer monitoring by
serving a small, bounded JSON status document at a well-known path. Ruru reads
it instead of a plain page and shows the app's identity, version, component
health and a few headline metrics on the monitor's detail page.

It is a *pull* companion to the existing push-based
[operational status API](OPERATIONAL_STATUS_API.md). Push needs pairing and a
service credential and is meant for guarded participants. Pull needs nothing
from Ruru: a developer adds one route, and an operator who already monitors the
app's website switches the monitor to enhanced mode.

## Goals and non-goals

Goals:

- Any app with an HTTP(S) listener can offer richer monitoring by adding one
  read-only route. For example, SwiftMiner (the macOS Twitch Drops app) could
  serve it from its own API/web-dashboard server.
- Reuse the existing HTTP monitor, its bounds, SSRF filter, threshold state
  machine, alert rules and incident handling.
- Use the same state vocabulary as operational status so the console and alerts
  treat both the same way.
- Keep the document safe to publish openly by default.

Non-goals:

- Enhanced monitoring is not authoritative. It never affects leases, terms,
  fencing, promotion, Preferred Primary, routing or client output permission.
- The document is not participant identity. Its `app.id` is self-reported and
  unauthenticated, and is never matched to a guarded service or node.
- No logs, traces, events, remote commands or free-form diagnostics.
- No Prometheus or OpenMetrics scraping (see [alternatives](#alternatives-considered)).
- No automatic discovery of apps or servers. The operator adds each monitor.

## Why `/.well-known/ruru`

- [RFC 8615](https://www.rfc-editor.org/rfc/rfc8615) reserves `/.well-known/`
  for site metadata, so the route will not collide with an app's own paths.
  `/ruru` or `/status` might.
- The path is fixed, so Ruru can find the document from the origin alone. An
  operator who types `https://swiftminer.app` does not need to know any more.
- One request covers reachability and status, so enhanced mode adds no traffic.

The name is unregistered with IANA. That is fine for now; register it if
outside adoption grows.

## Document schema (version 1)

`GET https://<origin>/.well-known/ruru`, served with
`Content-Type: application/json` and HTTP 200.

```json
{
  "ruru": 1,
  "app": {
    "id": "app.swiftminer",
    "name": "SwiftMiner",
    "version": "1.45.0",
    "build": "2026101912"
  },
  "state": "degraded",
  "reasonCode": "account_needs_sign_in",
  "uptimeSeconds": 183412,
  "components": [
    { "id": "miners", "name": "Drop miners", "state": "degraded", "reasonCode": "account_needs_sign_in" },
    { "id": "swiftbot", "name": "SwiftBot connection", "state": "ready" }
  ],
  "metrics": [
    { "id": "accounts", "name": "Accounts", "value": 3, "unit": "count" },
    { "id": "accounts_mining", "name": "Mining now", "value": 2, "unit": "count" }
  ],
  "links": [
    { "rel": "dashboard", "title": "Dashboard", "url": "https://miner.example.com/app" }
  ]
}
```

### Fields

| Field | Required | Rule |
| --- | --- | --- |
| `ruru` | yes | Integer document version. `1` for this specification. |
| `app.id` | yes | Machine ID, reverse-DNS style. Display and grouping only; never identity. |
| `app.name` | yes | Display name. |
| `app.version` | no | Display text, for example `1.45.0`. A change is recorded in Activity. |
| `app.build` | no | Display text. |
| `state` | yes | `ready`, `synchronizing`, `outdated`, `degraded` or `unknown`, as in operational status. |
| `reasonCode` | no | Machine code explaining a non-`ready` state. |
| `uptimeSeconds` | no | Non-negative integer, the app's own process uptime. A decrease is shown as a restart. |
| `components[]` | no | Each has `id`, `name`, `state` and an optional `reasonCode`, with the same states as above. |
| `metrics[]` | no | Each has `id`, `name`, a finite number `value` and an optional `unit`. |
| `links[]` | no | Each has `rel` (`dashboard`, `status`, `docs` or `support`), `title` and `url`. |

There is no timestamp field. Freshness is the moment Ruru fetched the document,
measured on Ruru's monotonic clock; app clocks are not trusted.

Unknown fields are ignored so the format can grow. Ruru accepts documents whose
`ruru` version it supports. A higher version leaves the monitor in plain HTTP
mode with an "unsupported status version" note, and a check still succeeds or
fails on the HTTP response alone.

### How a check is judged

| Response | Monitor result | Enhanced state shown |
| --- | --- | --- |
| Transport error, timeout, or status outside 200–399 | Failure, counted toward the threshold as today | Last valid document, marked stale |
| 200 with a valid document | Success | The document |
| 200 with a missing, invalid or oversized document | Success (the site is up) | "Status document invalid", with the reason code |
| 3xx | Treated as today (redirects are not followed) | Not parsed |

A reported `degraded` or `outdated` state never counts as the site being down.
It is a separate condition that alert rules can watch (phase 3).

## Bounds

All bounds are enforced by Ruru while reading and are not negotiable by the app.

| Item | Limit |
| --- | --- |
| Response body | 16 KiB; reading stops and the document is rejected beyond this |
| Components | 16 |
| Metrics | 16 |
| Links | 4 |
| `id`, `reasonCode` | ASCII `[a-z0-9._-]`, 1–48 characters |
| `name`, `title` | 1–64 characters after trimming |
| `version`, `build` | 1–32 characters |
| `unit` | 1–16 characters |
| `uptimeSeconds` | 0 to 10 years |
| Metric `value` | Finite double; NaN and infinity are rejected |
| Duplicate component or metric IDs | Document rejected |
| Interval and timeout | The HTTP monitor's existing 30 s–1 h and 1–30 s ranges |
| Targets | The existing 32-monitor limit; enhanced mode adds none |
| Metric history | In memory only, 120 values per metric, the same as check results |
| Requests per check | One |

Worst case is 32 targets × 16 metrics × 120 values, about 61,000 doubles
(under 1 MiB). History resets when Ruru restarts, like monitor results today.
Document parsing runs on the monitor engine's existing utility work, never on
the lease listener, the lease store or the 1 s refresh loop.

## Security rules

1. **Apps decide who can read it.** Apps should offer an exposure setting:
   off (the default, answering 404), local network only (refusing requests
   that carry proxy or tunnel headers such as `CF-Connecting-IP`), or
   everywhere. `RuruStatusExposure` in RuruClient implements this.
   **Anything published may be public, so publish nothing private.** Developer guidance: no
   secrets, tokens, internal hostnames, IP addresses, file paths, user data,
   account names, game or campaign names, log lines or error text. Use machine `reasonCode`s for
   details.
2. **Same origin only.** Ruru derives the URL from the monitor's scheme, host
   and port and never follows redirects. Every existing HTTP monitor
   restriction applies unchanged, including the restricted-host filter and
   `requiresNumericHost` for monitors created in the Web console.
3. **No ambient credentials.** No cookies, no cache, no URL credentials, and the
   same ephemeral session settings as today's HTTP probe and favicon fetch.
4. **Plain text only.** Every string is shown as plain text. No Markdown, HTML,
   images or remote icons from the document. Control characters and Unicode
   bidirectional overrides are removed before display, and the Web console
   escapes everything it renders.
5. **Links are restricted.** `https` only, on the same host as the monitor, with
   no user info in the URL. The console shows each link's host and opens it in
   the default browser only when the operator clicks. Other links are dropped.
6. **Non-authoritative isolation.** Enhanced data is an *application report* in
   `AlertSignal` evidence terms. It cannot clear an incident that Ruru's own
   reachability observation opened, and it never reaches lease, ownership or
   `RuruClient` lease code.
7. **Hostile servers are expected.** Size, count, length and timeout limits
   bound memory and time whatever the server sends. A malformed document is a
   display fault, not a crash or a monitor failure.
8. **Optional access token (phase 4, deferred).** An operator may later attach a
   bearer token for a private status document. It would live in Keychain, be
   sent only to the exact `https` origin, never be logged or exported, and be
   cleared when the monitor is removed. Until then, documents are anonymous.

## Console experience

On a monitor's detail page in enhanced mode:

- **Header:** app name, version and build, the overall state as a coloured
  status, and "checked *n* s ago".
- **Components:** a compact list of each component's state and reason code.
- **Metrics:** up to 16 small tiles, each with its value, unit and a sparkline
  from in-memory history.
- **Links:** buttons for dashboard, status, docs or support.
- **Activity:** version changes, detected restarts (uptime decreased) and state
  transitions join the existing activity feed.

The monitor list and Overview card show the overall state next to reachability,
so a site that is up but degraded is visible at a glance. Layout follows
[Design](DESIGN.md) (SwiftBot-style surfaces and service cards on macOS 15).

Ruru has no per-app code: any app that serves a valid document is supported.
When an HTTP(S) monitor is added (in either console), Ruru makes one
same-origin request for `/.well-known/ruru` with the monitor's own
restrictions. If a valid document comes back, it turns on **Read app status**
for that monitor; otherwise nothing changes. The operator can switch it off at
any time, and an edited monitor is never switched on automatically. In the
native edit sheet, **Check Address** repeats the check and reports what it
found, including an HTTP error such as 401 when the app has not opened the
route.

Ruru's Web console shows the same app name, version, reported state,
components and metrics in a monitor's detail sheet, as plain text. It does not
show the document's links, so the browser never renders an app-supplied URL.
A degraded or outdated report turns the monitor's status pill orange.

## Model changes

- `MonitorTarget` gains `enhancedStatus: Bool`, decoded with
  `decodeIfPresent ?? false`, so existing `configuration.json` files load
  unchanged. It is only valid when `kind == .http`.
- A UI-free `MonitorStatusDocument` type with strict validation lives in
  WitnessKit (`Sources/WitnessKit/MonitorStatusDocument.swift`).
- `RuruClient` gains an `Encodable` `RuruStatusDocument` builder, so Swift apps such
  as SwiftMiner can serve a valid document without copying the schema. Per
  `AGENTS.md`, this ships with documentation and conformance tests in the same
  change, and is purely additive.
- No change to the lease database, `/v1` routes, `/health`, the alert database
  schema or the operational status API.

## Implementation phases

1. **Contract (done).** Add `MonitorStatusDocument` (WitnessKit), validation, the `RuruClient` builder,
   a JSON fixture set (valid, oversized, duplicate IDs, NaN, unknown version,
   hostile strings) and conformance tests. Update [Integrations](INTEGRATIONS.md).
2. **Enhanced HTTP monitors (done).** Add the `enhancedStatus` probe path, in-memory
   metric history and the detail-page UI, plus debug-preview fixtures for every
   state.
3. **Alerts.** Add overall and per-component state conditions as `AlertSignal`
   producers with application-report evidence, using the existing rule,
   cooldown and incident model. No new destinations.
4. **Private documents (optional).** Add the Keychain-backed access token, only
   if a real deployment needs it.

Each phase updates [the development log](ROADMAP.md) with validation limits.

## v1-scope exception

[Architecture](ARCHITECTURE.md#v1-scope-and-feature-gate) lists "additional
monitor/probe types" as out of scope for v1. It also says what an exception
needs: an explicit user need, resource and failure bounds, why the feature
cannot live in the participating app, and safety validation. This section
covers each in turn.

**User need.** App developers want Ruru to show more than up or down for their
services, and the operator wants one console for that. SwiftMiner is the
intended first adopter. This counts as a concrete need only once SwiftMiner (or
another app) commits to serving the document. Until then, phase 1 can proceed
alone, because it adds only a type and tests.

**Resource and failure bounds.** [Bounds](#bounds) lists every limit: one
request per existing check, 16 KiB bodies, fixed counts, and under 1 MiB of
in-memory history in the worst case. Nothing is persisted except alert
incidents through the existing bounded store. A failure in parsing or display
degrades only that monitor's detail page.

**Why it cannot live in the participating app.** Each app can already show its
own status. What it cannot do is give the operator's single, independent
observer (a separate Mac in another place) a consistent view across apps, keep
working while the app's own UI is broken, or raise alerts through Ruru's rules
and quiet hours. The app still owns everything it reports. Ruru only reads
and displays it.

**Why it is a narrow extension rather than a new probe.** It reuses the HTTP
transport, SSRF filter, redirect policy, intervals, thresholds and target
limit. It adds a parser and a display, with no new network capability,
destination or protocol.

**Safety validation required before release:**

- Lease latency is unchanged with 32 enhanced monitors at a 30 s interval
  against slow (timeout) and maximum-size servers, measured on the Intel Mac
  mini.
- Hostile-document tests cover oversize, deep nesting, invalid UTF-8, bidi
  characters, duplicate IDs, non-finite numbers and slow-drip bodies.
- Redirects and restricted hosts are refused for both native and
  Web-console-created monitors.
- Old `configuration.json` decodes unchanged, and downgrading to an older Ruru
  ignores the new field.
- No enhanced state can open, clear or affect a lease, participant, Preferred
  Primary or authority-readiness signal.

**Recommendation.** Approve phase 1 now, since it is contract-only and changes
no runtime behaviour. Gate phases 2–3 on a committed first adopter and a
completed Intel Mac mini validation pass. Defer phase 4.

## Alternatives considered

- **Custom path such as `/ruru`.** It could collide with app routes and is not
  standard. Rejected in favour of `/.well-known/`.
- **Prometheus or OpenMetrics `/metrics`.** It has no shared notion of
  component state or app identity, uses text exposition, and its label
  cardinality is unbounded. Bounding it safely would take more code than this
  format. It could be read later through the same display if demand appears.
- **IETF health check draft (`application/health+json`).** Close in spirit, but
  it is an expired draft with open-ended `checks` objects and free-form
  `output` text that conflicts with rule 1. A converter could be added later.
- **Push only (operational status).** It needs pairing and a service credential.
  That suits guarded participants, but is too heavy for "show me how my website
  is doing". The two are complementary and share a state vocabulary.
