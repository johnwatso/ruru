# Operating Ruru safely

Ruru is a single, durable lease authority. It is deliberately not a clustered
database: when it is unavailable, a guarded client may finish only the work
allowed by its last confirmed local lease deadline. A standby must not promote
itself while Ruru cannot be reached.

Use this runbook for the initial two-SwiftBot deployment and after changes to
the Ruru Mac, its network path, or Internet Access.

Deployment testing is underway; the operator reported it working well on
15 October 2026. Record exact builds, machines and completed scenarios in the
acceptance record below before treating that report as coverage of every drill.

## When SwiftBot reports Ruru unreachable

SwiftBot checks Ruru from its own Mac. Its Overview and SwiftMesh views flag an
unreachable authority, and Activity records outage/recovery transitions. The
WebUI Overview and backup-node status page also show this condition. These are
local observations: a failed check can mean a failed Mac, tunnel, WAN path or
just that SwiftBot's own network is unavailable. A reachable recovering Ruru is
shown separately from an unreachable one.

Check the Ruru Mac, its network and Internet Access first. A current owner may
continue only until its local lease deadline; a standby cannot acquire while
Ruru is unavailable. A green health check never grants ownership. These flags
do not send Discord messages or bypass standby output restrictions. They need
SwiftBot to be running and reachable; independent external monitoring is still
needed to detect loss of both applications or their shared network path.

## Recovering from a backup

1. Stop the previous authority and affected servers. Preserve the damaged or
   current database, safety markers and available diagnostic reports.
2. In Settings → Backup, choose Restore and review the file's date, included
   ownership data and settings. Credentials, alert incidents and alert history
   are not portable; alert rules are included with settings.
3. If newer authority data was lost, reconcile the participants' latest durable
   terms and any protected resource's fence before restarting. A fixed term
   margin cannot reconstruct an arbitrarily newer lost authority.
4. Restore explicitly. Ruru archives current storage and opens the restored
   authority without restoring any owner. A restored ownership snapshot starts
   a 300-second quarantine when its database is reopened; waiting in the stopped
   state counts toward it. A settings-only restore does not create that new
   quarantine.
5. Review services, Internet Access and alert destinations. On a new Mac, set
   up credentials and pair servers again. Start Ruru and allow any remaining
   quarantine to finish before expecting acquisitions.

An unverified incident after restart is unresolved, not healthy. Use its Review
action to inspect the target or service. Fresh evidence must verify or recover
it; deleting a rule archives it without establishing recovery.

## Steady-state checklist

- Run one independent Ruru Mac, not a second unreplicated Ruru instance.
- Every participating client uses the exact same public HTTPS authority
  endpoint, cluster ID and service token. Do not use `localhost` on one client
  and the public hostname on another: their Ruru fingerprints would differ.
- Keep Ruru's local listener on loopback. Cloudflare Tunnel supplies public
  HTTPS; do not add router port forwarding.
- Put the Ruru Mac **and its internet path** (router/ONT/switch as applicable)
  on UPS power. A UPS avoids a process restart and therefore avoids restart
  quarantine; it is not a replacement for an outage drill.
- Use Ruru's Backup controls to create and verify backups. Never copy an older
  authority database back over a live or newer one. Do not remove the
  initialization marker, database locks, or authority archives to "fix" an
  outage.
- Keep bearer tokens in Keychain and out of terminal history, screenshots,
  exported diagnostics and runbook notes.

## Before the drill

Run the drill against a non-production Discord channel or another harmless
guarded side effect. Arrange a visible marker that only the active SwiftBot can
produce, and record timestamps from both clients and Ruru. Do not use the drill
to change service tokens, terms, database files, Cloudflare DNS, or pairing.

Confirm first:

1. Ruru reports **Running** and its public `GET /health` returns HTTP 200 with
   `{"ready":true}`.
2. Both SwiftBots use the same Ruru address and each can authenticate to the
   configured service.
3. Exactly one SwiftBot is emitting the guarded marker; the other is passive.
4. The configured lease duration is known. The intended SwiftBot deployment
   uses five minutes (300 seconds).

## Failure drill

### 1. Tunnel or WAN loss and return

Temporarily pause Internet Access in Ruru or interrupt the Ruru Mac's WAN path.
Do not stop the authority process.

- The local authority remains running; Internet Access becomes unavailable or
  reconnecting. This is a transport condition, not proof that a lease changed.
- The current owner may continue only until its **own local monotonic lease
  deadline**. It retries renewal; it must stop guarded work if it cannot renew
  in time.
- The standby remains passive. It does not self-promote merely because Ruru is
  unreachable.
- Restore the path or resume Internet Access. Verify Cloudflare reconnects and
  public `/health` is reachable again. Verify normal renewal/acquisition
  resumes without changing database files or re-pairing clients.

### 2. Ruru restart and recovery quarantine

Restart Ruru deliberately from its normal app lifecycle. Do not kill or remove
the database to shorten the wait.

- During recovery, public `/health` returns HTTP 503 with `{"ready":false}`.
- Both **new grants and renewals** are refused with `authority_recovering`.
- The wait is a full duration Ruru recorded for the longest outstanding grant,
  not merely the old lease's remaining time. A brief process outage can
  therefore cause a longer safe gap.
- The former owner stops at its local deadline. No client is allowed an
  unilateral grace period beyond that deadline.
- After `/health` returns ready, verify that only one client acquires and emits
  the guarded marker. Its fencing term must be newer than the previous term.

### 3. Owner loss and takeover

With Ruru reachable, stop the active SwiftBot's guarded work using its normal
shutdown path. Observe that the standby waits for release or expiry, then
acquires through Ruru. Verify one marker producer throughout; a handover gap is
acceptable, two simultaneous producers are not.

## Acceptance record

Record the Ruru version, client versions, configured lease length, the event
timestamps, and whether each expected result occurred. Record only non-secret
identifiers. Treat any duplicate guarded output, term regression, successful
renewal during recovery, or automatic promotion while Ruru is unreachable as a
safety failure: stop the drill and preserve logs/database files for diagnosis.

## What not to automate

Ruru does not manage router power, UPS settings, Cloudflare account recovery,
or a second authority. Do not build automatic database restoration, forced
promotion, or authority restart into a health check. Those actions can defeat
the fencing and restart-quarantine guarantees that make failover safe.
