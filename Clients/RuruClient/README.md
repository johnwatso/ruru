# RuruClient

`RuruClient` is the supported Swift Package Manager client for applications
that use a [Ruru](https://github.com/johnwatso/ruru) authority. It provides
lease fencing, one-time-code pairing, service capability discovery and
participant-presence reporting. It has no SwiftUI, Cloudflare, DuckDB or
Ruru-app dependency.

## Add the package

After the first RuruClient release tag is published, add Ruru's repository as
a package dependency, then add the `RuruClient` library product to the target
that performs guarded work:

```swift
.package(url: "https://github.com/johnwatso/ruru.git", from: "0.2.0")
```

Until that tag exists, or for local development as an external consumer, use
the Ruru repository root as the package path. Ruru's own Xcode project uses a
small nested manifest in this directory to avoid resolving the project as its
own package; external consumers must use the root manifest.

## Use it safely

Store the service token in Keychain, provide a stable node ID, and stop work
whenever `maintain` reports standby or unavailable. Every protected side effect
must also be fenced using `RuruLease.term` and must respect
`RuruLease.deadline`.

```swift
import RuruClient

let client = RuruLeaseClient(configuration: .init(
    endpoint: URL(string: "https://ruru.example.com")!,
    clusterID: "my-service",
    nodeID: stableNodeID,
    nodeName: "Primary Mac",
    token: tokenFromKeychain
))

let ownershipTask = Task {
    await client.maintain { state in
        switch state {
        case .owner(let lease):
            await worker.start(fencedBy: lease.term, until: lease.deadline)
        case .standby, .unavailable:
            await worker.stop()
        }
    }
}
```

Cancellation waits for the standby callback to finish stopping/draining work,
then releases the lease when it is still valid. This does not make an unfenced
side effect safe; read the [integration guide](../../Documentation/INTEGRATIONS.md)
before adopting the package.

If your application persists its own highest accepted fencing term, call
`acquire(minimumTerm:)` after recovery. A grant below that floor is released
before the method throws `RuruError.ownershipLost`; a release transport failure
is returned instead because the client cannot know whether Ruru received it.

## Operational status

Applications can report bounded readiness checks after feature-detecting
`operationalStatus` from `describe()`. This is diagnostic data only: it cannot
grant, renew, release, or extend a lease. Use stable component IDs and bounded
reason codes, not logs, hostnames, paths, tokens, or free text.

```swift
if (try await client.describe()).supports("operationalStatus") {
    try await client.reportOperationalStatus(state: .degraded, components: [
        .init(namespace: "example", id: "sync", state: .degraded,
              reasonCode: "peer_unreachable")
    ])
}
```

## Compatibility

The package follows semantic versioning. Patch releases preserve public API and
wire compatibility; minor releases may add source-compatible API; major
releases may break source compatibility. Ruru's lease routes and JSON contract
remain compatible as described in the integration guide and OpenAPI document.
`RuruServiceDescription.authorityVersion` and `.authorityBuild` identify the
serving Ruru app release for logs or support screens. They are optional so
clients remain compatible with older authorities, and they are not a substitute
for capability detection.

Every RuruClient change must keep its unit suite and Ruru's real-server client
conformance tests passing. A client release is tagged at the Ruru repository
root so consuming apps can use a normal SwiftPM version requirement.
