# Operational status API (v1)

Operational status is an application-neutral, observational capability. It
reports whether a node considers its local work ready, synchronising, outdated,
degraded, or unknown. It is separate from leases, participant presence,
Preferred Primary, and authority readiness: a report cannot grant ownership,
change a term, or cause a promotion.

Discover `operationalStatus` through authenticated `GET /v1/service` before
using it. Older Ruru instances return no such capability and must be left
compatible.

`POST /v1/operational-status/report` requires the service bearer token:

```json
{"version":1,"clusterID":"example-service","nodeID":"stable-node-id","state":"degraded","components":[{"namespace":"example","id":"sync","state":"degraded","reasonCode":"peer_unreachable"}]}
```

States are `ready`, `synchronizing`, `outdated`, `degraded`, and `unknown`. A
report has at most 16 components; a service has at most 32 reported nodes.
Component namespace, ID, and reason code are bounded ASCII machine codes, so
applications must not send free-form logs, paths, URLs, credentials, or user
data. Fresh reports last 45 seconds and observations are discarded after 10
minutes, on authority restart, or when the service credential changes.
