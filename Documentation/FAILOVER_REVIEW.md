# Failover safety review — 2026-10-09

Ruru follows a conservative single-authority lease design. Source review found
and corrected an outstanding-grant bug when shortening leases, plus safety gaps
in its bundled example clients. This is a code and local fault-test review;
deployment on the intended Macs has not been validated by this review.

## Corrections

- **Lease shortening:** a renewal used to replace a long lease with the new,
  shorter duration immediately. If that reply was lost, the owner could still
  trust its earlier grant when a successor acquired ownership. Renewals now
  preserve the later deadline and persist a matching recovery duration. Tests
  cover a lost reply, quarantine after restart, eventual adoption of the new
  duration, and refusal of out-of-range stored durations.
- **Swift reference client:** renewals race the outstanding local deadline;
  blocking transport cannot extend ownership. Grants have bounded durations and
  terms, must name this owner, must match the renewal term, and are rejected
  when their send-time deadline has passed. A stopping margin of 10%, capped at
  two seconds, is reserved. Cancellation awaits the standby callback in a fresh
  task before release, so the application can stop/drain output first. Cancelling
  during a blocked renewal preserves the last known grant for best-effort release.
- **Python example:** an independent expiry thread stops its placeholder worker
  while HTTP is blocked. Renewals update the worker deadline; expired and invalid
  grants cannot start it. The worker still needs per-effect checks and fencing.

## Reviewed safeguards

| Area | Source behaviour and evidence |
| --- | --- |
| Exclusive grants | The LeaseStore actor serializes read/modify/commit; concurrent acquire and stale renew/release tests cover one live owner per service. |
| Durable permission | Grants and audit writes commit together before acknowledgement; rollback injection and a separate SIGKILL/WAL recovery test preserve acknowledged terms. |
| Expiry | ContinuousClock drives live expiry; expired renewal never revives an owner. Request-send-time client deadlines avoid granting extra time for a delayed reply. |
| Fencing | Terms increase across successors, same-node reacquisition and restart, are scoped per service, and fail closed at exhaustion. Tests exercise an atomically fenced simulated resource. |
| Restart | Old epochs never become live; the longest outstanding recorded grant determines quarantine. Repeated restarts cannot clear the durable expiry and skip recovery. |
| Storage failure | Missing/corrupt/unfinished storage and missing safety markers fail closed. Dual lifetime locks exclude simultaneous processes on the same database. |
| Restore | Offline restore takes the locks, retains archives, raises known terms and quarantines for 300 seconds; it does not restore ownership. |
| Admission | Scoped service credentials, bounded requests/connections, metadata connection limits, and service revocation preserve separation from lease grants. |
| Preference and observation | Preferred Primary and participant reports do not grant or transfer ownership. Stable IDs identify owners; reported URLs/roles are metadata, not health or promotion evidence. |
| Listener and tunnel | Pausing/restarting the listener retains the same authority and clock. Connector generation checks and bounded retry operate separately from the authority. Closing the console leaves the menu bar service running. |
| SwiftBot boundary | Read-only inspection confirmed request-send-time deadlines with a margin and DiscordService.outputAllowed checking expiry independently of renewal completion. This is not a complete SwiftBot audit. |

## Operational limits and remaining validation

- Ruru is **one authority**, without quorum replication or automatic authority
  failover. If its Mac, network or tunnel is unavailable, owners stop by their
  deadlines and no standby can acquire. Running another independent authority
  for the same service would defeat exclusivity; file locks protect one database,
  not authorities on different Macs.
- Ruru runs in a logged-in user session. Login registration is optional; there
  is no pre-login daemon or independent crash supervisor. Deployment needs an
  operator-chosen startup and power/network arrangement. This review did not
  change login items, energy settings, tunnels or production data.
  A crashed Ruru cannot send its own outage notification; unattended operation
  needs health monitoring from outside that process.
- Workers must enforce deadlines before every side effect, return promptly from
  callbacks, and stop/drain before release. Resource fencing must authenticate
  grants and atomically retain the highest term with its mutation. Timers and
  stopping margins do not guarantee safety under arbitrary process suspension
  or clock-rate differences. Discord cannot fence already-sent requests, so
  exactly-once messaging is not guaranteed.
- Disaster restore raises the highest **known** term by a fixed margin. That
  margin cannot reconstruct an arbitrarily newer lost database. Stop all former
  authorities/participants, retain available current terms, and reconcile a
  downstream resource's durable fence when recovering from complete data loss.
- Still required before a deployment-level assurance: controlled two-Mac owner
  crash, witness loss, asymmetric partition, suspend/resume, lost renewal reply,
  handback/drain and restore drills. Verify actual Sequoia/Intel execution and
  resource use on the intended Mac mini. SIGKILL recovery does not test sudden
  power loss or faulty storage hardware.

## Design references

The review compared the implementation with the existing independently authored
[lease references](LEASE_REFERENCES.md):
[etcd's resource fencing example](https://github.com/etcd-io/etcd/blob/main/contrib/lock/README.md),
[client-go's renewal deadlines and release-before-work-finishes warning](https://github.com/kubernetes/client-go/blob/master/tools/leaderelection/leaderelection.go),
and [Patroni's stopping margins and watchdog limitations](https://patroni.readthedocs.io/en/latest/watchdog.html).
No upstream code was copied or translated and no runtime dependencies were added.

## Validation

- Focused Xcode run: 12 tests passed (lease duration and reference-client safety).
- Python example: 4 isolated unittest cases passed.
- Final full Xcode suite/build: **148 tests passed**, including the additional
  cancellation-during-renewal regression, real client/server conformance, fencing,
  restore and SIGKILL/WAL recovery tests.
- Universal Release build passed. Both the app and WitnessKit contain x86_64
  and arm64; all four slices have a macOS 15.0 minimum deployment target. Actual
  Intel/Sequoia execution was not performed.
- XcodeGen and `git diff --check` passed. Logs are in the ignored
  `.artifacts/failover-final-tests.log`, `failover-release.log` and
  `failover-python-tests.log`. All tests used temporary storage or isolated
  transports; no production authority was launched.
