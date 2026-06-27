# ADR 0016: Cluster Test Suite Owns the Controller's DS-App Lifecycle

- Status: Accepted
- Date: 2026-06-27
- Deciders: DS project
- Component: `test/test_helper.exs`, `test/support/cluster_case.ex`,
  `DS.Rebalancer`, `DS.Application`

## Context

The cluster test harness from ADR-0015 spins up peer nodes via `:peer.start`
in `DS.ClusterCase.setup_all`, runs the file's tests, and stops the peers in
`on_exit`. The controller VM (the one running `mix test`) is treated as a
persistent fixture: the DS application starts in `test_helper.exs` and is
shared across every test suite.

When we tried this approach in practice, several failure modes appeared in
sequence — each only visible once the previous one was fixed.

### Failure 1 — `:global` prevent-overlapping-partitions false positive

`:global` is Erlang's distributed name registry. We use it for leader
election in `DS.Rebalancer`: the first node to call
`:global.register_name(:ds_rebalancer, self())` becomes the leader; the
others become followers.

OTP 25 added the `prevent_overlapping_partitions` setting (defaults to
`true`). When enabled, `:global` watches connect / disconnect events and
proactively force-disconnects nodes if it detects that one node's view of
which nodes are connected disagrees with another node's view. The intent is
to prevent silent state divergence in real network partitions.

In our tests, every cluster file's `setup_all` connects fresh peers, and
every file's `on_exit` disconnects them. Across this rapid churn,
`:global`'s background sync state on the controller and on new peers can
momentarily disagree about cluster membership — even though there is no
real partition, only the deterministic test choreography. The detector
fires a false positive and forces a disconnect:

```
'global' at node :"controller@127.0.0.1" requested disconnect from node
:"p1@127.0.0.1" in order to prevent overlapping partitions
```

### Failure 2 — supervisor restart-intensity cascade

The forced disconnect from Failure 1 breaks the controller `Rebalancer`'s
link to the (now-disconnected) peer's Rebalancer process. The link fires,
which re-triggers `elect/1`, which re-establishes a link to a new follower,
which can break again moments later. Within a few seconds the top-level
supervisor's restart intensity (default `max_restarts = 3` in
`max_seconds = 5`) is exhausted. The whole DS app on the controller exits
with reason `shutdown`.

From that point on, the controller has no `Storage.Index` GenServer, so its
`:indexes` ETS table no longer exists, so every subsequent test's
`do_reset` hits `ArgumentError` from `:ets.tab2list(:indexes)`. The actual
test failures look like generic ETS errors and don't point at the
underlying `:global` cause.

### Failure 3 — `Rebalancer` rebalance-delay timer flake

After Failures 1 and 2 were addressed (`prevent_overlapping_partitions =
false`, plus the harness changes below), one test continued to flake at
roughly 50% — `DS.RouterTest "replica_nodes/1 is deterministic for the
same key"`. The pattern: the first call to `Router.replica_nodes/1`
returned the expected list; a second call moments later returned `[]`.

Cause: when peers are stopped at the end of a cluster suite, the
controller's `:net_kernel.monitor_nodes` subscription delivers a
`:nodedown` event to the leader Rebalancer. The leader's handler schedules
a `:do_rebalance` timer for `DS.Config.rebalance_delay()` (default 5
seconds — see ADR-0009) to absorb brief network flaps. If an isolated test
(`RouterTest`, in this case) happens to run within that 5-second window,
the timer fires mid-test, calls `Routing.bulk_update/1` with a fresh
assignment computed from `DS.Router.all_nodes()` (which by then is just
`[node()]`), and overwrites the routing table the test had populated. The
test's second `Router.replica_nodes/1` then sees the new (or empty) state.

## Decision

**The cluster test suite owns the controller's DS-app lifecycle.**
Specifically:

1. **`test_helper.exs` does not start the DS app.** It only sets
   `prevent_overlapping_partitions = false` (belt-and-suspenders) and
   calls `ExUnit.start()`. Distribution is also not started here.

2. **`DS.ClusterCase.setup_all`** is the entry point for every cluster
   test file. It:
   - Ensures distribution is up (`:net_kernel.start` if `Node.alive?/0` is
     false — distribution is VM-wide and only needs to be brought up once).
   - Calls `Application.stop(:ds)` to terminate any controller-side DS
     state left over from previous suites (rebalancer, routing
     assignments, schema/index/primary ETS tables, pending timers).
   - Calls `Application.ensure_all_started(:ds)` to re-boot the DS app
     fresh on the controller.
   - Spawns peers, copies env, connects, syncs `:global`, starts the DS
     app on each peer.
   - Waits for the leader's rebalance broadcast to populate `:routing` on
     every node before returning.

3. **`DS.ClusterCase`'s `on_exit`** stops every peer (catching
   `:exit, _` if a peer is already dead) **and** calls
   `Application.stop(:ds)` on the controller. The latter terminates the
   `Rebalancer` GenServer, which kills any pending `:do_rebalance`
   timer with it — eliminating Failure 3.

4. **Isolated tests are self-sufficient.** Every isolated test file
   already starts its own GenServers via the
   `start_link/{:error, {:already_started, _}}` pattern, so they work
   whether or not the controller's DS app is currently running. After a
   cluster suite has stopped the controller's app, an isolated test's
   `start_link` cleanly takes ownership.

## Consequences

### Positive
- Each cluster suite begins with a controller that has no `:global`
  registrations, no leftover routing assignments, and no pending timers
  from previous suites. The mental model is: every cluster suite sees a
  fresh cluster.
- Isolated tests are insulated from cluster-side state. A
  `Rebalancer` running on the controller can no longer fire timers mid
  isolated test.
- The `:global` false-positive disconnect path is closed by the kernel
  env flag. The restart-cascade path is closed by avoiding the conditions
  that trigger it. The Rebalancer-timer path is closed by tearing down
  the Rebalancer at suite end. All three failure modes are addressed at
  different layers, with no single point of failure.
- The harness shape now matches its purpose. Cluster setup logic lives in
  the cluster `CaseTemplate`, not in a global entry point.

### Negative
- Each cluster suite pays the cost of stopping and starting the DS app on
  the controller (tens of milliseconds). Negligible for the current test
  count; could become a real cost at hundreds of cluster suites.
- We disable `prevent_overlapping_partitions` in tests. If a future bug
  somehow depended on this safety net firing, our tests would not catch
  it. The safety net is OTP-internal; no application code in DS depends
  on its behavior, so this is acceptable.
- Tests run on a single machine with deterministic Erlang distribution.
  We are explicitly *not* exercising real network failure modes. Such
  scenarios — packet loss, asymmetric reachability, NIC flaps — would
  need a separate harness (network namespaces, tc, or a proxy) to test
  properly.
- A `test_helper.exs` that doesn't start the application is unusual.
  Future contributors may expect `mix test` to start the app
  automatically; the cluster `CaseTemplate` and isolated tests'
  `start_link` fallbacks make this work, but the indirection is worth
  documenting in a comment.

## Alternatives considered

1. **Keep `Application.ensure_all_started` in `test_helper.exs`; restart
   only the controller's `Rebalancer` per cluster suite.** Rejected as
   too narrow. The flakes traced back to multiple parts of the DS app
   state (`:routing`, `:global` registrations, pending timers). A
   targeted `Rebalancer` restart would still leave other state
   carryover. Stopping the whole app is simpler and covers everything.

2. **Single shared cluster across all cluster test files.** Spawn peers
   exactly once in `test_helper.exs`, store them in `:persistent_term`,
   never stop them between suites. Avoids all churn. Rejected as too
   restrictive: it couples test files together (a flaky test in file A
   pollutes the cluster for file B) and prevents per-suite topology
   variation (e.g., a future "2-node cluster" test).

3. **Increase the supervisor's `max_restarts` on the controller in test
   env.** Hides Failure 2 by giving the supervisor more headroom, but
   the underlying false-positive disconnect (Failure 1) still happens
   and the system is still in a degraded state during tests. Treats a
   symptom, not the cause.

4. **Wait longer between peer stops and starts.** Hardcoded
   `Process.sleep`. Fragile and doesn't scale with test count.

5. **Restart the whole BEAM per cluster suite** (via separate `mix test`
   invocations per file or via a wrapper script). Heavy. Erlang
   distribution is expensive to bring up repeatedly. Loses the benefits
   of a single ExUnit run (consolidated reporting, shared compile
   state).

## Related

- ADR-0009 — Rebalancer 5-second grace timer on nodedown. The Failure 3
  timer is exactly this mechanism behaving correctly in production
  conditions but biting us in a test context where nodes deliberately
  vanish.
- ADR-0015 — `:peer` for cluster tests. This ADR refines that harness
  with the lifecycle changes.
- `test/support/cluster_case.ex` — concrete implementation.
- `test/test_helper.exs` — minimal entry point.
