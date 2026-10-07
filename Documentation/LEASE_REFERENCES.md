# Lease design references and fencing validation

Ruru's lease authority and regression scenarios are written independently in
Swift. The following upstream projects inform design review; they are not new
runtime dependencies or vendored implementations.

## References and licensing

| Project | Reference | Design lesson | Upstream license |
| --- | --- | --- | --- |
| etcd | [Lock/fencing example](https://github.com/etcd-io/etcd/blob/main/contrib/lock/README.md), [mutex](https://github.com/etcd-io/etcd/blob/main/client/v3/concurrency/mutex.go) | Delayed work from an expired owner needs rejection at the protected resource. | [Apache-2.0](https://github.com/etcd-io/etcd/blob/main/LICENSE) |
| Kubernetes client-go | [Leader election](https://github.com/kubernetes/client-go/blob/master/tools/leaderelection/leaderelection.go) | Renewal deadlines, retry jitter and shutdown ordering; election alone is not fencing. | [Apache-2.0](https://github.com/kubernetes/client-go/blob/master/LICENSE) |
| Apache ZooKeeper / Curator | [Lock recipes](https://zookeeper.apache.org/doc/r3.9.3/recipes.html), [Leader Latch](https://curator.apache.org/docs/recipes-leader-latch/) | Lost responses and connection/session state need explicit handling. | [ZooKeeper Apache-2.0](https://github.com/apache/zookeeper/blob/master/LICENSE.txt), [Curator Apache-2.0](https://github.com/apache/curator/blob/master/LICENSE) |
| Patroni | [Watchdog design](https://patroni.readthedocs.io/en/latest/watchdog.html) | Work must stop before permission expires, allowing for shutdown and scheduling delays. Its watchdog implementation uses Linux interfaces. | [MIT](https://github.com/patroni/patroni/blob/master/LICENSE) |

The initial implementation uses the etcd stale-owner failure scenario as a
conceptual reference. No upstream code, comments, documentation passages or
assets are copied or translated. New Swift test code remains under Ruru's root
MIT license. Existing bundled dependency licenses remain in `Resources/`.
If future work copies or adapts upstream material, review that specific revision,
retain its copyright/license and applicable NOTICE material, identify modifications,
and include required attribution with any distributed material. This reference
list does not replace the license notices for copied code.

## Deterministic stale-owner scenarios

`Tests/WitnessKitTests/LeaseFencingTests.swift` uses temporary DuckDB authorities,
the authenticated JSON router, an injected monotonic clock and a single-resource
Swift actor fixture. Retaining an old grant models a paused client or a delayed
write; advancing the clock avoids real-time sleeps and timing-dependent tests.

The scenarios check that:

- At the exact expiry boundary, B acquires a greater term. Once the protected
  resource accepts B's term, A's delayed write changes neither its data nor fence.
  A's stale renew/release requests also leave B's lease intact.
- Reacquisition by the same stable node ID still uses a greater term, so pending
  work from its previous run cannot overwrite its new run's output.
- Closing and reopening the authority against its existing database enforces
  the full restart quarantine and retains terms. The independently retained
  resource rejects delayed pre-restart output after accepting the new term.
- Independent services can have different term sequences. Resource fences are
  scoped to their service and cannot compare unrelated terms globally.
- Before the successor's term reaches a resource, a highest-seen-term check can
  still accept expired work. Client deadlines remain necessary.

## Integration limits

This verifies the Ruru authority/router together with a simulated cooperating
resource. It does not implement or validate SwiftBot's output path, Discord,
resource persistence, machine suspension or real network partitions. Reopening
the store is an authority-lifetime test; the separate storage-probe suite covers
process termination and DuckDB crash recovery.

A real resource must authenticate its callers and bind the service, node and term
to the permission it trusts. A caller-supplied number is not proof of a grant.
The resource must atomically compare the fence and perform the protected mutation,
durably retain the highest accepted term alongside its data, and never reset that
term while old clients or writes can remain active. The test fixture's in-memory
state is deliberately not a production durability mechanism.

Clients must stop guarded work by their conservative local monotonic deadline,
and finish/stop that work before voluntarily releasing ownership. A term fence
rejects older work after a newer term has been accepted; it does not prove live
ownership, order writes within one term, or guarantee exactly-once effects.
Discord does not enforce Ruru terms, so already-sent requests may still complete.
