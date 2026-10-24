# Web UI — shelved

Decision: 22 October 2026. Shelve all Web UI related work until Ruru is active
and in use. Reassess the need and scope from real operational experience then;
there is no scheduled restart date or current release requirement.

Deferred scope includes Ruru’s browser console, dashboards and remote
administration; browser design and assets; passkeys, operator enrollment,
sessions and roles; Cloudflare Access integration for browser users; browser
monitor management; and all associated browser testing, security review and
release-validation tasks. Web UI related integration proposals, including shared
administration/current-owner navigation and richer standby websites, are also
shelved in Ruru’s planning. Historical roadmap entries are records of prior work,
not active commitments, and their Web UI follow-ups are superseded by this decision.

The prototype sources `Sources/Ruru/RuruWebUI.swift` and `RuruWebAssets.swift`
are retained but excluded by `project.yml` from Debug and Release. The app no
longer creates the browser handler or offers enrollment controls. WebAuthn is
removed from the active dependency graph. Existing saved passkey records are
left untouched; they are not loaded by the app. The listener’s optional browser
handler boundary remains available but unused by Ruru; `/`, `/web/*` and
`/api/web/*` return 404 without a handler.

Continue native console, lease safety, client compatibility and deployment
validation work. Existing participant Web UI origins, alert links and resource
catalogue contracts remain compatible. Internet Access still serves the service
API and health checks. The static public website and update feeds in `Website/`
are separate from the shelved application Web UI.

Once Ruru is active and in use, review concrete operator needs before choosing
whether to resume any browser work. Revisit the prototype’s architecture,
authentication, resource bounds and security validation at that time; exclusion
from builds does not certify it for future release.
